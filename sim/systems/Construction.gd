class_name Construction
extends RefCounted

## Construcción de edificios. Sistema puro y estático: `f(state, …) -> state'`.
##
## Es **la única ruta de mutación** para construir. El jugador la llama desde la UI y el
## gobernador la llama desde su checkpoint: nadie tiene un camino privilegiado, así que
## delegar no puede divergir de jugar a mano.


static func cost_of(node: SimNode, building_index: int) -> PackedFloat64Array:
	return Content.building(building_index).cost_for(node.buildings[building_index])


static func is_available(node: SimNode, building_index: int) -> bool:
	return Content.building(building_index).tier_min <= node.tier


static func can_afford(node: SimNode, building_index: int) -> bool:
	var cost := cost_of(node, building_index)
	for i in Goods.COUNT:
		if node.stocks[i] < cost[i]:
			return false
	return true


static func can_build(node: SimNode, building_index: int) -> bool:
	return is_available(node, building_index) and can_afford(node, building_index)


static func build(node: SimNode, building_index: int, cycle: float, events: SimEventLog) -> bool:
	if not can_build(node, building_index):
		return false
	var cost := cost_of(node, building_index)
	for i in Goods.COUNT:
		node.stocks[i] -= cost[i]
	node.buildings[building_index] += 1
	var b := Content.building(building_index)
	# Un centro de trabajo nuevo sin peso asignado no recibiría gente nunca: arranca con 1.
	if b.is_workplace() and node.jobs[building_index] <= 0.0:
		node.jobs[building_index] = 1.0
	if events != null:
		events.push("build", cycle, node.id, "%s construye %s" % [node.name, b.name],
			{"building": b.id, "owned": node.buildings[building_index]})
	return true


## Reparto de mano de obra. Los pesos son relativos; el integrador los normaliza.
static func set_job_weight(node: SimNode, building_index: int, weight: float) -> void:
	node.jobs[building_index] = maxf(weight, 0.0)
