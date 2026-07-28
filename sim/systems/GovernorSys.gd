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


## Urgencia que se suma al peso de la política cuando un recurso es **el cuello de botella
## real**. Tiene que dominar a las prioridades: un gobernador puede ser mediocre, no puede
## construir casas para gente a la que no da de comer.
const URGENT := 1.5


static func _decide(
	state: WorldState, node: SimNode, params: SimParams, events: SimEventLog
) -> void:
	var w := node.governor.normalized()
	# Mirar qué está limitando de verdad, con el mismo cálculo que usa la simulación.
	var snap := Integrator.snapshot(node, params)
	_rebalance_jobs(node, w, snap)
	_build_best(state, node, w, snap, params, events)
	if w[P_EXPANSION] > 0.25 and Promotion.can_found_child(state, node, params):
		Promotion.found_child(state, node, params, events)


## Reparte la mano de obra según las prioridades. La comida manda: si es ella la que pone el
## techo, su peso sube pase lo que pase en la política.
static func _rebalance_jobs(
	node: SimNode, w: PackedFloat64Array, snap: Integrator.Snapshot
) -> void:
	var food_weight := w[P_FOOD]
	if snap.food_limited:
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
	state: WorldState, node: SimNode, w: PackedFloat64Array, snap: Integrator.Snapshot,
	params: SimParams, events: SimEventLog
) -> void:
	var best := -1
	var best_score := 0.0
	for bi in Content.buildings_for_tier(node.tier):
		if not Construction.can_build(node, bi):
			continue
		var score := _score(Content.building(bi), w, node, snap, params)
		if score > best_score:
			best_score = score
			best = bi
	if best >= 0:
		Construction.build(node, best, state.cycle, events)


## La puntuación mezcla la política del jugador con el cuello de botella real.
##
## La versión anterior premiaba el alojamiento siempre, y el resultado era un gobernador que
## levantaba seis cabañas y una sola granja: alojamiento para 40 personas y comida para 7. Sin
## mirar cuál de los dos techos está por debajo, las prioridades por sí solas no bastan.
static func _score(
	b: BuildingDef, w: PackedFloat64Array, node: SimNode, snap: Integrator.Snapshot,
	params: SimParams
) -> float:
	var score := 0.0

	if b.produces[Goods.FOOD] > 0.0:
		score += w[P_FOOD]
		if snap.food_limited:
			score += URGENT

	if b.housing > 0.0:
		score += w[P_GROWTH]
		# Solo urge alojar si es el alojamiento lo que frena, y ya está casi lleno.
		if not snap.food_limited and node.pop >= snap.housing * 0.85:
			score += URGENT

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
		# Un almacén lleno es producción tirada a la basura.
		var caps := node.storage_caps(params)
		for i in Goods.COUNT:
			if caps[i] != INF and node.stocks[i] >= caps[i] - 0.001:
				score += URGENT
				break

	return score
