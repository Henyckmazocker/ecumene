class_name WorldState
extends RefCounted

## Todo el estado autoritativo de la partida, y nada más.
##
## Lección directa de BioSphera (estado disperso por los nodos de escena, identidad por
## `get_instance_id()`): aquí el modelo no sabe que existe una vista. Las escenas y la UI
## **solo leen**. Un único RNG sembrado vive dentro, así que el mundo es reproducible:
## mismo seed + misma secuencia de acciones ⇒ mismo `state_hash()`.

## 2 — `jobs` pasó de pesos relativos a número de trabajadores destinados.
## 3 — rutas entre padre e hijo (`routes`, `next_route_id`, `routes_cycle`). Un save v2 carga sin
##     ninguna: no hay nada que migrar, solo defaults.
## 4 — expediciones en camino (`expeditions`). Un save v3 carga sin ninguna.
const SCHEMA_VERSION := 4

var world_seed: int = 0
var nodes: Dictionary = {}       ## id:int -> SimNode
var root_id: int = -1
var next_id: int = 1
## Tiempo de simulación transcurrido, en ciclos.
var cycle: float = 0.0
## Tier más alto alcanzado en esta era (alimenta la recompensa de ascensión).
var peak_tier: int = 0
## Población acumulada vista en esta era, para la recompensa de ascensión.
var peak_pop: float = 0.0

## Rutas del árbol, **en orden de id** (se añaden con id creciente y borrar no reordena). Se
## iteran siempre así: sumar los caudales en otro orden cambia el último bit del `route_offset`.
## Ascender las borra con el resto del mundo; el legado no trae rutas gratis.
var routes: Array[Route] = []
## Contador propio, no `next_id`: crear una ruta no puede mover el id del próximo nodo.
var next_route_id: int = 1
## Ciclo del último checkpoint de rutas (ver `Logistics.prepare`).
var routes_cycle: float = 0.0

## Expediciones en camino, **ordenadas por (`arrive_cycle`, `parent_id`)**: es el orden en que
## llegan, y tiene que ser determinista porque cada llegada crea un nodo con el siguiente id. Una
## por nodo como mucho. Los colonos que van dentro no cuentan en `total_pop` ni en `peak_pop`:
## han salido del padre y todavía no están en ninguna parte. Ascender las borra con la era.
var expeditions: Array[Expedition] = []

@export_group("Ascensión")
## Meta-moneda persistente entre eras.
var legacy: float = 0.0
## Nodos del árbol de legado comprados (ids).
var legacy_nodes: PackedStringArray = PackedStringArray()
var era: int = 1

var rng := RandomNumberGenerator.new()

## Posición de cada nodo en el mundo (id → Vector2i). **Caché derivada, no estado**: sale de las
## semillas y del árbol, igual que el terreno, así que no entra en `to_dict` ni en `state_hash`.
## Un estado cargado (`from_dict`) o el de una era nueva (`Ascension.ascend`) es un objeto nuevo
## y nace con ella vacía.
var _pos_cache: Dictionary = {}
## Firma del árbol con que se llenó la caché: `(nodes.size(), next_id)`. Borrar un nodo baja el
## tamaño y fundar sube `next_id`, así que cualquier cambio del árbol la invalida **entera**, venga
## de donde venga el borrado (hoy `SimEngine._prune` hace `nodes.erase` a pelo). Entera y no solo
## el id muerto: un hermano de id mayor pudo colocarse lejos de él y ahora tendría otro sitio.
## Recalcular todo un árbol cuesta ~1,5 ms (M0 del plan Terreno compartido).
var _pos_cache_sig := Vector2i(-1, -1)
## Ruido del mundo, creado una vez por estado: `relief_at_world` crea un `FastNoiseLite` por
## llamada, y la colocación consulta ~50 celdas por candidato.
var _height_noise: FastNoiseLite


static func create(seed_value: int, params: SimParams) -> WorldState:
	var state := WorldState.new()
	state.world_seed = seed_value
	state.rng.seed = seed_value
	var root := state.add_node(Content.SETTLEMENT, -1)
	state.root_id = root.id
	root.pop = params.initial_pop
	root.stocks[Goods.FOOD] = 50.0
	root.stocks[Goods.WOOD] = 40.0
	root.buildings[Content.building_index("farm")] = 1
	root.buildings[Content.building_index("woodcutter")] = 1
	# Reparto **de partida**, no automático: los cinco fundadores llegan con su oficio puesto
	# (tres al campo, dos al bosque). A partir de aquí no se destina a nadie sin que lo mandes.
	root.jobs[Content.building_index("farm")] = 3.0
	root.jobs[Content.building_index("woodcutter")] = 2.0
	state.refresh_totals()
	return state


