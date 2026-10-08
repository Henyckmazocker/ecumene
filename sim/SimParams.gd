class_name SimParams
extends Resource

## Todo el tuning de la simulación, fuera del código (patrón `SimParams` de Worlding).
##
## Regla de oro heredada de Worlding: la economía tiene que tener un punto de equilibrio.
## Aquí eso significa que un asentamiento con el reparto de trabajos por defecto produzca
## más comida de la que consume — si no, colapsa por hambruna, que fue el primer bug de
## balance de aquella simulación.

@export_group("Tiempo")
## Duración de un ciclo de simulación en segundos reales a velocidad ×1.
@export_range(0.05, 5.0, 0.05) var seconds_per_cycle: float = 1.0
## Velocidades seleccionables (0 = pausa).
@export var speeds: PackedFloat64Array = PackedFloat64Array([0.0, 1.0, 2.0, 4.0, 8.0])

@export_group("Población")
## Crecimiento logístico por ciclo con superávit de comida.
@export_range(0.0, 0.5, 0.001) var growth_rate: float = 0.035
## Decrecimiento exponencial por ciclo en hambruna.
@export_range(0.0, 0.5, 0.001) var starvation_rate: float = 0.05
## Consumo de comida por habitante y ciclo.
@export_range(0.0, 5.0, 0.01) var food_per_pop: float = 0.25
## Alojamiento sin construir nada (el claro del bosque original). Tiene que dejar margen
## por encima de `initial_pop`: si no, la partida arranca con el crecimiento a cero.
@export_range(0.0, 100.0, 1.0) var base_housing: float = 10.0
## Población por debajo de la cual el nodo se considera muerto.
@export_range(0.0, 10.0, 0.1) var min_pop: float = 0.5
## Población del asentamiento inicial.
@export_range(1.0, 100.0, 1.0) var initial_pop: float = 5.0

@export_group("Almacenamiento")
## Capacidad de partida por recurso, antes de construir almacenes.
@export_range(0.0, 10000.0, 10.0) var base_storage: float = 200.0

## Cuánto multiplica el tope de almacenamiento cada escala que se sube.
##
## Sin esto la economía se estrella contra su propio techo. El coste de un edificio crece en
## progresión **geométrica** (`BuildingDef.cost_for`, ×1.15–1.25 por ejemplar) y el tope crecía
## solo **linealmente** con los almacenes (+200 cada uno): dos curvas así se cruzan siempre.
## Y el cruce llegaba pronto —el almacén nº 20 costaba 4.163 de madera con el tope en 4.000, y
## como es el edificio que sube el tope, se bloqueaba a sí mismo y con él a todo lo demás—.
##
## Multiplicar por escala **no elimina el cruce, lo aplaza**: dentro de una escala el muro
## sigue ahí, y pasa a ser lo que empuja a ascender. Lo que sí garantiza `economy_test` es que
## el muro nunca llega antes que el umbral de ascenso, que es lo que lo convierte en un empujón
## en vez de en un callejón sin salida.
@export_range(1.0, 64.0, 0.5) var storage_per_tier: float = 8.0

@export_group("Logística")
## Cuánto puede subir el techo `K` la comida que llega por rutas, como fracción del `K` que da el
## campo propio (`Integrator._food_capacity`). Es lo que hace que cortar una ruta devuelva la
## ciudad a su techo propio en vez de extinguirla.
@export_range(0.0, 2.0, 0.05) var food_import_cap: float = 0.5

@export_group("Expediciones")
## Ciclos que tarda la primera expedición de un nodo en fundar su colonia.
@export_range(0.0, 100000.0, 10.0) var expedition_base: float = 2400.0
## ×duración por cada hijo que ese nodo ya tiene: cada colonia sale más lejos que la anterior.
@export_range(1.0, 4.0, 0.05) var expedition_growth: float = 1.5
## ⏩ Fracción de lo que le queda de viaje que recorta cada aceleración con oro.
@export_range(0.0, 1.0, 0.05) var accelerate_fraction: float = 0.25
## ⏩ Oro por ciclo recortado (k). M0 lo calibró con la 5.ª expedición, la primera como Ciudad:
## que el oro de la primera mitad del viaje pague 3 aceleraciones seguidas y no 4.
@export_range(0.0, 10000.0, 1.0) var accelerate_gold_per_cycle: float = 120.0
## ⏩ ×precio por cada aceleración ya hecha a la misma expedición: la cuarta ya no compensa.
@export_range(1.0, 4.0, 0.05) var accelerate_growth: float = 1.5

@export_group("Progreso offline")
## Tope de tiempo offline que se acredita, en segundos reales (24 h).
@export_range(0.0, 604800.0, 60.0) var offline_cap_seconds: float = 86400.0
## Eficiencia del tiempo offline frente al online.
@export_range(0.0, 1.0, 0.01) var offline_efficiency: float = 0.5

@export_group("Delegación")
## Rendimiento de un nodo gobernado frente a uno llevado a mano.
@export_range(0.0, 1.0, 0.01) var governor_efficiency: float = 0.85
## Cada cuántos ciclos revisa decisiones un gobernador.
@export_range(1.0, 1000.0, 1.0) var governor_interval: float = 30.0

@export_group("Integrador")
## Máximo de segmentos analíticos por llamada a `advance` antes de rendirse y avanzar liso.
@export_range(1, 1024, 1) var max_segments: int = 256
## Iteraciones de bisección al resolver el instante en que un stock cruza un umbral.
@export_range(8, 128, 1) var solver_iterations: int = 48
