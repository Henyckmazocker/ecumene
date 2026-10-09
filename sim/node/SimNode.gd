class_name SimNode
extends RefCounted

## Un nodo del árbol de escalas. **Es el mismo objeto en las siete escalas**: lo que cambia
## es su `tier`, y con él el `TierDef` que dicta qué recursos maneja, qué puede construir y
## cuándo puede promocionar.
##
## Un nodo es a la vez la escala y su propia capital: un nodo de tier "ciudad" tiene su
## población y sus edificios (el núcleo urbano) y además hijos de tier inferior. La población
## total del subárbol es `pop` + la de todos los descendientes.
##
## Estado autoritativo puro: aquí no hay nodos de escena, ni referencias a la vista, ni
## `get_instance_id()`. Los ids son propios y estables, y todo esto se serializa tal cual.

var id: int = -1
var tier: int = Content.SETTLEMENT
var parent_id: int = -1
var children: PackedInt32Array = PackedInt32Array()

## Semilla derivada, estable: fija el terreno procedural y la materialización de agentes.
var seed: int = 0
var name: String = ""

## Población propia (el núcleo de esta escala), no la del subárbol.
var pop: float = 0.0
## Stocks por recurso, indexados por las constantes de `Goods`.
var stocks: PackedFloat64Array = Goods.zeros()
## Ejemplares construidos, indexados por el índice global de `Content.buildings()`.
var buildings: PackedInt32Array = PackedInt32Array()
## **Trabajadores destinados** a cada oficio, mismo índice que `buildings`.
##
## Es un número de personas, no un peso: si aquí pone 6, hay seis granjeros. Lo que no está
## asignado está ocioso. El motor no reparte a nadie por su cuenta — construir una granja no
## la llena de gente, la llenas tú.
var jobs: PackedFloat64Array = PackedFloat64Array()

## Mejoras compradas en este nodo. Permanentes y por nodo.
var upgrades: PackedStringArray = PackedStringArray()

## Está en déficit de comida (la población decrece). Lo fija el integrador.
var starving: bool = false
## Gobernador al mando, o `null` si lo lleva el jugador.
var governor: Governor = null
## Ciclo en el que el gobernador revisó decisiones por última vez.
var governor_last_cycle: float = 0.0
## 🎖️ Sellado (plan Gobernador por sello): con 🎖️ Consejo, el nodo se puede delegar. Es permanente:
## retomar el mando no lo quita y volver a delegar no gasta otro sello. Lo pone `GovernorSys.seal`,
## y `Promotion.arrive` a las colonias que nacen delegadas. **No** lo mira `GovernorSys.delegate`,
## que es la primitiva: la puerta es `GovernorSys.delegate_blocker`. Esquema 6.
var governor_unlocked: bool = false

## ⚡ Ritmo propio del nodo (plan Objetos de tiempo). Con un boost `k`, cada tramo de `span` ciclos
## globales el nodo avanza `k·span` ciclos **suyos**: producción, consumo, crecimiento, su
## gobernador y su expedición en camino. 1 es sin boost. Se apaga en `boost_until`, que es ciclo
## **global**: es lo único del boost que no se dilata (`SimEngine.tick` parte el tramo ahí).
## Entran en el save y en el `state_hash` (esquema 5); un save v4 carga sin boost.
var boost_factor: float = 1.0
var boost_until: float = 0.0
## Reloj propio, en ciclos del nodo: avanza `k·span` por tramo, y con él cuenta el gobernador
## (`GovernorSys.run`). En un nodo que nunca ha tenido boost es **igual** a `state.cycle`, bit a
## bit (`SimEngine._advance_all`), así que un nodo que no se acelera decide como siempre.
var local_cycle: float = 0.0

## Caché recalculada tras cada tick — nunca se serializa, se deriva.
var total_pop: float = 0.0
## Suma de los caudales de las rutas que tocan este nodo (− lo que sale, + lo que entra), por
## recurso. La fija `Logistics` y **no se guarda**: se deriva de `WorldState.routes`. Vacío si el
## nodo no tiene rutas, y entonces el integrador ni lo mira.
var route_offset := PackedFloat64Array()

## Efectos de las mejoras, cacheados. `housing()`, `storage_caps()` y `capacity_of()` se
## llaman en bucles calientes del HUD y del integrador, así que no se recalculan cada vez.
var _effects: Upgrades.Effects = null


## Multiplicadores de las mejoras de este nodo. Se recalcula solo cuando cambian.
func effects() -> Upgrades.Effects:
	if _effects == null:
		_effects = Upgrades.compute(upgrades)
	return _effects


func invalidate_effects() -> void:
	_effects = null


static func create(node_id: int, node_tier: int, node_seed: int, node_name: String) -> SimNode:
	var n := SimNode.new()
	n.id = node_id
	n.tier = node_tier
	n.seed = node_seed
	n.name = node_name
	var count := Content.building_count()
	n.buildings.resize(count)
	n.jobs.resize(count)
	n.stocks = Goods.zeros()
	return n


func building_total() -> int:
	var total := 0
	for c in buildings:
		total += c
	return total


func is_delegated() -> bool:
	return governor != null


func def() -> TierDef:
	return Content.tier(tier)