func add_node(tier: int, parent_id: int) -> SimNode:
	var id := next_id
	next_id += 1
	# Semilla derivada y estable: el terreno de un nodo no se guarda, se regenera.
	var node_seed := hash(str(world_seed, ":", id))
	var node := SimNode.create(id, tier, node_seed, NameGen.for_node(node_seed, tier))
	node.parent_id = parent_id
	nodes[id] = node
	if parent_id >= 0 and nodes.has(parent_id):
		var parent: SimNode = nodes[parent_id]
		parent.children.append(id)
	return node


func get_node_by_id(id: int) -> SimNode:
	return nodes.get(id)


func root() -> SimNode:
	return nodes.get(root_id)


## Semilla del terreno de toda la partida: la de la raíz. Un mundo por partida; cada nodo es una
## ventana suya centrada en `world_pos_of(node)`. Cambia al ascender porque la raíz es otra.
func terrain_seed() -> int:
	var r := root()
	return r.seed if r != null else 0


# ---------------------------------------------------------------------------
# Posición en el mundo (vista derivada; nunca escribe estado de simulación)
# ---------------------------------------------------------------------------

## Extensión de la que sale la separación entre hermanos, **por la profundidad del hijo** en el
## árbol: hijos de la raíz, nietos, y de ahí abajo. No por el tier del padre: ese cambia al
## promocionar y la colonia saltaría de sitio al recalcular. La profundidad no cambia nunca.
const PLACE_EXTENT_BY_DEPTH := [64.0, 48.0, 32.0]
## Candidatos por hijo. M0 midió 0 fallos con 1.024; con 64, candidato medio 1,5 y máximo 32.
const PLACE_CANDIDATES := 64
## El anillo donde cae un hijo, en celdas **más allá del núcleo del padre**
## (`Layout.core_radius` de su profundidad). Antes era 0,55-0,9 de la extensión (35-58 celdas
## de la raíz), y el `Layout` de una ciudad llenaba ±64: los pueblos caían encima de sus
## edificios. Ahora el padre construye dentro de su núcleo y los hijos van fuera, en campo
## abierto: 6 celdas de margen (la mancha de la vista agregada mide 2,5-7 de radio) y 16 de
## anchura, que con la separación entre hermanos da sitio de sobra (M3b: 500 semillas).
const PLACE_RING_INNER := 6.0
const PLACE_RING_OUTER := 22.0
## Lado del cuadrado que tiene que ser edificable alrededor del centro, y en qué proporción: así
## `Layout` tiene sitio para los primeros edificios.
const PLACE_SQUARE := 7
const PLACE_MIN_BUILDABLE := 0.80
## Separación mínima a los hermanos de id menor, en fracción de la extensión.
const PLACE_SIBLING_GAP := 0.30


## Posición del nodo en el mundo, en celdas. La raíz está en `(0, 0)`. Un hijo, en un anillo
## alrededor de su padre elegido con su semilla. Se calcula al vuelo y se guarda en caché: no
## entra en el save ni en `state_hash`, porque sale de semillas y del árbol, igual que el terreno.
func world_pos_of(node: SimNode) -> Vector2i:
	if node == null:
		return Vector2i.ZERO
	var sig := Vector2i(nodes.size(), next_id)
	if sig != _pos_cache_sig:
		_pos_cache.clear()
		_pos_cache_sig = sig
	if _pos_cache.has(node.id):
		return _pos_cache[node.id]
	var pos := Vector2i.ZERO
	var parent: SimNode = nodes.get(node.parent_id)
	if node.id != root_id and parent != null:
		pos = _place_child(node, parent)
	_pos_cache[node.id] = pos
	return pos


