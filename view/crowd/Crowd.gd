class_name Crowd
extends RefCounted

## La multitud del nodo enfocado. **Persiste**: nunca se tira y se rehace.
##
## Es la diferencia con M1. Antes la multitud era un array que se regeneraba cada vez que la
## población cruzaba un entero, y el pueblo entero se rebarajaba cada pocos segundos. Ahora los
## villagers tienen identidad y lo que cambia del agregado les llega poco a poco a través de
## [CrowdReconciler].
##
## Corre en **tiempo real**: no le afecta la velocidad de simulación y sigue viva con la pausa
## puesta. El mundo no se detiene porque tú pauses tu partida.

var villagers: Array[Villager] = []
## Cuántos habitantes reales representa cada punto en pantalla (> 1 en poblaciones grandes).
var represents: float = 1.0
var clock := DayClock.new()
var places: Places = null

var _rng := RandomNumberGenerator.new()


func _init(seed_value: int = 0) -> void:
	_rng.seed = seed_value


func size() -> int:
	return villagers.size()


## Avanza la vida del pueblo `delta` **segundos reales**.
##
## Las posiciones se integran cada fotograma; las decisiones van *time-sliced*, cada villager
## en su propio instante. Con 400 habitantes eso son unas pocas decisiones por fotograma en vez
## de 400 de golpe.
func advance(delta: float, params: CrowdParams) -> void:
	if places == null:
		return
	clock.seconds_per_day = params.seconds_per_day
	clock.advance(delta)
	var hour := clock.hour()

	var i := 0
	while i < villagers.size():
		var villager := villagers[i]
		villager.advance(delta, params)
		if villager.decide_in <= 0.0:
			villager.decide(params, hour, places, _rng)
			_maybe_chat(villager, params)
		if villager.departing and villager.fade <= 0.0:
			villagers.remove_at(i)
			continue
		i += 1


## Corrillos. Se muestrean unos pocos vecinos al azar en vez de comprobarlos todos: sale O(1)
## por decisión y a ojo no se distingue de una búsqueda exacta. Si algún día hiciera falta
## precisión de verdad (agrupaciones, colas), entonces sí tocaría una rejilla espacial.
func _maybe_chat(villager: Villager, params: CrowdParams) -> void:
	if not villager.is_sociable() or villagers.size() < 2:
		return
	if _rng.randf() > params.chat_chance:
		return
	for _i in params.chat_samples:
		var other: Villager = villagers[_rng.randi() % villagers.size()]
		if other == villager or not other.is_sociable():
			continue
		if villager.position.distance_to(other.position) > params.chat_radius:
			continue
		var seconds := params.chat_seconds.x \
			+ _rng.randf() * (params.chat_seconds.y - params.chat_seconds.x)
		villager.start_chat(other.position, seconds)
		other.start_chat(villager.position, seconds)
		return


# ---------------------------------------------------------------------------
# Altas y bajas — las usa el reconciliador
# ---------------------------------------------------------------------------

## Da de alta un habitante. `walk_in` lo hace entrar andando desde las afueras; sin él aparece
## ya instalado, que es lo que hace falta al cargar una partida o volver de estar fuera.
func spawn(params: CrowdParams, walk_in: bool) -> Villager:
	var villager := Villager.new()
	villager.setup(_rng, params)
	villager.home = places.home_point(_rng)
	if walk_in:
		villager.position = places.outskirt_point(_rng)
		villager.activity = Villager.Activity.ARRIVING
		villager.target = villager.home
		villager.fade = 0.0
	else:
		villager.position = Villager._near(villager.home, 1.5, _rng)
		villager.target = villager.position
		villager.activity = Villager.Activity.LINGERING
		villager.fade = 1.0
	villagers.append(villager)
	return villager


## Manda a alguien fuera del pueblo. Se elige a quien no tiene puesto: que se vaya un ocioso
## en vez de un trabajador cuadra con lo que significa que baje la población.
func retire_one() -> void:
	var chosen := -1
	for i in villagers.size():
		var villager := villagers[i]
		if villager.departing:
			continue
		if not villager.has_work:
			chosen = i
			break
		if chosen < 0:
			chosen = i
	if chosen < 0:
		return
	villagers[chosen].depart(places.nearest_outskirt(villagers[chosen].position))


func rng() -> RandomNumberGenerator:
	return _rng


## Habitantes por oficio, sin contar a los que ya se están marchando.
func job_counts() -> Dictionary:
	var counts := {}
	for villager in villagers:
		if villager.departing:
			continue
		counts[villager.job] = int(counts.get(villager.job, 0)) + 1
	return counts


func active_count() -> int:
	var total := 0
	for villager in villagers:
		if not villager.departing:
			total += 1
	return total