## Puestos de trabajo que caben en un tipo de edificio, con las mejoras aplicadas.
##
## Vive aquí y no en `Construction` a propósito: lo necesitan tanto el integrador como la UI,
## y ponerlo en un sistema creaba un ciclo `Integrator` ⇄ `Construction` que GDScript no puede
## resolver. Es una propiedad del nodo, así que este es su sitio.
func capacity_of(building_index: int) -> float:
	var b := Content.building(building_index)
	if not b.is_workplace():
		return 0.0
	return b.worker_slots * float(buildings[building_index]) \
		* effects().slots[building_index]


## Capacidad de alojamiento: el techo al que tiende la población.
func housing(params: SimParams) -> float:
	var h := params.base_housing
	for i in buildings.size():
		if buildings[i] > 0:
			h += Content.building(i).housing * float(buildings[i])
	return h * effects().housing


## Tope de almacenamiento por recurso (INF para los recursos acumulativos).
func storage_caps(params: SimParams) -> PackedFloat64Array:
	# El tope sube con la escala. Es lo que impide que la economía se estrangule sola: los
	# costes crecen en progresión geométrica y el tope, sumando almacenes, solo linealmente
	# (ver `SimParams.storage_per_tier`). Multiplica el tope entero —base y almacenes—, no solo
	# la base, o subir de escala apenas se notaría.
	var multiplier := effects().storage * pow(params.storage_per_tier, float(tier))
	var caps := Goods.zeros()
	for i in Goods.COUNT:
		caps[i] = INF if i in Goods.UNCAPPED else params.base_storage * multiplier
	for bi in buildings.size():
		var count := buildings[bi]
		if count <= 0:
			continue
		var st := Content.building(bi).storage
		for i in Goods.COUNT:
			if caps[i] != INF:
				caps[i] += st[i] * float(count) * multiplier
	return caps


func duplicate_node() -> SimNode:
	var n := SimNode.new()
	n.id = id
	n.tier = tier
	n.parent_id = parent_id
	n.children = children.duplicate()
	n.seed = seed
	n.name = name
	n.pop = pop
	n.stocks = stocks.duplicate()
	n.buildings = buildings.duplicate()
	n.jobs = jobs.duplicate()
	n.upgrades = upgrades.duplicate()
	n.starving = starving
	n.governor = governor.duplicate_governor() if governor != null else null
	n.governor_last_cycle = governor_last_cycle
	n.governor_unlocked = governor_unlocked
	# La sonda de `Logistics._first_breach` avanza copias: sin el ritmo, predeciría el corte con
	# el reloj de otro.
	n.boost_factor = boost_factor
	n.boost_until = boost_until
	n.local_cycle = local_cycle
	n.total_pop = total_pop
	n.route_offset = route_offset.duplicate()
	return n


func to_dict() -> Dictionary:
	var d := {
		"id": id,
		"tier": tier,
		"parent": parent_id,
		"children": Array(children),
		"seed": seed,
		"name": name,
		"pop": pop,
		"stocks": Array(stocks),
		"buildings": Array(buildings),
		"jobs": Array(jobs),
		"upgrades": Array(upgrades),
		"starving": starving,
		"gov_cycle": governor_last_cycle,
		"gov_unlocked": governor_unlocked,
		"boost_factor": boost_factor,
		"boost_until": boost_until,
		"local_cycle": local_cycle,
	}
	if governor != null:
		d["governor"] = governor.to_dict()
	return d


## `world_cycle` es el reloj del mundo del save: el `local_cycle` de un nodo que no lo trae (save v4).
static func from_dict(d: Dictionary, world_cycle: float = 0.0) -> SimNode:
	var n := SimNode.new()
	n.id = int(d["id"])
	n.tier = int(d["tier"])
	n.parent_id = int(d["parent"])
	n.children = PackedInt32Array(d["children"])
	n.seed = int(d["seed"])
	n.name = String(d["name"])
	n.pop = float(d["pop"])
	n.stocks = PackedFloat64Array(d["stocks"])
	n.buildings = PackedInt32Array(d["buildings"])
	n.jobs = PackedFloat64Array(d["jobs"])
	# Saves anteriores a las mejoras simplemente no traen ninguna: no hace falta migración.
	n.upgrades = PackedStringArray(d.get("upgrades", []))
	n.starving = bool(d["starving"])
	n.governor_last_cycle = float(d.get("gov_cycle", 0.0))
	if d.has("governor"):
		n.governor = Governor.from_dict(d["governor"])
	# 🎖️ Un save v5 no lo trae: la migración 5 → 6 (`Save.migrate`) sella los delegados; si llega
	# hasta aquí sin la clave (un dict suelto de test), el nodo no está sellado.
	n.governor_unlocked = bool(d.get("gov_unlocked", false))
	# ⚡ Un save v4 no trae ritmo: el nodo carga sin boost y al paso del mundo.
	n.boost_factor = float(d.get("boost_factor", 1.0))
	n.boost_until = float(d.get("boost_until", 0.0))
	n.local_cycle = float(d.get("local_cycle", world_cycle))
	# El catálogo puede haber crecido entre versiones: los arrays por edificio se reajustan.
	var count := Content.building_count()
	if n.buildings.size() != count:
		n.buildings.resize(count)
	if n.jobs.size() != count:
		n.jobs.resize(count)
	# Y el de recursos: un save de antes del transporte trae seis stocks. Los recursos nuevos van
	# siempre al final de `Goods`, así que rellenar con ceros no mueve ningún índice y el estado
	# que había queda bit a bit; no hace falta subir el esquema (ver `save_test`).
	if n.stocks.size() < Goods.COUNT:
		n.stocks.resize(Goods.COUNT)
	return n