## Dónde caerá un hijo que **todavía no existe**: el que fundará `parent` con el id `future_id`.
## Lo usa la vista agregada para que una expedición viaje hacia su sitio de verdad.
##
## **Solo lee.** Coloca un nodo de mentira con el mismo algoritmo que `world_pos_of` (`_place_child`)
## y con la semilla que le dará `add_node`; el nodo no entra en `nodes` ni en la caché de
## posiciones. Sale exacto si al llegar los hermanos de id menor son los mismos que ahora.
func predicted_child_pos(parent: SimNode, future_id: int) -> Vector2i:
	if parent == null:
		return Vector2i.ZERO
	var ghost := SimNode.new()
	ghost.id = future_id
	ghost.parent_id = parent.id
	# La misma semilla que `add_node`: de ella sale el anillo de candidatos.
	ghost.seed = hash(str(world_seed, ":", future_id))
	ghost.name = "#%d" % future_id
	return _place_child(ghost, parent)


## Profundidad en el árbol: la raíz 0, sus hijos 1…
func depth_of(node: SimNode) -> int:
	var depth := 0
	var parent: SimNode = nodes.get(node.parent_id)
	while parent != null:
		depth += 1
		parent = nodes.get(parent.parent_id)
	return depth


## El anillo de los hijos de `parent`, en celdas desde su centro: `(interior, exterior)`. Fijo por
## la profundidad del padre, como su núcleo, así que la posición de una colonia no salta.
func child_ring(parent: SimNode) -> Vector2:
	var core := Layout.core_radius(depth_of(parent))
	return Vector2(core + PLACE_RING_INNER, core + PLACE_RING_OUTER)


func _place_child(child: SimNode, parent: SimNode) -> Vector2i:
	var p := world_pos_of(parent)
	var depth := depth_of(child)
	var e: float = PLACE_EXTENT_BY_DEPTH[clampi(depth - 1, 0, PLACE_EXTENT_BY_DEPTH.size() - 1)]
	var ring := child_ring(parent)
	# Hermanos de id menor que siguen vivos: el orden por id es el de fundación, determinista, y
	# no depende de qué se tickeó o se cargó antes.
	var older: Array[Vector2i] = []
	for sid in parent.children:
		if sid < child.id and nodes.has(sid):
			older.append(world_pos_of(nodes[sid]))
	var min_gap := PLACE_SIBLING_GAP * e
	var best := p
	var best_fraction := -1.0
	for k in PLACE_CANDIDATES:
		var angle := TAU * _frac24(hash([child.seed, k, 0]))
		var radius := lerpf(ring.x, ring.y,
				_frac24(hash([child.seed, k, 1])))
		var c := p + Vector2i(roundi(cos(angle) * radius), roundi(sin(angle) * radius))
		var crowded := false
		for o in older:
			if Vector2(c - o).length() <= min_gap:
				crowded = true
				break
		if crowded:
			continue
		if not Relief.is_buildable(_relief_at(c.x, c.y)):
			continue
		var fraction := _buildable_fraction(c)
		if fraction >= PLACE_MIN_BUILDABLE:
			return c
		if fraction > best_fraction:
			best_fraction = fraction
			best = c
	# M0 no vio nunca este caso (0 fallos con 1.024 candidatos), pero si llega, mejor un sitio
	# regular que ninguno; y que se sepa.
	push_warning("Ecumene: %s (id %d) no encuentra sitio edificable; se usa el mejor (%.0f %%)" % [
		child.name, child.id, maxf(best_fraction, 0.0) * 100.0,
	])
	return best


## Fracción edificable del cuadrado `PLACE_SQUARE`×`PLACE_SQUARE` centrado en `c`.
func _buildable_fraction(c: Vector2i) -> float:
	var half := PLACE_SQUARE / 2
	var ok := 0
	for dy in range(-half, half + 1):
		for dx in range(-half, half + 1):
			if Relief.is_buildable(_relief_at(c.x + dx, c.y + dy)):
				ok += 1
	return float(ok) / float(PLACE_SQUARE * PLACE_SQUARE)


## El mismo terreno que `TerrainGen.relief_at_world`, con el ruido creado una sola vez.
func _relief_at(wx: int, wy: int) -> int:
	if _height_noise == null:
		_height_noise = TerrainGen._make_noise(terrain_seed(), 3.0 / TerrainGen.NOISE_SCALE, 4)
	return TerrainGen.relief_at(_height_noise, float(wx), float(wy))


## 24 bits bajos de un hash, como fracción en [0, 1). Lo que validó M0.
static func _frac24(h: int) -> float:
	return float(h & 0xFFFFFF) / 16777216.0


