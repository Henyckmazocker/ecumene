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
	_catch_up_job = null
	_running = true
	_push_system("world", 0.0, state.root_id,
		"Fundas %s" % state.root().name, {"seed": seed_value})
	state_replaced.emit(state)


## Adopta un estado cargado (partida guardada, ascensión).
func adopt(new_state: WorldState) -> void:
	state = new_state
	_accumulator = 0.0
	# Adoptar otro estado tira la acreditación a medias: los pasos que quedaban eran de un
	# mundo que ya no existe (es lo que pasa al ascender).
	_catch_up_job = null
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
	# Mientras se acredita una ausencia, el tiempo no avanza por ningún otro sitio: un tick
	# online colado entre dos pasos cambiaría el troceado y el resultado dejaría de ser el
	# de un salto.
	if _catch_up_job != null:
		return
	_accumulator += delta * speed() / params.seconds_per_cycle
	# Cota anti espiral de la muerte: si el frame se ha ido, no se intenta recuperar todo.
	var budget := 240
	while _accumulator >= CYCLE and budget > 0:
		_accumulator -= CYCLE
		budget -= 1
		tick(CYCLE)


## Avanza la simulación `dt` ciclos. Es el mismo camino que usa el catch-up offline.
func tick(dt: float) -> void:
	if state == null or dt <= 0.0:
		return
	var bonus := Ascension.bonuses(state)
	var base := _modifiers(bonus)
	# Una vez por tick, no por nodo: el legado no cambia a mitad de tick.
	var delegated := base.scaled(efficiency_of(params, bonus))
	# Checkpoint de rutas con el ciclo de **antes** del avance: el caudal se fija para el tramo
	# que empieza ahora. Sin rutas no hace nada y `routed` sale vacío.
	var routed := Logistics.prepare(state, params)

	# El tramo se parte en cada llegada de una expedición: el hijo nace en el ciclo exacto y crece
	# el resto del tramo, así que tickear de 1 en 1 o de un salto da la misma colonia (regla 4).
	# Y en cada fin de ⚡ boost, por lo mismo: el nodo pasa de `k` a 1 en su ciclo exacto. Sin
	# expediciones ni boosts es un solo tramo de `dt`, como siempre. Las decisiones van después,
	# una vez.
	var target := state.cycle + dt
	var left := dt
	while true:
		var next := minf(state.next_arrival(), state.min_boost_until)
		# El reloj se pone al final del tramo **antes** de avanzarlo, como siempre: lo que se anota
		# durante el avance (una hambruna) sale con el ciclo en que acaba el tramo.
		if next > target:
			var from := state.cycle
			state.cycle = target
			if left > 0.0:
				_advance_all(from, left, routed, base, delegated)
			break
		var span := next - state.cycle
		if span > 0.0:
			var from := state.cycle
			state.cycle = next
			_advance_all(from, span, routed, base, delegated)
		left = target - state.cycle
		if state.min_boost_until <= state.cycle:
			_expire_boosts()
		for e in state.pop_arrivals(next):
			Promotion.arrive(state, e, events)

	# El gobernador decide con los mismos multiplicadores con los que se integra su nodo
	# (`delegated`): si mirase la economía sin legado ni peaje, vería otro techo y otras tasas que
	# las que de verdad avanzan, y fundaría o construiría a destiempo.
	for id in state.ordered_ids():
		GovernorSys.run(state, state.nodes[id], params, events, delegated)

	# ⌛ Goteo: mira `state.cycle`, así que da lo mismo de 1 en 1, de un salto o troceado.
	Shop.drip(state, params, events)

	_prune()
	state.refresh_totals()
	state.peak_tier = maxi(state.peak_tier, state.max_tier())
	cycle_advanced.emit(state.cycle)


