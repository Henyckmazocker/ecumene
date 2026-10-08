class_name Villager
extends RefCounted

## Un habitante del pueblo. **Tiene estado y vive en tiempo real.**
##
## Sustituye al `Agent` de M1, que era una función pura del ciclo de simulación. Aquella
## versión tenía propiedades bonitas sobre el papel y se veía mal: a ×8 la gente corría, en
## pausa se congelaba a medio paso, y cada vez que la población cruzaba un entero se
## rematerializaba el pueblo entero con casas y oficios nuevos.
##
## Ahora es al revés y es lo correcto: **la dramatización tiene su propia inercia**. Un
## villager conserva su identidad —su casa, su oficio, dónde está— mientras exista, y los
## cambios del agregado le llegan como *órdenes* que atiende cuando termina lo que estaba
## haciendo (ver [CrowdReconciler]).
##
## Sigue sin poder tocar `WorldState`: no tiene ninguna referencia a él.

enum Activity {
	ARRIVING,    ## llega andando desde las afueras
	SLEEPING,    ## en casa, de noche
	LINGERING,   ## remoloneando cerca de casa
	COMMUTING,   ## de camino al trabajo
	WORKING,     ## en el puesto, con micromovimiento
	BREAK,       ## descanso a media jornada, fuera del edificio
	ERRAND,      ## recado con propósito: almacén o mercado
	RETURNING,   ## de vuelta a casa
	CHATTING,    ## parado charlando con alguien
	WANDERING,   ## dando una vuelta, típico de quien no tiene puesto
	LEAVING,     ## se marcha del pueblo
}

var position := Vector2.ZERO
var velocity := Vector2.ZERO
var activity: int = Activity.LINGERING
var target := Vector2.ZERO

## Casa y puesto asignados. Persisten: es lo que hace que el pueblo no se rebaraje.
var home := Vector2.ZERO
var workplace := Vector2.ZERO
var job: int = -1

var has_work: bool = false
var speed: float = 1.6
## Desfase horario propio, en horas: nadie sale de casa en el mismo instante.
var schedule_offset: float = 0.0
## Semilla del vaivén individual, para que el micromovimiento no vaya sincronizado.
var wobble_phase: float = 0.0

## Segundos hasta la próxima reevaluación de actividad. Escalonado entre villagers para que
## el coste de las decisiones se reparta entre fotogramas.
var decide_in: float = 0.0
## Segundos restantes de una actividad con duración fija (charlar).
var hold: float = 0.0

## Opacidad, para que llegar y marcharse sean desvanecimientos y no apariciones de la nada.
var fade: float = 1.0
## Marcado para irse: al llegar a `fade` 0 lo retira la multitud.
var departing: bool = false

var _age: float = 0.0


func setup(rng: RandomNumberGenerator, params: CrowdParams) -> void:
	speed = params.walk_speed * (1.0 - params.speed_jitter * 0.5 + rng.randf() * params.speed_jitter)
	schedule_offset = (rng.randf() * 2.0 - 1.0) * params.schedule_jitter
	wobble_phase = rng.randf() * TAU
	decide_in = rng.randf() * params.decide_max


# ---------------------------------------------------------------------------
# Locomoción — cada fotograma
# ---------------------------------------------------------------------------

## Avanza en **segundos reales**. No sabe nada del ciclo de simulación ni de la velocidad ×N:
## por eso el pueblo se ve igual de natural a ×1 que a ×8, y sigue vivo con la pausa puesta.
func advance(delta: float, params: CrowdParams) -> void:
	_age += delta
	if hold > 0.0:
		hold -= delta
	if decide_in > 0.0:
		decide_in -= delta

	if departing:
		fade = maxf(fade - delta / params.fade_seconds, 0.0)
	elif fade < 1.0:
		fade = minf(fade + delta / params.fade_seconds, 1.0)

	var to_target := target - position
	var distance := to_target.length()
	var desired := Vector2.ZERO

	if distance > 0.02:
		var direction := to_target / distance
		# Frenada al llegar: sin esto la gente se para en seco y parece teletransportarse el
		# último tramo.
		var cruise := speed * _speed_factor()
		var wanted := minf(cruise, distance * 2.5)
		desired = direction * wanted
		# Desvío lateral lento: las rutas dejan de ser reglas y pasan a ser sendas.
		if distance > 1.0 and params.route_wander > 0.0:
			var lateral := Vector2(-direction.y, direction.x)
			desired += lateral * sin(_age * 1.3 + wobble_phase) * params.route_wander * wanted

	velocity = velocity.move_toward(desired, params.acceleration * delta)
	position += velocity * delta


## Cuánto del paso normal se usa en cada actividad. Dormir es estar quieto; trabajar es
## moverse poco dentro del edificio; ir al trabajo es andar de verdad.
func _speed_factor() -> float:
	match activity:
		Activity.SLEEPING:
			return 0.05
		Activity.CHATTING:
			return 0.1
		Activity.WORKING:
			return 0.35
		Activity.LINGERING, Activity.BREAK:
			return 0.5
		Activity.WANDERING:
			return 0.6
		_:
			return 1.0