## Ids en orden determinista (por id ascendente). Nunca iterar `nodes` directamente:
## el orden de un Dictionary no forma parte del contrato del motor.
func ordered_ids() -> PackedInt32Array:
	var ids := PackedInt32Array()
	for k in nodes.keys():
		ids.append(int(k))
	ids.sort()
	return ids


## Población de un subárbol (propia + la de todos los descendientes).
func subtree_pop(id: int) -> float:
	var node: SimNode = nodes.get(id)
	if node == null:
		return 0.0
	var total := node.pop
	for child in node.children:
		total += subtree_pop(child)
	return total


## 🎭 Influencia de un nodo: raíz cuadrada de la cultura de su subárbol. No se almacena ni se
## integra: se calcula al vuelo, con el mismo recorrido que `total_pop`, así que una ciudad con
## templos en sus pueblos también la tiene. La raíz da rendimientos decrecientes, como el legado.
## El árbol tiene pocos nodos: recorrerlo en cada `can_promote` no cuesta nada.
func influence_of(node: SimNode) -> float:
	return sqrt(maxf(_subtree_culture(node), 0.0))


func _subtree_culture(node: SimNode) -> float:
	var total := float(node.stocks[Goods.CULTURE])
	for child in node.children:
		var c: SimNode = nodes.get(child)
		if c != null:
			total += _subtree_culture(c)
	return total


## Recalcula la caché `total_pop` de todos los nodos, de las hojas hacia la raíz.
func refresh_totals() -> void:
	if root_id >= 0:
		_refresh(root_id)
	peak_pop = maxf(peak_pop, nodes[root_id].total_pop if root_id >= 0 else 0.0)


func _refresh(id: int) -> float:
	var node: SimNode = nodes[id]
	var total := node.pop
	for child in node.children:
		total += _refresh(child)
	node.total_pop = total
	return total


## La expedición que tiene en camino ese nodo, o null.
func expedition_of(node_id: int) -> Expedition:
	for e in expeditions:
		if e.parent_id == node_id:
			return e
	return null


## Mete una expedición en su sitio del orden de llegada.
func add_expedition(e: Expedition) -> void:
	var at := expeditions.size()
	for i in expeditions.size():
		var other := expeditions[i]
		if e.arrive_cycle < other.arrive_cycle \
				or (e.arrive_cycle == other.arrive_cycle and e.parent_id < other.parent_id):
			at = i
			break
	expeditions.insert(at, e)


## Ciclo de la próxima llegada, o `INF` si no hay ninguna en camino.
func next_arrival() -> float:
	return INF if expeditions.is_empty() else expeditions[0].arrive_cycle


## Saca y devuelve, en orden, todas las expediciones que llegan hasta `at_cycle` incluido.
func pop_arrivals(at_cycle: float) -> Array[Expedition]:
	var out: Array[Expedition] = []
	while not expeditions.is_empty() and expeditions[0].arrive_cycle <= at_cycle:
		out.append(expeditions.pop_front())
	return out


## Quita la expedición en camino de ese nodo, si la hay, y la devuelve.
func cancel_expedition_of(node_id: int) -> Expedition:
	for i in expeditions.size():
		if expeditions[i].parent_id == node_id:
			var e := expeditions[i]
			expeditions.remove_at(i)
			return e
	return null


## Tier máximo del árbol.
func max_tier() -> int:
	var best := 0
	for id in ordered_ids():
		best = maxi(best, nodes[id].tier)
	return best


# ---------------------------------------------------------------------------
# Determinismo
# ---------------------------------------------------------------------------

