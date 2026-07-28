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
	var base := _modifiers(bonus, offline)
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
	var cycles := credited / params.seconds_per_cycle
	if cycles <= 0.0:
		return 0.0
	tick(cycles, true)
	events.push("offline", state.cycle, state.root_id,
		"Vuelves tras %s: %d ciclos acreditados" % [_format_span(credited), int(cycles)],
		{"seconds": credited, "cycles": cycles, "capped": elapsed_seconds > cap})
	return cycles


func _modifiers(bonus: Ascension.Bonuses, offline: bool) -> Integrator.Modifiers:
	var mods := Integrator.Modifiers.new()
	mods.production = bonus.production
	mods.food = bonus.food
	mods.growth = bonus.growth
	mods.housing = bonus.housing
	if offline:
		var efficiency := minf(params.offline_efficiency + bonus.offline_rate, 1.0)
		mods = mods.scaled(efficiency)
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
