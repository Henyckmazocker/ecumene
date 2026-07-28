class_name GovernorSys
extends RefCounted

## Evaluación de gobernadores. Se ejecuta en **checkpoints** (cada `governor_interval`
## ciclos), no en cada tick: así el catch-up offline de un imperio delegado sigue costando
## un número acotado de decisiones en vez de una por ciclo.
##
## Todas las decisiones salen por `Construction` y `Promotion`, las mismas funciones que usa
## el jugador.

## Prioridades del gobernador, en el orden de `Governor.normalized()`.
const P_FOOD := 0
const P_GROWTH := 1
const P_INDUSTRY := 2
const P_EXPANSION := 3


## Ejecuta los checkpoints pendientes de un nodo delegado. Devuelve cuántos se evaluaron.
static func run(
	state: WorldState, node: SimNode, params: SimParams, events: SimEventLog
) -> int:
	if not node.is_delegated():
		return 0
	var interval := maxf(params.governor_interval, 1.0)
	var due := int(floor((state.cycle - node.governor_last_cycle) / interval))
	if due <= 0:
		return 0
	# Acotado: un mes offline no dispara miles de decisiones retroactivas.
	due = mini(due, 64)
	for _i in due:
		_decide(state, node, params, events)
	node.governor_last_cycle = state.cycle
	return due


static func _decide(
	state: WorldState, node: SimNode, params: SimParams, events: SimEventLog
) -> void:
	var w := node.governor.normalized()
	_rebalance_jobs(node, w)
	_build_best(state, node, w, events)
	if w[P_EXPANSION] > 0.25 and Promotion.can_found_child(state, node, params):
		Promotion.found_child(state, node, params, events)


## Reparte la mano de obra según las prioridades. El hambre manda: si el nodo está en
## déficit, el peso de la comida se dispara pase lo que pase en la política.
static func _rebalance_jobs(node: SimNode, w: PackedFloat64Array) -> void:
	var food_weight := w[P_FOOD]
	if node.starving:
		food_weight = maxf(food_weight, 0.7)
	for bi in node.buildings.size():
		if node.buildings[bi] <= 0:
			continue
		var b := Content.building(bi)
		if not b.is_workplace():
			continue
		if b.produces[Goods.FOOD] > 0.0:
			node.jobs[bi] = food_weight
		elif b.produces[Goods.WOOD] > 0.0:
			node.jobs[bi] = w[P_GROWTH]
		else:
			node.jobs[bi] = w[P_INDUSTRY]


## Construye el edificio más alineado con las prioridades que se pueda pagar.
static func _build_best(
	state: WorldState, node: SimNode, w: PackedFloat64Array, events: SimEventLog
) -> void:
	var best := -1
	var best_score := 0.0
	for bi in Content.buildings_for_tier(node.tier):
		if not Construction.can_build(node, bi):
			continue
		var score := _score(Content.building(bi), w, node)
		if score > best_score:
			best_score = score
			best = bi
	if best >= 0:
		Construction.build(node, best, state.cycle, events)


static func _score(b: BuildingDef, w: PackedFloat64Array, node: SimNode) -> float:
	var score := 0.0
	if b.housing > 0.0:
		score += w[P_GROWTH]
		# Sin sitio donde meter gente el crecimiento se para: prioridad si está lleno.
		if node.pop > 0.0 and node.total_pop > 0.0:
			score += w[P_GROWTH]
	if b.produces[Goods.FOOD] > 0.0:
		score += w[P_FOOD] * (2.0 if node.starving else 1.0)
	if b.produces[Goods.WOOD] > 0.0:
		score += w[P_GROWTH] * 0.5
	for good in [Goods.STONE, Goods.TOOLS, Goods.GOLD, Goods.CULTURE]:
		if b.produces[good] > 0.0:
			score += w[P_INDUSTRY]
	var storage_total := 0.0
	for v in b.storage:
		storage_total += v
	if storage_total > 0.0:
		score += w[P_INDUSTRY] * 0.4
	return score