## Huella estable del estado. Mismo seed y mismas acciones ⇒ mismo valor, ciclo a ciclo.
func state_hash() -> int:
	var buf := PackedByteArray()
	buf.append_array(_i64(world_seed))
	buf.append_array(_i64(root_id))
	buf.append_array(_f64(cycle))
	for id in ordered_ids():
		var n: SimNode = nodes[id]
		buf.append_array(_i64(n.id))
		buf.append_array(_i64(n.tier))
		buf.append_array(_i64(n.parent_id))
		buf.append_array(_f64(n.pop))
		for v in n.stocks:
			buf.append_array(_f64(v))
		for v in n.buildings:
			buf.append_array(_i64(v))
		for v in n.jobs:
			buf.append_array(_f64(v))
		for upgrade_id in n.upgrades:
			buf.append_array(upgrade_id.to_utf8_buffer())
	# Solo si hay alguna: sin rutas, la huella es la de siempre.
	if not routes.is_empty():
		buf.append_array(_f64(routes_cycle))
		for r in routes:
			buf.append_array(_i64(r.id))
			buf.append_array(_i64(r.from_id))
			buf.append_array(_i64(r.to_id))
			buf.append_array(_i64(r.good))
			buf.append_array(_f64(r.rate))
			buf.append_array(_f64(r.flow))
	# Igual con las expediciones: sin ninguna en camino, la huella no cambia. La política y el
	# actor no entran, como no entra el gobernador de un nodo: lo que entra es lo que decide.
	if not expeditions.is_empty():
		for e in expeditions:
			buf.append_array(_i64(e.parent_id))
			buf.append_array(_f64(e.depart_cycle))
			buf.append_array(_f64(e.arrive_cycle))
			buf.append_array(_i64(e.tier))
			buf.append_array(_f64(e.pop))
			buf.append_array(_f64(e.food))
			# ⏩ Solo si se ha acelerado: una expedición sin acelerar deja la huella de siempre, y
			# un save v4 de antes de acelerar carga con el hash con que se guardó.
			if e.accelerations > 0:
				buf.append_array(_i64(e.accelerations))
	return _fnv1a(buf)


static func _i64(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(8)
	b.encode_s64(0, v)
	return b


static func _f64(v: float) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(8)
	b.encode_double(0, v)
	return b


## FNV-1a de 64 bits, con aritmética explícita para que no dependa de la plataforma.
static func _fnv1a(data: PackedByteArray) -> int:
	var h := -3750763034362895579  # 0xcbf29ce484222325 en complemento a dos
	for byte in data:
		h ^= byte
		h *= 1099511628211
	return h


# ---------------------------------------------------------------------------
# Serialización
# ---------------------------------------------------------------------------

func to_dict() -> Dictionary:
	var node_list := []
	for id in ordered_ids():
		node_list.append(nodes[id].to_dict())
	var route_list := []
	for r in routes:
		route_list.append(r.to_dict())
	var expedition_list := []
	for e in expeditions:
		expedition_list.append(e.to_dict())
	return {
		"schema": SCHEMA_VERSION,
		"seed": world_seed,
		"root": root_id,
		"next_id": next_id,
		"cycle": cycle,
		"peak_tier": peak_tier,
		"peak_pop": peak_pop,
		"legacy": legacy,
		"legacy_nodes": Array(legacy_nodes),
		"era": era,
		"rng_state": rng.state,
		"nodes": node_list,
		"routes": route_list,
		"next_route_id": next_route_id,
		"routes_cycle": routes_cycle,
		"expeditions": expedition_list,
	}


static func from_dict(d: Dictionary) -> WorldState:
	var state := WorldState.new()
	state.world_seed = int(d["seed"])
	state.root_id = int(d["root"])
	state.next_id = int(d["next_id"])
	state.cycle = float(d["cycle"])
	state.peak_tier = int(d.get("peak_tier", 0))
	state.peak_pop = float(d.get("peak_pop", 0.0))
	state.legacy = float(d.get("legacy", 0.0))
	state.legacy_nodes = PackedStringArray(d.get("legacy_nodes", []))
	state.era = int(d.get("era", 1))
	state.rng.seed = state.world_seed
	state.rng.state = int(d.get("rng_state", 0))
	for nd in d["nodes"]:
		var node := SimNode.from_dict(nd)
		state.nodes[node.id] = node
	# Un save v2 no trae rutas: carga sin ninguna, que es lo que tenía.
	for rd in d.get("routes", []):
		state.routes.append(Route.from_dict(rd))
	state.next_route_id = int(d.get("next_route_id", 1))
	state.routes_cycle = float(d.get("routes_cycle", 0.0))
	# Un save v3 no trae expediciones: carga sin ninguna en camino. Se guardan ya en orden de
	# llegada, pero se reinsertan por `add_expedition` para no fiarse del fichero.
	for ed in d.get("expeditions", []):
		state.add_expedition(Expedition.from_dict(ed))
	# `route_offset` no se guarda: se deriva aquí, para que el HUD enseñe las tasas con las rutas
	# desde el primer fotograma y no desde el primer tick.
	Logistics.compute_offsets(state)
	state.refresh_totals()
	return state