## Un tramo sin llegadas: los nodos con rutas juntos y el resto cada uno con
## `Integrator.advance`. Es el cuerpo de `tick` de antes de las expediciones, partido para que un
## hijo pueda nacer entre dos tramos.
##
## ⚡ Un nodo con boost `k` integra `k·span` (y sus rutas, `Logistics.advance_routed`, a `1/k`):
## como la producción es lineal y el integrador tiene forma cerrada, N×1 == N sigue en pie.
## `from` es el ciclo en que empieza el tramo; `state.cycle` ya está en el final.
func _advance_all(
	from: float, span: float, routed: PackedInt32Array, base: Integrator.Modifiers,
	delegated: Integrator.Modifiers
) -> void:
	# Los nodos con rutas avanzan juntos, porque una ruta se corta en los dos extremos a la vez
	# (ver `Logistics`). Cada uno sigue avanzando solo con `Integrator.advance`; lo único que
	# comparten es el instante del corte.
	var was_routed_starving := {}
	if not routed.is_empty():
		for id in routed:
			was_routed_starving[id] = (state.nodes[id] as SimNode).starving
		Logistics.advance_routed(state, params, span, routed, base, delegated)

	# Orden determinista: nunca se itera el Dictionary de nodos directamente.
	for id in state.ordered_ids():
		var node: SimNode = state.nodes[id]
		# El flanco se mira con el valor de antes del avance, guardado aquí y no en el nodo: un
		# campo nuevo cambiaría el save y el `state_hash` por algo que solo es un aviso.
		var was_starving: bool = was_routed_starving.get(id, node.starving)
		if not was_routed_starving.has(id):
			Integrator.advance(node, params, span * node.boost_factor,
				delegated if node.is_delegated() else base)
		_advance_local_clock(node, from, span)
		if node.starving and not was_starving and node.is_delegated():
			_warn_famine(node)


## El reloj propio del nodo avanza `k·span`. Un nodo al paso del mundo (sin boost y con el reloj en
## `from`, o detrás si alguien ha movido `state.cycle` a mano) **copia** `state.cycle` en vez de
## sumar: `from + span` puede caer a un ulp del final del tramo, y entonces la cadencia del
## gobernador —que antes contaba con `state.cycle`— cambiaría por un bit. Así, sin boost,
## `local_cycle == state.cycle` siempre y nada de lo de antes se mueve. Un nodo que tuvo boost va
## por delante del mundo, y ese suma.
func _advance_local_clock(node: SimNode, from: float, span: float) -> void:
	if node.boost_factor == 1.0 and node.local_cycle <= from:
		node.local_cycle = state.cycle
	else:
		node.local_cycle += span * node.boost_factor


## Apaga los ⚡ boosts que acaban en este ciclo. No toca ninguna expedición: `Expedition.arrival`
## ya contó con el fin del boost al calcular la llegada.
func _expire_boosts() -> void:
	for id in state.ordered_ids():
		var node: SimNode = state.nodes[id]
		if node.boost_factor != 1.0 and node.boost_until <= state.cycle:
			node.boost_factor = 1.0
			node.boost_until = 0.0
	state.refresh_boost_end()


## ⚡ Pone `node` a ritmo `factor` durante `cycles` ciclos **globales** desde ahora. Es la operación
## entera de usar un boost, sin pagar nada: la llamarán `Shop.use_boost` (M3 del plan) y los tests.
## Vive aquí porque es del reloj, como partir el tramo y expirarlo; es estática y pura, como los
## sistemas, para que tienda y tests la llamen sin motor.
##
## **No se apila:** con un boost activo se queda el mayor de los dos factores y la duración se
## renueva desde ahora, no se suma. La expedición en camino del nodo, si la hay, se recalcula en
## forma cerrada —lo que le quedaba en ciclos del nodo con el ritmo viejo, y su llegada con el
## nuevo— y se saca y se vuelve a meter, como ⏩ (`Promotion.accelerate_expedition`): puede
## adelantar a otra en el orden de llegada.
static func apply_boost(state_: WorldState, node: SimNode, factor: float, cycles: float) -> void:
	var now := state_.cycle
	var e := state_.cancel_expedition_of(node.id)
	var left := 0.0
	if e != null:
		left = Expedition.remaining_local(e.arrive_cycle, now, node.boost_factor, node.boost_until)
	node.boost_factor = maxf(node.boost_factor, factor)
	node.boost_until = now + cycles
	if e != null:
		e.arrive_cycle = Expedition.arrival(now, left, node.boost_factor, node.boost_until)
		state_.add_expedition(e)
	state_.refresh_boost_end()


