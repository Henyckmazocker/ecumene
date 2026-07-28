class_name BuildingDef
extends Resource

## Definición de un tipo de edificio. Es un [Resource] para poder migrar a `.tres`
## sin tocar código; de momento el catálogo se construye en `data/Content.gd`.
##
## Contrato clave con el integrador: la producción y el consumo son **lineales en el
## número de trabajadores efectivos**. Esa linealidad es lo que hace que el avance del
## tiempo tenga forma cerrada y que el progreso offline sea el mismo código que el online.
## Cualquier edificio con producción no lineal rompería `Integrator`.

@export var id: String = ""
@export var name: String = ""
## Tier mínimo en el que el edificio está disponible.
@export var tier_min: int = 0

## Coste del primer ejemplar, por recurso.
@export var cost: PackedFloat64Array = Goods.zeros()
## Factor de encarecimiento por cada ejemplar ya construido (curva incremental clásica).
@export var cost_growth: float = 1.18

## Puestos de trabajo por ejemplar. 0 = el edificio es pasivo (no consume mano de obra).
@export var worker_slots: float = 0.0
## Producción por trabajador y ciclo.
@export var produces: PackedFloat64Array = Goods.zeros()
## Consumo por trabajador y ciclo (materias primas del edificio).
@export var consumes: PackedFloat64Array = Goods.zeros()

## Alojamiento que aporta por ejemplar (sube el techo de población).
@export var housing: float = 0.0
## Capacidad de almacenamiento que aporta por ejemplar, por recurso.
@export var storage: PackedFloat64Array = Goods.zeros()


## Coste de construir el ejemplar número `owned + 1`.
func cost_for(owned: int) -> PackedFloat64Array:
	var mult := pow(cost_growth, float(owned))
	var out := Goods.zeros()
	for i in Goods.COUNT:
		out[i] = cost[i] * mult
	return out


func is_workplace() -> bool:
	return worker_slots > 0.0
