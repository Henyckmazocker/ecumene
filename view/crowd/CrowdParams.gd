class_name CrowdParams
extends Resource

## Tuning de la **dramatización**: cómo de rápido anda la gente, cuánto dura su jornada, cada
## cuánto se para a charlar.
##
## Está deliberadamente separado de `SimParams`. Son dos simulaciones distintas y solo una es
## autoritativa: tocar aquí cambia cómo se ve el pueblo y **no puede cambiar un solo número de
## la economía**. Tenerlo en el mismo recurso invitaría exactamente al error contrario.

@export_group("Reloj visual")
## Segundos reales que dura un día en el pueblo. Corre siempre, también con la simulación en
## pausa, y no le afecta la velocidad ×1–×8.
@export_range(10.0, 600.0, 5.0) var seconds_per_day: float = 120.0

@export_group("Luz")
## Tono de la noche, **sin oscurecer**: lo oscuro lo pone `min_light`. Azulado y no gris, porque
## una noche negra se come el color por oficio de la gente, y con él el «desaturado = ocioso».
@export var night_color := Color(0.70, 0.80, 1.0)
## Valor (el canal más alto) del tinte en plena noche. A ~0,45 los oficios se siguen
## distinguiendo de madrugada; por debajo, el pueblo se vuelve una mancha.
@export_range(0.1, 1.0, 0.01) var min_light: float = 0.45
## Tono cálido de las rampas de amanecer y atardecer. **Ámbar, nunca naranja ni rojo**: el rojo
## es del hambre y no puede aparecer en la paleta por la hora que es.
@export var dusk_color := Color(1.0, 0.90, 0.70)
## Cuánto pesa `dusk_color` en el centro de una rampa. Se desvanece en sus dos extremos, así que
## solo tiñe durante las tres horas de transición de `DayClock.daylight()`.
@export_range(0.0, 1.0, 0.05) var dusk_strength: float = 0.6


## El tinte del `CanvasModulate` para una luz ambiente en [0, 1].
##
## Blanco a pleno día —el pueblo se ve exactamente como sin tinte—, `night_color` escalado a
## `min_light` de noche, y en las rampas una pizca de ámbar que pesa más a media transición.
## Pura y aquí por la misma razón que [method dots_for]: es tuning visual y se puede comprobar
## sin abrir una ventana.
func light_tint(daylight: float) -> Color:
	var night := night_color * (min_light / maxf(night_color.v, 0.001))
	night.a = 1.0
	var tint := night.lerp(Color.WHITE, daylight)
	return tint.lerp(tint * dusk_color, dusk_strength * sin(PI * clampf(daylight, 0.0, 1.0)))

@export_group("Locomoción")
## Celdas por segundo real. La gente anda siempre a este paso, esté el juego a ×1 o a ×8.
##
## Va atado al espaciado de `Layout`: al darle a cada edificio su parcela, el pueblo dobló de
## radio y con el paso antiguo la gente se pasaba la jornada de camino —a media mañana solo un
## 32 % había llegado al puesto—. Y eso no es un detalle estético: la multitud tiene que
## **converger al agregado**, así que si el reparto de oficios dice que hay 40 granjeros,
## tienen que verse 40 en la granja, no 13 andando por el campo.
@export_range(0.2, 10.0, 0.1) var walk_speed: float = 2.4
## Variación individual del paso, para que no marchen en formación.
@export_range(0.0, 1.0, 0.05) var speed_jitter: float = 0.35
@export_range(0.5, 40.0, 0.5) var acceleration: float = 6.0
## Desvío lateral de las rutas. A 0 la gente va en línea recta como un dron.
@export_range(0.0, 2.0, 0.05) var route_wander: float = 0.4
## Radio del micromovimiento al estar parado en un sitio (trabajando, en casa).
@export_range(0.0, 1.0, 0.05) var settle_radius: float = 0.3

@export_group("Decisiones")
## Cada villager reevalúa su actividad en un instante propio dentro de este rango: así el
## coste de las decisiones se reparte entre fotogramas en vez de concentrarse en picos.
@export_range(0.05, 5.0, 0.05) var decide_min: float = 0.4
@export_range(0.05, 5.0, 0.05) var decide_max: float = 1.2

