class_name TierDef
extends Resource

## Definición de una escala (asentamiento, pueblo, ciudad, región, país, imperio, planeta).
##
## No hay una clase por escala: un tier es **datos**. Añadir "planeta" es rellenar otro
## `TierDef`, no escribir código. `SimNode` es el mismo objeto en las siete escalas.

@export var index: int = 0
@export var id: String = ""
@export var name: String = ""
@export var name_plural: String = ""

## Recursos que esta escala maneja de forma nativa (los de tiers inferiores se heredan).
@export var goods: PackedInt32Array = PackedInt32Array()
## Ids de edificios disponibles en esta escala.
@export var buildings: PackedStringArray = PackedStringArray()

## Condición de promoción al tier siguiente.
@export var promote_pop: float = 0.0
@export var promote_buildings: int = 0

## Cuántos hijos caben al promocionar (el nodo promocionado es el primero: la capital).
@export var child_slots: int = 1

## Mecánica nueva que estrena la escala — documental, la usa la UI para explicarla.
@export var unlocks: String = ""


func can_promote(pop: float, building_count: int) -> bool:
	if promote_pop <= 0.0:
		return false  # tier terminal
	return pop >= promote_pop and building_count >= promote_buildings
