class_name Agent
extends RefCounted

## Un habitante visible.
##
## **Su posición es una función pura del tiempo de simulación.** No guarda estado entre
## fotogramas, no se "actualiza": se le pregunta dónde está en el ciclo `t` y responde. De ahí
## salen tres propiedades que el proyecto necesita y que un agente con estado no daría:
##
##   - **No puede tocar el modelo** aunque alguien se descuide: no tiene nada que escribir.
##   - **Materializar y colapsar es gratis y exacto**: al volver a acercar el zoom, la gente
##     está donde estaría si nunca hubieras mirado a otro lado.
##   - **Pausa y velocidades salen solas**: si el ciclo no avanza, nadie se mueve.
##
## Lo que ves es una **dramatización** del agregado: estos puntos no producen nada, reparten
## visualmente el total que el integrador ya decidió.

enum State { HOME, COMMUTE_OUT, WORKING, COMMUTE_HOME, IDLE }

## Ciclos que dura un día. 24 hace que el reloj de la simulación se lea como uno de verdad.
const DAY := 24.0

var home := Vector2.ZERO
var work := Vector2.ZERO
var has_work: bool = false
## Índice de edificio donde trabaja, para colorear por oficio.
var job: int = -1
## Desfase individual en [0, 1): sin esto todo el pueblo saldría de casa el mismo instante.
var phase: float = 0.0
## Celdas por ciclo.
var speed: float = 6.0
var wander: float = 1.4


## Posición y estado en un instante de la simulación. Coordenadas en celdas del terreno.
func sample(cycle: float) -> Array:
	if not has_work:
		return [_idle_position(cycle), State.IDLE]

	var day_t := fposmod(cycle + phase * DAY * 0.06, DAY)
	var travel := clampf(home.distance_to(work) / speed, 0.25, 4.0)
	var depart := 6.5 + phase * 2.0
	var back := 18.0 + phase * 2.0

	if day_t < depart:
		return [_settled(home, cycle), State.HOME]
	if day_t < depart + travel:
		var t := (day_t - depart) / travel
		return [home.lerp(work, _ease(t)), State.COMMUTE_OUT]
	if day_t < back:
		return [_settled(work, cycle), State.WORKING]
	if day_t < back + travel:
		var t := (day_t - back) / travel
		return [work.lerp(home, _ease(t)), State.COMMUTE_HOME]
	return [_settled(home, cycle), State.HOME]


## Pequeño vaivén para que trabajar y estar en casa no parezca estar congelado. Barato:
## dos senos, sin estado.
func _settled(anchor: Vector2, cycle: float) -> Vector2:
	var t := cycle * 1.7 + phase * TAU
	return anchor + Vector2(sin(t), cos(t * 1.31)) * 0.22


## Ocio: quien no tiene puesto deambula cerca de casa. Que se note a simple vista quién no
## está haciendo nada es información de juego, no decoración — significa que sobra gente
## para los puestos que hay.
func _idle_position(cycle: float) -> Vector2:
	var t := cycle * 0.09 + phase * TAU
	var radius := wander * (0.45 + 0.55 * sin(t * 0.73 + phase * 5.0))
	return home + Vector2(cos(t), sin(t * 1.27)) * radius


static func _ease(t: float) -> float:
	return t * t * (3.0 - 2.0 * t)
