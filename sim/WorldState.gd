class_name WorldState
extends RefCounted

## Todo el estado autoritativo de la partida, y nada más.
##
## Lección directa de BioSphera (estado disperso por los nodos de escena, identidad por
## `get_instance_id()`): aquí el modelo no sabe que existe una vista. Las escenas y la UI
## **solo leen**. Un único RNG sembrado vive dentro, así que el mundo es reproducible:
## mismo seed + misma secuencia de acciones ⇒ mismo `state_hash()`.

## 2 — `jobs` pasó de pesos relativos a número de trabajadores destinados.
const SCHEMA_VERSION := 2

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

@export_group("Ascensión")
## Meta-moneda persistente entre eras.
var legacy: float = 0.0
## Nodos del árbol de legado comprados (ids).
var legacy_nodes: PackedStringArray = PackedStringArray()
var era: int = 1

var rng := RandomNumberGenerator.new()


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
	state.refresh_totals()
	return state