func arrived(tolerance: float = 0.4) -> bool:
	return position.distance_to(target) <= tolerance


# ---------------------------------------------------------------------------
# Decisiones — en el temporizador propio de cada villager
# ---------------------------------------------------------------------------

## Elige qué hacer ahora. La llama [Crowd] cuando le toca a este villager, no cada fotograma.
func decide(params: CrowdParams, hour: float, places: Places, rng: RandomNumberGenerator) -> void:
	_schedule_next_decision(params, rng)

	# Llegar, marcharse y charlar tienen su propia condición de salida: no se interrumpen.
	match activity:
		Activity.LEAVING:
			return
		Activity.ARRIVING:
			if not arrived(0.8):
				return
		Activity.CHATTING:
			if hold > 0.0:
				return

	var h := fposmod(hour + schedule_offset, 24.0)

	# --- Noche: a casa y a dormir ---
	if h >= params.sleep_hour or h < params.wake_hour:
		_switch(Activity.SLEEPING, home, params, rng)
		return

	# --- Jornada laboral ---
	if has_work and h >= params.work_start and h < params.work_end:
		var in_break := h >= params.break_hour and h < params.break_hour + params.break_length
		if in_break:
			_switch(Activity.BREAK, _near(workplace, 1.8, rng), params, rng)
		elif activity == Activity.WORKING and arrived(1.2):
			# Ya está en el puesto: solo cambia de sitio dentro del edificio.
			_switch(Activity.WORKING, _near(workplace, params.settle_radius * 2.0, rng), params, rng)
		else:
			_switch(Activity.COMMUTING if not arrived(1.2) else Activity.WORKING,
				_near(workplace, params.settle_radius, rng), params, rng)
		return

	# --- Después del trabajo: a veces con recado ---
	if has_work and h >= params.work_end:
		if activity == Activity.ERRAND and not arrived(0.8):
			return  # dejarle terminar el recado
		if activity != Activity.ERRAND and activity != Activity.RETURNING \
				and rng.randf() < params.errand_chance and not places.errands.is_empty():
			_switch(Activity.ERRAND, places.errand_point(rng), params, rng)
			return
		if arrived(1.5) and position.distance_to(home) < 2.5:
			_switch(Activity.LINGERING, _near(home, 1.6, rng), params, rng)
		else:
			_switch(Activity.RETURNING, _near(home, 0.6, rng), params, rng)
		return

	# --- Sin puesto, o antes de entrar a trabajar: vida de pueblo ---
	if rng.randf() < 0.3:
		_switch(Activity.WANDERING, _near(places.plaza, 3.5, rng), params, rng)
	else:
		var anchor := home if has_work or rng.randf() < 0.6 else places.plaza
		_switch(Activity.LINGERING, _near(anchor, 2.2, rng), params, rng)


## Se para a charlar con alguien. Lo dispara [Crowd], que es quien conoce a los vecinos.
func start_chat(with_position: Vector2, seconds: float) -> void:
	activity = Activity.CHATTING
	# No encima del otro: a un paso, mirándose.
	target = position.lerp(with_position, 0.4)
	hold = seconds
	decide_in = seconds


## ¿Está en un momento en el que pararse a charlar tiene sentido? Nadie interrumpe su turno
## ni se levanta de la cama para hacer corrillo.
func is_sociable() -> bool:
	return activity in [Activity.LINGERING, Activity.WANDERING, Activity.BREAK,
		Activity.RETURNING]


## Le llega un puesto nuevo (o se queda sin ninguno). No lo aplica de inmediato: se queda
## apuntado y surte efecto en la próxima decisión, así el cambio se ve como alguien que
## termina lo que estaba haciendo y luego cambia de rumbo.
func assign_job(new_job: int, new_workplace: Vector2) -> void:
	job = new_job
	workplace = new_workplace
	has_work = new_job >= 0


func depart(exit_point: Vector2) -> void:
	departing = true
	activity = Activity.LEAVING
	target = exit_point


## Da media vuelta: vuelve a contar como habitante sin dejar de ser quien era.
##
## Conserva casa, oficio y posición —estaba de camino a la salida, no se ha ido—, así que el
## `fade` sube desde donde estuviera y decide de nuevo en el acto: quien ya iba medio
## desvanecido reaparece poco a poco en lugar de encenderse de golpe.
func reinstate() -> void:
	departing = false
	activity = Activity.LINGERING
	target = position
	decide_in = 0.0


func _switch(new_activity: int, new_target: Vector2, params: CrowdParams,
		rng: RandomNumberGenerator) -> void:
	activity = new_activity
	target = new_target
	_schedule_next_decision(params, rng)


func _schedule_next_decision(params: CrowdParams, rng: RandomNumberGenerator) -> void:
	decide_in = params.decide_min + rng.randf() * (params.decide_max - params.decide_min)


static func _near(anchor: Vector2, radius: float, rng: RandomNumberGenerator) -> Vector2:
	var angle := rng.randf() * TAU
	# Raíz del radio: reparto uniforme en el área, no amontonado en el centro.
	var r := sqrt(rng.randf()) * radius
	return anchor + Vector2(cos(angle), sin(angle)) * r
