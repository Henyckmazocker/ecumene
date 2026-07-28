class_name Biomes
extends RefCounted

## Biomas del terreno 2D. Cada celda del mapa de un nodo es uno de estos.
##
## Los colores son planos a propósito (ver la dirección de arte): cerca el mapa se lee como
## un diorama limpio y lejos como un mapa, sin necesidad de un set de tiles por escala.

const WATER := 0
const COAST := 1
const PLAIN := 2
const FOREST := 3
const ARID := 4
const MOUNTAIN := 5
const COUNT := 6

const NAMES := ["Agua", "Costa", "Llanura", "Bosque", "Árido", "Montaña"]

## Paleta apagada: el color saturado se reserva para la gente y los recursos.
const COLORS := [
	Color(0.16, 0.28, 0.40),  # agua
	Color(0.68, 0.63, 0.47),  # costa
	Color(0.42, 0.52, 0.32),  # llanura
	Color(0.24, 0.37, 0.26),  # bosque
	Color(0.60, 0.53, 0.36),  # árido
	Color(0.42, 0.41, 0.40),  # montaña
]


static func is_buildable(biome: int) -> bool:
	return biome != WATER


## Cuánto le gusta a un edificio caer en un bioma, en [0, 1]. 0 = no se pone ahí.
##
## Esto es **solo colocación visual**: no toca la producción. Que el bioma module el
## rendimiento es una decisión de balance pendiente (ver GDD/Mundo y Niveles), y cuando se
## tome tendrá que entrar como multiplicador constante por nodo para no romper la linealidad
## de la que depende el integrador.
static func affinity(biome: int, building_id: String) -> float:
	if not is_buildable(biome):
		return 0.0
	match building_id:
		"farm":
			match biome:
				PLAIN: return 1.0
				COAST: return 0.7
				ARID: return 0.4
				FOREST: return 0.3
				MOUNTAIN: return 0.05
		"woodcutter":
			match biome:
				FOREST: return 1.0
				PLAIN: return 0.4
				MOUNTAIN: return 0.3
				COAST: return 0.2
				ARID: return 0.1
		"quarry":
			match biome:
				MOUNTAIN: return 1.0
				ARID: return 0.5
				PLAIN: return 0.2
				COAST: return 0.15
				FOREST: return 0.1
		_:
			# Casas, almacenes, talleres, mercados y templos: donde se pueda pisar, mejor
			# cuanto más llano.
			match biome:
				PLAIN: return 1.0
				COAST: return 0.85
				ARID: return 0.7
				FOREST: return 0.6
				MOUNTAIN: return 0.3
	return 0.5
