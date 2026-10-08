class_name Ascension
extends RefCounted

## Prestigio. **Ortogonal al eje de escala**: ascender no es llegar a planeta, es reiniciar el
## árbol para volver a subirlo más rápido. Si la ascensión fuese el final del eje vertical,
## las dos progresiones competirían entre sí en vez de multiplicarse.

## Población de cúspide por debajo de la cual ascender no da nada. Es el suelo del prestigio: sin
## él, se podría ascender el primer día a cambio de cero y la mecánica no significaría nada.
const MIN_PEAK_POP := 1000.0

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
	## Tope de herederos: hasta qué profundidad del árbol (raíz = 0) funda un gobernador. Base 0,
	## solo la raíz coloniza delegando. Ver `GovernorSys._decide`.
	var heirs: int = 0
	## Multiplicador de la duración de las expediciones: `1 − 0,08 × rangos` de 🧭 Caminos
	## antiguos. Lo lee `Promotion.expedition_cycles` al salir; nunca baja de cero.
	var expedition: float = 1.0


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
			Legacy.Effect.HEIRS: b.heirs += int(total)
			Legacy.Effect.EXPEDITION: b.expedition = maxf(b.expedition - total, 0.0)
	return b


## Multiplicador del legado. Con ×1, ascender en H3 daba 3 y solo llegaba para un nodo: la era 2
## no se notaba. Con ×5 se compran varios.
const REWARD_SCALE := 5.0


## 📜 Cultura por punto de legado. La calibró M0 del plan «Sumidero de oro y cultura»: una era
## que llega a Región junta ~10,3 M de cultura, y ⌊√(10.337.828/1.000)⌋ = 101 es del orden de los 99 que
## da la población en ese momento. Así la cultura pesa como la población, sin eclipsarla.
const CULTURE_PER_LEGACY := 1000.0


## Legado que se llevaría el jugador si ascendiese ahora.
##
## Raíz cuadrada de la población pico (la curva clásica del género: el prestigio premia
## seguir jugando pero con rendimientos decrecientes) por el tier máximo alcanzado, **más** lo
## que da la cultura. Se suma aparte y no se multiplica, para que el modal pueda decir cuánto
## sale de cada lado. El suelo manda sobre las dos: bajo `MIN_PEAK_POP` no da nada, haya la
## cultura que haya, o se podría ascender el primer día a cambio de un templo.
static func reward(state: WorldState) -> float:
	if state.peak_pop < MIN_PEAK_POP:
		return 0.0
	return pop_reward(state) + culture_reward(state)


## La parte del legado que sale de la población pico y la escala alcanzada (sin el suelo: lo
## aplica `reward`). Aparte solo para poder enseñar el desglose.
static func pop_reward(state: WorldState) -> float:
	return floor(sqrt(state.peak_pop / MIN_PEAK_POP) * float(1 + state.peak_tier) * REWARD_SCALE)


## Legado por la cultura del árbol **en el momento de ascender**, no por un pico: la cultura se
## gasta en mejoras de ciudad, y lo que cuenta es lo que se deja sin gastar. Raíz cuadrada, como
## la población y la influencia: rendimientos decrecientes. Sin el suelo (lo aplica `reward`).
## `ascend` la lee antes de crear el mundo nuevo, igual que `peak_pop`.
static func culture_reward(state: WorldState) -> float:
	var root := state.root()
	if root == null:
		return 0.0
	return floor(sqrt(maxf(_tree_culture(state, root), 0.0) / CULTURE_PER_LEGACY))


## Σ 📜 del subárbol, el mismo recorrido que `WorldState.influence_of`. No se reusa su raíz al
## cuadrado: √ y luego ² pierde el último bit, y en una frontera exacta movería el ⌊⌋.
static func _tree_culture(state: WorldState, node: SimNode) -> float:
	var total := float(node.stocks[Goods.CULTURE])
	for child in node.children:
		var c: SimNode = state.nodes.get(child)
		if c != null:
			total += _tree_culture(state, c)
	return total


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


## Un nodo está desbloqueado cuando cada uno de sus requisitos tiene al menos un rango. Un save
## anterior a las ramas puede tener comprado un hijo sin su padre: los bonos se le siguen
## aplicando —esto solo gobierna las compras futuras—, así que no hace falta migrar nada.
static func is_unlocked(state: WorldState, id: String) -> bool:
	var def: Legacy.Node_ = Legacy.get_node_def(id)
	if def == null:
		return false
	var owned := ranks(state)
	for required in def.requires:
		if int(owned.get(required, 0)) <= 0:
			return false
	return true


static func can_buy(state: WorldState, id: String) -> bool:
	var def: Legacy.Node_ = Legacy.get_node_def(id)
	if def == null or not is_unlocked(state, id):
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
