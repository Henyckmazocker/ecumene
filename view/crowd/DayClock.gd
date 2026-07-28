class_name DayClock
extends RefCounted

## El reloj del pueblo, **independiente del reloj de la simulación**.
##
## Dos relojes a propósito. El de `SimEngine` mide ciclos de economía, se pausa y va de ×1 a ×8.
## Este mide la vida cotidiana y corre siempre, al mismo ritmo: pausar el juego detiene *tu
## partida*, no el mundo, y poner ×8 acelera la producción, no convierte a la gente en
## correcaminos. Sin esta separación, mirar el pueblo a velocidad alta era insufrible.

var seconds_per_day: float = 120.0
var elapsed: float = 0.0


func advance(delta: float) -> void:
	elapsed += delta


## Hora del día en [0, 24).
func hour() -> float:
	return fposmod(elapsed / seconds_per_day, 1.0) * 24.0


func day() -> int:
	return int(elapsed / seconds_per_day)


## Fracción del día en [0, 1), útil para animaciones cíclicas.
func phase() -> float:
	return fposmod(elapsed / seconds_per_day, 1.0)


## Luz ambiente en [0, 1]: 0 en plena noche, 1 a mediodía. Todavía no se usa para nada — es
## lo que alimentará el tinte día/noche del CanvasModulate cuando llegue el arte.
func daylight() -> float:
	var h := hour()
	if h < 5.0 or h > 21.0:
		return 0.0
	if h < 8.0:
		return (h - 5.0) / 3.0
	if h > 18.0:
		return 1.0 - (h - 18.0) / 3.0
	return 1.0


func is_night() -> bool:
	return daylight() <= 0.0
