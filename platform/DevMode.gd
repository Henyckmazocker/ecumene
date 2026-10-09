class_name DevMode

## Modo desarrollo: lo que es herramienta de depuración y no juego (hoy, ×2, ×4 y ×8). Es cosa de
## la vista y de `Main`, nunca del modelo: `SimParams.speeds` no sabe nada de él. Estático y sin
## autoload, como `Save`: no tiene estado que guardar.
##
## Encendido desde el editor (que es también arrancar desde el código fuente con `godot-4 --path .`)
## o con `--dev` en una build exportada. `--no-dev` lo apaga incluso en el editor, para ver la
## build de release sin exportarla (y sin la clave de Augur que lleva dentro).
static func on() -> bool:
	var args := OS.get_cmdline_user_args()
	if "--no-dev" in args:
		return false
	return OS.has_feature("editor") or "--dev" in args


## La velocidad más alta que puede pedir el jugador: todas con dev, solo ⏸ y ▶ sin él.
static func max_speed_index(speeds_count: int) -> int:
	return speeds_count - 1 if on() else mini(1, speeds_count - 1)
