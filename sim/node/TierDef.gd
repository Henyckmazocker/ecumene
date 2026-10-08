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
## Hijos **ya crecidos** que hacen falta para promocionar: de la escala justo por debajo de esta,
## que es la más alta a la que un hijo puede llegar (`Promotion.tier_ceiling`). 0 = no se miran.
##
## No entra en `can_promote` de aquí, que solo sabe de números del propio nodo: los hijos están
## en `WorldState`, y la cuenta la hace `Promotion.can_promote`, la única lista de condiciones.
@export var promote_children: int = 0
## 🎭 Influencia que hace falta para SALIR de esta escala (como `promote_pop`). Solo Ciudad > 0.
##
## Como los hijos, no entra en `can_promote` de aquí: la influencia es del subárbol
## (`WorldState.influence_of`), y la mira `Promotion.can_promote`. 0 = no se mira.
@export var promote_influence: float = 0.0

## Multiplica el coste de todo lo que construye un nodo de esta escala. Asentamiento y pueblo a
## 1: no mueven H1 ni a los hijos. Es la palanca de Región (`Construction.cost_of` lo aplica).
@export var cost_scale: float = 1.0

## Multiplica la duración de las expediciones que salen de un nodo de esta escala. Una ciudad que
## funda un pueblo tarda más que un pueblo que funda una aldea: es lo que estira Región, porque sus
## pueblos 5.º y 6.º los funda ya la ciudad (`Promotion.expedition_cycles` lo aplica).
@export var expedition_scale: float = 1.0

## Cuántos hijos caben al promocionar (el nodo promocionado es el primero: la capital).
@export var child_slots: int = 1

## Mecánica nueva que estrena la escala — documental, la usa la UI para explicarla.
@export var unlocks: String = ""


func can_promote(pop: float, building_count: int) -> bool:
	if promote_pop <= 0.0:
		return false  # tier terminal
	return pop >= promote_pop and building_count >= promote_buildings


## Una escala **sin edificios propios** no se puede jugar: no trae nada que construir ni que
## repartir, así que promocionar a ella sería una promesa vacía. La condición sale de los datos
## y no de un número mágico: cuando región tenga su primer edificio, la puerta se abre sola.
func is_playable() -> bool:
	return not buildings.is_empty()
