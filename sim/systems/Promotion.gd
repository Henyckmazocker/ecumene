class_name Promotion
extends RefCounted

## Promoción de escala y fundación de hijos: el eje vertical del juego.
##
## Un nodo **promociona en el sitio** (`tier += 1`): tu asentamiento *se convierte* en pueblo
## conservando población, stocks y edificios. No aparece un padre vacío por encima.
##
## El anidamiento sale de la regla del techo: **un hijo nunca puede alcanzar el tier de su
## padre**. Cuando la raíz sube a región, sus hijos pueden llegar hasta ciudad, y los hijos
## de estos hasta pueblo. Así una región acaba conteniendo varias ciudades, cada una con sus
## pueblos — la estructura fractal que pide el diseño, sin código por escala.


static func can_promote(state: WorldState, node: SimNode) -> bool:
	var tier_def := node.def()
	if not tier_def.can_promote(node.total_pop, node.building_total()):
		return false
	return node.tier < tier_ceiling(state, node)


## Tier máximo al que puede llegar este nodo: uno menos que su padre (la raíz no tiene techo).
static func tier_ceiling(state: WorldState, node: SimNode) -> int:
	if node.parent_id < 0:
		return Content.TIER_COUNT - 1
	var parent: SimNode = state.get_node_by_id(node.parent_id)
	if parent == null:
		return Content.TIER_COUNT - 1
	return parent.tier - 1


static func promote(state: WorldState, node: SimNode, events: SimEventLog) -> bool:
	if not can_promote(state, node):
		return false
	var from_name := node.def().name
	node.tier += 1
	var to_def := node.def()
	state.peak_tier = maxi(state.peak_tier, node.tier)
	if events != null:
		events.push("promotion", state.cycle, node.id,
			"%s asciende de %s a %s" % [node.name, from_name, to_def.name],
			{"tier": node.tier, "unlocks": to_def.unlocks})
	return true


## Plazas de hijos libres.
static func free_slots(node: SimNode) -> int:
	if node.tier <= Content.SETTLEMENT:
		return 0
	return maxi(0, node.def().child_slots - node.children.size())


static func can_found_child(state: WorldState, node: SimNode, params: SimParams) -> bool:
	if free_slots(node) <= 0:
		return false
	# Fundar cuesta colonos y provisiones: sale del núcleo, no de la nada.
	return node.pop >= _settler_pop(params) * 2.0 and node.stocks[Goods.FOOD] >= _settler_food(params)


## Funda un hijo un tier por debajo del padre, poblado con colonos del núcleo.
static func found_child(
	state: WorldState, node: SimNode, params: SimParams, events: SimEventLog
) -> SimNode:
	if not can_found_child(state, node, params):
		return null
	var child := state.add_node(node.tier - 1, node.id)
	var settlers := _settler_pop(params)
	node.pop -= settlers
	node.stocks[Goods.FOOD] -= _settler_food(params)
	child.pop = settlers
	child.stocks[Goods.FOOD] = _settler_food(params)
	child.buildings[Content.building_index("farm")] = 1
	child.buildings[Content.building_index("woodcutter")] = 1
	child.jobs[Content.building_index("farm")] = 1.0
	child.jobs[Content.building_index("woodcutter")] = 1.0
	if events != null:
		events.push("found", state.cycle, child.id,
			"%s funda %s" % [node.name, child.name],
			{"parent": node.id, "tier": child.tier})
	return child


static func _settler_pop(params: SimParams) -> float:
	return params.initial_pop * 2.0


static func _settler_food(params: SimParams) -> float:
	return 50.0
