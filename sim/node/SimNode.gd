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

## Está en déficit de comida (la población decrece). Lo fija el integrador.
var starving: bool = false
## Gobernador al mando, o `null` si lo lleva el jugador.
var governor: Governor = null
## Ciclo en el que el gobernador revisó decisiones por última vez.
var governor_last_cycle: float = 0.0

## Caché recalculada tras cada tick — nunca se serializa, se deriva.
var total_pop: float = 0.0


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


## Capacidad de alojamiento: el techo al que tiende la población.
func housing(params: SimParams) -> float:
	var h := params.base_housing
	for i in buildings.size():
		if buildings[i] > 0:
			h += Content.building(i).housing * float(buildings[i])
	return h


## Tope de almacenamiento por recurso (INF para los recursos acumulativos).
func storage_caps(params: SimParams) -> PackedFloat64Array:
	var caps := Goods.zeros()
	for i in Goods.COUNT:
		caps[i] = INF if i in Goods.UNCAPPED else params.base_storage
	for bi in buildings.size():
		var count := buildings[bi]
		if count <= 0:
			continue
		var st := Content.building(bi).storage
		for i in Goods.COUNT:
			if caps[i] != INF:
				caps[i] += st[i] * float(count)
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
	n.starving = starving
	n.governor = governor.duplicate_governor() if governor != null else null
	n.governor_last_cycle = governor_last_cycle
	n.total_pop = total_pop
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
		"starving": starving,
		"gov_cycle": governor_last_cycle,
	}
	if governor != null:
		d["governor"] = governor.to_dict()
	return d


static func from_dict(d: Dictionary) -> SimNode:
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
	n.starving = bool(d["starving"])
	n.governor_last_cycle = float(d.get("gov_cycle", 0.0))
	if d.has("governor"):
		n.governor = Governor.from_dict(d["governor"])
	# El catálogo puede haber crecido entre versiones: los arrays por edificio se reajustan.
	var count := Content.building_count()
	if n.buildings.size() != count:
		n.buildings.resize(count)
	if n.jobs.size() != count:
		n.jobs.resize(count)
	return n
