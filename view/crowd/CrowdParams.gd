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

@export_group("Locomoción")
## Celdas por segundo real. La gente anda siempre a este paso, esté el juego a ×1 o a ×8.
@export_range(0.2, 10.0, 0.1) var walk_speed: float = 1.6
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
## Tope de habitantes en pantalla. Por encima, cada punto representa a varios.
@export_range(20, 2000, 10) var max_villagers: int = 400
## Altas y bajas por segundo real. Bajo a propósito: que la población suba se tiene que ver
## como gente que llega andando, no como puntos que aparecen.
@export_range(0.1, 50.0, 0.1) var arrivals_per_second: float = 2.5
## Cambios de oficio por segundo real.
@export_range(0.1, 50.0, 0.1) var job_changes_per_second: float = 2.0
## Segundos que tarda un recién llegado en aparecer del todo (y un saliente en irse).
@export_range(0.1, 10.0, 0.1) var fade_seconds: float = 1.5
