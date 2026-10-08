class_name Construction
extends RefCounted

## Construcción de edificios. Sistema puro y estático: `f(state, …) -> state'`.
##
## Es **la única ruta de mutación** para construir. El jugador la llama desde la UI y el
## gobernador la llama desde su checkpoint: nadie tiene un camino privilegiado, así que
## delegar no puede divergir de jugar a mano.


## **La única puerta** al coste de un edificio: la UI, el gobernador, `ceiling_dump` y los tests
## del muro pasan por aquí. Una escala más alta paga más por todo (`TierDef.cost_scale`); un
## `cost_for` suelto pesaría el precio de aldea y el gobernador se quedaría esperando.
static func cost_of(node: SimNode, building_index: int) -> PackedFloat64Array:
	var cost := Content.building(building_index).cost_for(node.buildings[building_index])
	var scale := node.def().cost_scale
	if scale != 1.0:
		for i in cost.size():
			cost[i] *= scale
	return cost


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
	# Construir **no destina a nadie**. Una granja recién levantada está vacía hasta que el
	# jugador manda gente: el motor no reparte trabajadores por su cuenta.
	if events != null:
		events.push("build", cycle, node.id, "%s construye %s" % [node.name, b.name],
			{"building": b.id, "owned": node.buildings[building_index]})
	return true


## Puestos que caben en total en un tipo de edificio, con las mejoras aplicadas.
static func capacity_of(node: SimNode, building_index: int) -> float:
	return node.capacity_of(building_index)


## Personas que hay sin destinar a ningún oficio.
static func idle_of(node: SimNode) -> float:
	return Integrator.idle_population(node)


## Destina `count` personas a un oficio. Se recorta a los puestos que existen y a la gente
## disponible: no se puede mandar a la granja a quien no está ni a quien ya está en el taller.
##
## Única ruta para cambiar el reparto — la usan igual los botones del jugador y el gobernador.
static func set_workers(node: SimNode, building_index: int, count: float) -> float:
	var capacity := capacity_of(node, building_index)
	var current := node.jobs[building_index]
	var others := 0.0
	for bi in node.jobs.size():
		if bi != building_index:
			others += minf(node.jobs[bi], capacity_of(node, bi))
	var available := maxf(node.pop - others, 0.0)
	node.jobs[building_index] = clampf(count, 0.0, minf(capacity, available))
	return node.jobs[building_index] - current


## Añade (o quita, con `amount` negativo) trabajadores. Devuelve cuántos se movieron de
## verdad, para que la UI pueda avisar cuando ya no caben más.
static func add_workers(node: SimNode, building_index: int, amount: float) -> float:
	return set_workers(node, building_index, node.jobs[building_index] + amount)