@export_group("Vida social")
@export_range(0.0, 6.0, 0.1) var chat_radius: float = 1.8
## Vecinos que se muestrean al azar para buscar con quién charlar. Muestrear unos pocos sale
## O(1) y a ojo no se distingue de comprobarlos todos.
@export_range(1, 16, 1) var chat_samples: int = 4
@export_range(0.0, 1.0, 0.05) var chat_chance: float = 0.35
@export var chat_seconds := Vector2(3.0, 9.0)

@export_group("Jornada")
@export_range(0.0, 24.0, 0.25) var wake_hour: float = 6.5
@export_range(0.0, 24.0, 0.25) var work_start: float = 8.0
@export_range(0.0, 24.0, 0.25) var break_hour: float = 13.0
@export_range(0.0, 24.0, 0.25) var break_length: float = 1.0
@export_range(0.0, 24.0, 0.25) var work_end: float = 18.0
@export_range(0.0, 24.0, 0.25) var sleep_hour: float = 22.0
## Desfase individual máximo, en horas: nadie sale de casa en el mismo instante.
@export_range(0.0, 4.0, 0.1) var schedule_jitter: float = 1.2
## Probabilidad de pasarse por el almacén o el mercado al volver del trabajo.
@export_range(0.0, 1.0, 0.05) var errand_chance: float = 0.3

@export_group("Convergencia hacia el agregado")
## Tope duro de puntos en pantalla. Es el último recurso: con `villagers_per_dot` puesto, no se
## llega hasta bien entrada la escala de pueblo.
@export_range(20, 2000, 10) var max_villagers: int = 400
## Habitantes reales por punto, pasada la población de detalle completo.
##
## Cada punto que se dibuja cuesta lo mismo cada fotograma —integrar su posición, decidir, y
## tres escrituras en el `MultiMesh`—, así que el coste de la vista es lineal en los puntos y no
## en la población. Un pueblo de mil habitantes no se lee mejor con mil puntos que con
## doscientos: se lee peor, porque se convierte en una mancha.
@export_range(1.0, 50.0, 1.0) var villagers_per_dot: float = 5.0
## Hasta aquí se dibuja a todo el mundo, uno a uno.
##
## Es la población con la que el asentamiento promociona (`Content`, 60). Mientras seas un
## puñado de gente, esa gente **es** el juego y agregarla de cinco en cinco dejaría el pueblo
## fundacional con doce puntos. La agregación empieza cuando ya no puedes seguirlos uno a uno.
@export_range(0, 500, 5) var full_detail_pop: int = 60
## Altas y bajas por segundo real. Bajo a propósito: que la población suba se tiene que ver
## como gente que llega andando, no como puntos que aparecen.
@export_range(0.1, 50.0, 0.1) var arrivals_per_second: float = 2.5
## Cambios de oficio por segundo real.
@export_range(0.1, 50.0, 0.1) var job_changes_per_second: float = 2.0
## Segundos que tarda un recién llegado en aparecer del todo (y un saliente en irse).
@export_range(0.1, 10.0, 0.1) var fade_seconds: float = 1.5


## Cuántos puntos se dibujan para una población dada.
##
## Uno por habitante mientras el pueblo sea pequeño, y de ahí en adelante uno por cada
## `villagers_per_dot`. El tramo es **continuo**: al cruzar `full_detail_pop` el ritmo de
## aparición se frena, pero no desaparece nadie de golpe, que es lo que pasaría con un cociente
## a secas (a 60 habitantes se pasaría de 60 puntos a 12 en un ciclo).
##
## Función pura y aquí, no en el reconciliador, porque es una decisión de **tuning visual** y es
## lo que se puede comprobar sin abrir una ventana.
func dots_for(pop: float) -> int:
	if pop <= 0.0:
		return 0
	var detail := float(full_detail_pop)
	var dots := pop if pop <= detail else detail + (pop - detail) / villagers_per_dot
	return clampi(int(round(dots)), 1, max_villagers)