## Informe de la última ausencia acreditada, para la pantalla de vuelta. `null` si no hubo.
var last_offline: OfflineReport = null

## Acreditación en curso, si la hay. Mientras exista, el tick normal no corre: ver `_process`.
var _catch_up_job: CatchUpJob = null


## Una acreditación de ausencia a medias.
##
## Existe para poder acreditar **repartido entre fotogramas** y enseñar una barra en vez de
## colgar el juego un cuarto de minuto. Lo que la hace inofensiva es que el troceado se decide
## de una vez en `begin_catch_up` y no vuelve a tocarse: los fotogramas cambian *cuándo* se dan
## los pasos, nunca *cuáles*, así que acreditar en uno o en cincuenta da el mismo estado bit a
## bit que el bucle de un tirón. `catchup_test.gd` es el que no deja que eso deje de ser verdad.
class CatchUpJob extends RefCounted:
	## Pasos en los que está troceada la ausencia, y ciclos de cada paso.
	var steps: int = 1
	var chunk: float = 0.0
	var done: int = 0
	## Segundos acreditados (ya recortados por el tope) y ciclos que salen de ellos.
	var credited: float = 0.0
	var cycles: float = 0.0
	var capped: bool = false
	## Foto del estado antes del primer paso, para el informe de vuelta.
	var before: Dictionary = {}
	## Si ya se compuso el informe. Cerrar dos veces la misma ausencia dejaría dos anuncios de
	## vuelta en el diario, y quien conduce la acreditación puede llamar de más (ver el mínimo
	## de tiempo que la barra se queda en pantalla).
	var reported: bool = false
	## ⌛ Es un salto (`begin_skip`), no una ausencia: tiempo online, y al acabar no se compone
	## `OfflineReport` ni se anota la vuelta. `credited` son entonces los segundos que avanza.
	var is_skip: bool = false

	func progress() -> float:
		return float(done) / float(maxi(steps, 1))

	func is_done() -> bool:
		return done >= steps


## Acredita el tiempo transcurrido con el juego cerrado, en segundos reales, de un tirón.
## Devuelve los ciclos realmente acreditados (ya recortados por el tope).
func catch_up(elapsed_seconds: float) -> float:
	var job := begin_catch_up(elapsed_seconds)
	if job == null:
		return 0.0
	while not advance_catch_up(job, 0.0):
		pass
	return job.cycles


## Prepara la acreditación de una ausencia y **no da ningún paso**. `null` si no hay nada que
## acreditar. Aquí se decide el troceado entero; a partir de este punto ya no depende de nada
## externo, y por eso da igual en cuántos fotogramas se consuma.
func begin_catch_up(elapsed_seconds: float) -> CatchUpJob:
	if state == null or elapsed_seconds <= 0.0:
		return null
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
		return null
	return _job_for(cycles, credited, elapsed_seconds > cap)


## ⌛ Prepara un salto de `cycles` ciclos y **no da ningún paso**, como `begin_catch_up`. Es tiempo
## online: sin tope y a eficiencia 1, así que solo comparte con la ausencia el troceado
## (`_job_for`) y la barra. Los pasos siguen siendo `tick(chunk)` (regla 4), y el goteo, que mira
## `state.cycle`, corre dentro del salto como fuera. `null` si no hay nada que saltar o si ya hay
## una acreditación a medias: dos troceados a la vez no son un troceado.
func begin_skip(cycles: float) -> CatchUpJob:
	if state == null or cycles <= 0.0 or _catch_up_job != null:
		return null
	var job := _job_for(cycles, cycles * params.seconds_per_cycle, false)
	job.is_skip = true
	return job


