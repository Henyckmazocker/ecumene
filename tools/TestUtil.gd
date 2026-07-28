extends RefCounted
## Utilidades compartidas por los tests headless.
##
## Los tests **tienen que vivir en `tools/` dentro del proyecto**: el snap de Godot no puede
## leer `/tmp`, así que un script de test fuera del proyecto no se carga.


## Motores creados por el test, para liberarlos al final: `SimEngine` es un `Node` y aquí
## nunca entra en el árbol de escena, así que nadie lo libera por nosotros.
static var _engines: Array[SimEngine] = []


## Motor listo para test: sin log de eventos (ni ring buffer ni JSONL) y con params limpios.
static func make_engine(seed_value: int, params: SimParams = null) -> SimEngine:
	var engine := SimEngine.new()
	if params != null:
		engine.params = params
	engine.events.enabled = false
	engine.events.write_files = false
	engine.start(seed_value)
	_engines.append(engine)
	return engine


## Notación científica: el `%` de GDScript no tiene `%e`.
static func sci(value: float) -> String:
	return String.num_scientific(value)


## Error relativo entre dos magnitudes, tolerante al cero.
static func rel_error(a: float, b: float) -> float:
	var scale := maxf(absf(a), absf(b))
	if scale < 1.0e-9:
		return 0.0
	return absf(a - b) / scale


static func check(condition: bool, ok_message: String, fail_message: String) -> int:
	if condition:
		print("OK  " + ok_message)
		return 0
	print("FALLO: " + fail_message)
	return 1


static func finish(tree: SceneTree, failures: int) -> void:
	for engine in _engines:
		engine.free()
	_engines.clear()
	print("")
	if failures == 0:
		print("=== TODO EN VERDE ===")
	else:
		print("=== %d COMPROBACIÓN(ES) EN ROJO ===" % failures)
	tree.quit(0 if failures == 0 else 1)
