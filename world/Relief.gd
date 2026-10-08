class_name Relief
extends RefCounted

## El terreno es tierra o agua. La tierra se pinta en cuatro tonos por altura, y eso es todo:
## no hay clases de suelo con efecto en el juego (los biomas se quitaron el 2026-10-08).

const WATER := 0
const LOW := 1      # tierra baja
const MID := 2
const HIGH := 3
const PEAK := 4     # tierra alta
const COUNT := 5

## Paleta apagada (Arte y Estética): el color saturado se reserva para la gente y los recursos.
const COLORS := [
	Color(0.16, 0.28, 0.40),  # agua (la de antes)
	Color(0.46, 0.55, 0.35),  # baja
	Color(0.42, 0.52, 0.32),  # media (la llanura de antes)
	Color(0.37, 0.47, 0.30),  # alta
	Color(0.33, 0.41, 0.29),  # cumbre
]


static func is_buildable(kind: int) -> bool:
	return kind != WATER
