class_name SimEngine
extends Node

## Reloj de la simulación y única frontera entre la UI y el estado.
##
## Timestep fijo con acumulador fraccionario (patrón `SimulationClock` de BioSphera, ya
## depurado en Worlding): la simulación es **invariante a los FPS y a la velocidad**. Con
## `speed = 0` no corre ningún tick, así que pausar es literalmente no avanzar el tiempo.
##
## Determinismo: el tick online siempre avanza en pasos de exactamente un ciclo. Sin eso, un
## ordenador con más FPS produciría un troceado distinto del tiempo y, con él, un error de
## coma flotante distinto. El catch-up offline es la excepción deliberada: avanza de un solo
## salto porque el integrador es componible.

signal cycle_advanced(cycle: float)
signal speed_changed(index: int)
signal state_replaced(state: WorldState)

const CYCLE := 1.0
## Tope de pasos en los que se trocea un catch-up con nodos delegados.
const CATCHUP_STEPS := 64

@export var params: SimParams

var state: WorldState
var events := SimEventLog.new()

var speed_index: int = 1
var _accumulator: float = 0.0
var _running: bool = false


func _init() -> void:
	if params == null:
		params = SimParams.new()


func _ready() -> void:
	set_process(true)


## Arranca una partida nueva.
func start(seed_value: int) -> void:
	state = WorldState.create(seed_value, params)
	_accumulator = 0.0
	_running = true
	events.push("world", 0.0, state.root_id,
		"Fundas %s" % state.root().name, {"seed": seed_value})
	state_replaced.emit(state)


## Adopta un estado cargado (partida guardada, ascensión).
func adopt(new_state: WorldState) -> void:
	state = new_state
	_accumulator = 0.0
	_running = true
	state_replaced.emit(state)


func speed() -> float:
	return params.speeds[clampi(speed_index, 0, params.speeds.size() - 1)]


func set_speed_index(index: int) -> void:
	speed_index = clampi(index, 0, params.speeds.size() - 1)
	speed_changed.emit(speed_index)


func is_paused() -> bool:
	return speed() <= 0.0


func _process(delta: float) -> void:
	if not _running or state == null or is_paused():
		return
	_accumulator += delta * speed() / params.seconds_per_cycle
	# Cota anti espiral de la muerte: si el frame se ha ido, no se intenta recuperar todo.
	var budget := 240
	while _accumulator >= CYCLE and budget > 0:
		_accumulator -= CYCLE
		budget -= 1
		tick(CYCLE)


## Avanza la simulación `dt` ciclos. Es el mismo camino que usa el catch-up offline.
func tick(dt: float, offline: bool = false) -> void:
	if state == null or dt <= 0.0:
		return
	var bonus := Ascension.bonuses(state)
	var base := _modifiers(bonus)
	state.cycle += dt

	# Orden determinista: nunca se itera el Dictionary de nodos directamente.
	for id in state.ordered_ids():
		var node: SimNode = state.nodes[id]
		var mods := base
		if node.is_delegated():
			var efficiency := minf(params.governor_efficiency + bonus.governor, 1.0)
			mods = base.scaled(efficiency)
		Integrator.advance(node, params, dt, mods)

	for id in state.ordered_ids():
		GovernorSys.run(state, state.nodes[id], params, events)

	_prune(offline)
	state.refresh_totals()
	state.peak_tier = maxi(state.peak_tier, state.max_tier())
	cycle_advanced.emit(state.cycle)


## Acredita el tiempo transcurrido con el juego cerrado, en segundos reales.
## Devuelve los ciclos realmente acreditados (ya recortados por el tope).
func catch_up(elapsed_seconds: float) -> float:
	if state == null or elapsed_seconds <= 0.0:
		return 0.0
	var bonus := Ascension.bonuses(state)
	var cap := params.offline_cap_seconds + bonus.offline_cap_seconds
	var credited := minf(elapsed_seconds, cap)

	# La eficiencia offline escala **tiempo, no producción**. Escalarla como multiplicador de
	# producción parece equivalente y no lo es: el consumo de comida por habitante no se
	# escala (comer se come igual), así que al 50 % la granja producía menos de lo que come
	# su propia gente y el techo alimentario caía a cero. Resultado: cerrar el juego
	# extinguía el asentamiento. Acreditando la mitad del tiempo, la economía es idéntica a
	# la online —solo hay menos de ella—, que es justo lo que "rinde la mitad" quiere decir.
	var efficiency := minf(params.offline_efficiency + bonus.offline_rate, 1.0)
	var cycles := credited * efficiency / params.seconds_per_cycle
	if cycles <= 0.0:
		return 0.0

	# El avance del tiempo se compone; **las decisiones no**. Con un solo salto, un nodo
	# delegado crecería hasta el techo de los edificios que tenía cuando cerraste el juego y
	# el gobernador construiría todo de golpe al final, desperdiciando la ausencia entera.
	# Con nodos delegados se trocea en pasos —acotados a 64, no uno por ciclo— para que
	# construir y crecer se alternen. Sin delegar no hay decisiones que intercalar y se
	# resuelve de un salto, que es lo barato.
	var steps := 1
	if _has_delegated():
		steps = clampi(int(cycles / params.governor_interval), 1, CATCHUP_STEPS)
	var chunk := cycles / float(steps)
	for _i in steps:
		tick(chunk, true)
	events.push("offline", state.cycle, state.root_id,
		"Vuelves tras %s: %d ciclos acreditados" % [_format_span(credited), int(cycles)],
		{"seconds": credited, "cycles": cycles, "capped": elapsed_seconds > cap})
	return cycles


## Multiplicadores en vigor ahora mismo. La UI los usa para que el HUD enseñe exactamente las
## tasas que la simulación está aplicando, no una aproximación paralela.
func current_modifiers() -> Integrator.Modifiers:
	return _modifiers(Ascension.bonuses(state))


## Multiplicadores del legado. No hay variante offline: la ausencia se paga en tiempo
## acreditado (ver `catch_up`), no tocando la economía.
func _has_delegated() -> bool:
	for id in state.ordered_ids():
		if (state.nodes[id] as SimNode).is_delegated():
			return true
	return false


func _modifiers(bonus: Ascension.Bonuses) -> Integrator.Modifiers:
	var mods := Integrator.Modifiers.new()
	mods.production = bonus.production
	mods.food = bonus.food
	mods.growth = bonus.growth
	mods.housing = bonus.housing
	return mods


## Retira los nodos que han colapsado por hambruna. La raíz nunca se retira: si se vacía,
## la partida sigue con lo que queda (reiniciar es decisión del jugador, no del motor).
func _prune(offline: bool) -> void:
	for id in state.ordered_ids():
		var node: SimNode = state.nodes.get(id)
		if node == null or node.id == state.root_id:
			continue
		if node.pop > params.min_pop or not node.children.is_empty():
			continue
		var parent: SimNode = state.nodes.get(node.parent_id)
		if parent != null:
			var idx := parent.children.find(node.id)
			if idx >= 0:
				parent.children.remove_at(idx)
		state.nodes.erase(id)
		if not offline:
			events.push("collapse", state.cycle, id,
				"%s se despuebla y desaparece" % node.name, {"tier": node.tier})


static func _format_span(seconds: float) -> String:
	var hours := int(seconds) / 3600
	var minutes := (int(seconds) % 3600) / 60
	if hours > 0:
		return "%d h %d min" % [hours, minutes]
	return "%d min" % minutes