## ⌛ Por qué no se puede usar el salto `id` ahora; vacío si se puede. El motor sabe lo que el
## estado no: si hay una acreditación a medias.
func skip_blocker(id: String) -> String:
	if state == null:
		return "no hay partida"
	return Shop.use_blocker(state, state.root(), id, false, _catch_up_job != null)


## ⌛ Gasta el salto `id` (`Shop.spend_skip`, anotado sobre `node`) y prepara su troceado. `null`
## si no se puede (`skip_blocker`). Quien conduce consume el trabajo con `advance_catch_up`, igual
## que una ausencia: `Main.use_skip` lo engancha a la barra.
func use_skip(id: String, node: SimNode = null) -> CatchUpJob:
	if not skip_blocker(id).is_empty():
		return null
	var cycles := Shop.spend_skip(state, node if node != null else state.root(), id, events)
	return begin_skip(cycles)


## Trocea `cycles` ciclos en pasos y guarda la foto de `before`. Es la mitad de `begin_catch_up`
## que no sabe de dónde salen los ciclos: la comparten la ausencia y el ⌛ salto.
func _job_for(cycles: float, credited: float, capped: bool) -> CatchUpJob:
	# El avance del tiempo se compone; **las decisiones no**. Con un solo salto, un nodo
	# delegado crecería hasta el techo de los edificios que tenía cuando cerraste el juego y
	# el gobernador construiría todo de golpe al final, desperdiciando la ausencia entera.
	# Con nodos delegados se trocea en pasos —acotados a 64, no uno por ciclo— para que
	# construir y crecer se alternen. Sin delegar no hay decisiones que intercalar y se
	# resuelve de un salto, que es lo barato.
	#
	# Con rutas, lo mismo y por otra razón: el caudal se fija en cada checkpoint, y un salto de
	# 40.000 ciclos con el caudal del primero regalaría o robaría recursos. Cada paso dura al menos
	# un `governor_interval`, así que cada uno empieza con su checkpoint de rutas.
	var job := CatchUpJob.new()
	job.steps = 1
	if _has_delegated() or not state.routes.is_empty():
		job.steps = clampi(int(cycles / params.governor_interval), 1, CATCHUP_STEPS)
	job.chunk = cycles / float(job.steps)
	job.credited = credited
	job.cycles = cycles
	job.capped = capped
	job.before = OfflineReport.snapshot(state)
	_catch_up_job = job
	return job


## Da al menos un paso de la acreditación, y todos los que quepan enteros en `budget_msec`
## (con `0.0`, todos los que queden). Devuelve `true` cuando ya no queda nada.
##
## Los pasos se dan **enteros**: partir uno para que cupiera en el presupuesto cambiaría el
## troceado, y con él el resultado.
func advance_catch_up(job: CatchUpJob, budget_msec: float = 0.0) -> bool:
	if job == null or job.reported:
		return true
	var deadline := Time.get_ticks_usec() + int(budget_msec * 1000.0)
	while not job.is_done():
		tick(job.chunk)
		job.done += 1
		if budget_msec > 0.0 and Time.get_ticks_usec() >= deadline:
			break
	if not job.is_done():
		return false

	job.reported = true
	if _catch_up_job == job:
		_catch_up_job = null
	# Un ⌛ no es una vuelta: ni informe ni anuncio (lo cuenta `item_used`, anotado al usarlo).
	if job.is_skip:
		return true
	last_offline = OfflineReport.build(job.before, state, params, job.credited, job.cycles,
		job.capped, governor_efficiency())
	_push_system("offline", state.cycle, state.root_id,
		"Vuelves tras %s: %d ciclos acreditados" % [
			OfflineReport.span(job.credited), int(job.cycles)],
		{"seconds": job.credited, "cycles": job.cycles, "capped": job.capped})
	return true


