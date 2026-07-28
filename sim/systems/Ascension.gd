class_name Ascension
extends RefCounted

## Prestigio. **Ortogonal al eje de escala**: ascender no es llegar a planeta, es reiniciar el
## árbol para volver a subirlo más rápido. Si la ascensión fuese el final del eje vertical,
## las dos progresiones competirían entre sí en vez de multiplicarse.

## Bonos activos derivados del árbol de legado. Se calculan una vez por tick, no por nodo.
class Bonuses:
	extends RefCounted
	var production: float = 1.0
	var food: float = 1.0
	var growth: float = 1.0
	var housing: float = 1.0
	var offline_cap_seconds: float = 0.0
	var offline_rate: float = 0.0
	var governor: float = 0.0
	var start_goods: float = 0.0


## Rangos comprados de cada nodo de legado.
static func ranks(state: WorldState) -> Dictionary:
	var out := {}
	for id in state.legacy_nodes:
		out[id] = int(out.get(id, 0)) + 1
	return out


static func bonuses(state: WorldState) -> Bonuses:
	var b := Bonuses.new()
	var owned := ranks(state)
	for id in owned:
		var def: Legacy.Node_ = Legacy.get_node_def(id)
		if def == null:
			continue
		var total: float = def.per_rank * float(owned[id])
		match def.effect:
			Legacy.Effect.PRODUCTION: b.production += total
			Legacy.Effect.FOOD: b.food += total
			Legacy.Effect.GROWTH: b.growth += total
			Legacy.Effect.HOUSING: b.housing += total
			Legacy.Effect.OFFLINE_CAP: b.offline_cap_seconds += total * 3600.0
			Legacy.Effect.OFFLINE_RATE: b.offline_rate += total
			Legacy.Effect.GOVERNOR: b.governor += total
			Legacy.Effect.START_LEGACY: b.start_goods += total
	return b


## Legado que se llevaría el jugador si ascendiese ahora.
##
## Raíz cuadrada de la población pico (la curva clásica del género: el prestigio premia
## seguir jugando pero con rendimientos decrecientes) por el tier máximo alcanzado.
static func reward(state: WorldState) -> float:
	if state.peak_pop < 1000.0:
		return 0.0
	return floor(sqrt(state.peak_pop / 1000.0) * float(1 + state.peak_tier))


static func can_ascend(state: WorldState) -> bool:
	return reward(state) >= 1.0


## Reinicia el árbol conservando legado y nodos comprados. Devuelve el estado nuevo.
static func ascend(state: WorldState, params: SimParams, events: SimEventLog) -> WorldState:
	if not can_ascend(state):
		return state
	var gained := reward(state)
	var fresh := WorldState.create(state.world_seed + state.era, params)
	fresh.legacy = state.legacy + gained
	fresh.legacy_nodes = state.legacy_nodes.duplicate()
	fresh.era = state.era + 1
	var b := bonuses(fresh)
	if b.start_goods > 0.0:
		var root := fresh.root()
		root.stocks[Goods.FOOD] += b.start_goods
		root.stocks[Goods.WOOD] += b.start_goods
	if events != null:
		events.push("ascension", state.cycle, -1,
			"Asciendes a la era %d con %d de legado" % [fresh.era, int(gained)],
			{"gained": gained, "era": fresh.era, "peak_tier": state.peak_tier})
	return fresh


static func rank_of(state: WorldState, id: String) -> int:
	return int(ranks(state).get(id, 0))


static func can_buy(state: WorldState, id: String) -> bool:
	var def: Legacy.Node_ = Legacy.get_node_def(id)
	if def == null:
		return false
	var rank := rank_of(state, id)
	return rank < def.max_ranks and state.legacy >= def.cost_for(rank)


static func buy(state: WorldState, id: String, events: SimEventLog) -> bool:
	if not can_buy(state, id):
		return false
	var def: Legacy.Node_ = Legacy.get_node_def(id)
	state.legacy -= def.cost_for(rank_of(state, id))
	state.legacy_nodes.append(id)
	if events != null:
		events.push("legacy", state.cycle, -1, "Legado: %s" % def.name, {"id": id})
	return true