## Lo que rinde un nodo delegado, en `[0, 1]`: el rendimiento base de `SimParams` más lo que
## le suma el legado (🎓 Escuela de gobernadores), con tope en 1.
##
## Es **la única fuente** de ese número. La aplica `tick`, la enseña el HUD y la cita el informe
## de vuelta: antes cada uno leía `params.governor_efficiency` a su modo y la UI decía 85 % cuando
## se rendía al 93.
func governor_efficiency() -> float:
	return efficiency_of(params, Ascension.bonuses(state))


## La misma cuenta sin motor, para quien solo tiene el estado a mano (el HUD).
static func governor_efficiency_for(state_: WorldState, params_: SimParams) -> float:
	return efficiency_of(params_, Ascension.bonuses(state_))


static func efficiency_of(params_: SimParams, bonus: Ascension.Bonuses) -> float:
	return minf(params_.governor_efficiency + bonus.governor, 1.0)


## Multiplicadores con los que se simula un nodo delegado: legado × peaje. La misma cuenta que
## `tick`, sin motor, para que el gobernador decida sobre lo que de verdad se integra (y para
## quien lo llame suelto, como los tests que invocan `GovernorSys.run` sin pasar por `tick`).
static func delegated_modifiers(state_: WorldState, params_: SimParams) -> Integrator.Modifiers:
	var bonus := Ascension.bonuses(state_)
	return _modifiers(bonus).scaled(efficiency_of(params_, bonus))


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


static func _modifiers(bonus: Ascension.Bonuses) -> Integrator.Modifiers:
	var mods := Integrator.Modifiers.new()
	mods.production = bonus.production
	mods.food = bonus.food
	mods.growth = bonus.growth
	mods.housing = bonus.housing
	return mods


## Retira los nodos que han colapsado por hambruna. La raíz nunca se retira: si se vacía,
## la partida sigue con lo que queda (reiniciar es decisión del jugador, no del motor).
func _prune() -> void:
	var pruned := false
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
		pruned = true
		# Sus rutas se van con él, en el mismo paso: el siguiente checkpoint no puede encontrarse
		# una ruta con un extremo que ya no existe.
		Logistics.drop_routes_of(state, id)
		# Y su expedición en camino, si la tenía: los colonos se pierden. No se adopta en el
		# abuelo, que no la mandó, y un hijo no puede nacer con un padre que ya no existe.
		var lost := state.cancel_expedition_of(id)
		# También durante la acreditación: el log no es estado, así que anotarlo no mueve el
		# `state_hash`, y sin él nadie podía contar que una colonia murió mientras no estabas
		# (`Analytics._count_offline` veía siempre cero). El diario no se llena igual:
		# `Main._on_event` calla mientras dura la barra.
		var data := {"tier": node.tier}
		var text := "%s se despuebla y desaparece" % node.name
		if lost != null:
			data["expedition_lost"] = lost.pop
			text += ", y con él la expedición que había mandado"
		_push_system("collapse", state.cycle, id, text, data)
	# Su boost se va con él, pero la caché del próximo fin podría seguir apuntándole.
	if pruned:
		state.refresh_boost_end()


## Un nodo delegado acaba de **entrar** en hambruna: se anota una vez por episodio, no por ciclo,
## porque lo que se avisa es el cambio. Solo delegado: el que lleva el jugador ya lo tiene
## delante en rojo, y aquí lo que se denuncia es al gobernador que lo deja pasar.
##
## Sale como `system` y no como `governor`: nadie lo decide, es lo que la simulación constata.
## No va a Augur (`Analytics._on_event` lo descarta en su `_:`).
func _warn_famine(node: SimNode) -> void:
	_push_system("famine", state.cycle, node.id,
		"⚠️ %s pasa hambre y su gobernador no lo remedia" % node.name, {"tier": node.tier})


## Lo que anota el propio motor —fundar el mundo, acreditar una ausencia, un colapso— no lo
## decide nadie: sale con el actor `system`, y el actor de antes se restaura al acabar.
func _push_system(
	category: String, cycle: float, node_id: int, text: String, data: Dictionary
) -> void:
	var prev := events.actor
	events.actor = "system"
	events.push(category, cycle, node_id, text, data)
	events.actor = prev
