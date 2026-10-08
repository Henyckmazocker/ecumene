extends SceneTree
## La cámara de escalas, sin ratón: se llama a `_zoom_at` a mano, que es por donde pasan la rueda
## y el pellizco. Ejecutar con:
##   godot-4 --headless --path . -s res://tools/camera_test.gd
##
## Comprueba los tres comportamientos de M1 de la vista agregada:
## - sin padre ni hijo, el zoom se acota como siempre y no se pide ningún cambio de foco;
## - alejarse más allá de `ZOOM_MIN` pide el padre, y solo tras el margen (`OVERSHOOT`);
## - acercarse más allá de `ZOOM_MAX` pide el hijo que `Main` le dio (el último visitado).
##
## Y los dos atajos de M3c para entrar en un hijo desde la vista agregada:
## - acercar con el puntero sobre una mancha ancla el zoom: converge a su centro y pide ese hijo en
##   menos muescas que el cruce de `ZOOM_MAX`; alejar suelta el ancla; sin mancha, el zoom de antes;
## - un clic (o un toque) sobre la mancha pide el hijo al momento y la cámara vuela hasta ella; un
##   arrastre no es un clic, y un clic fuera de las manchas no pide nada.

const TestUtil := preload("res://tools/TestUtil.gd")

var _requested: Array[int] = []


## La cámara tiene que estar ya dentro del árbol, o `get_screen_transform` no tiene a qué viewport
## mirar: se espera un fotograma tras añadirla.
func _initialize() -> void:
	var failures := 0
	var camera := ScaleCamera.new()
	camera.enabled = true
	root.add_child(camera)
	await process_frame
	camera.focus_requested.connect(func(id: int) -> void: _requested.append(id))
	var point := Vector2(320, 240)

	# --- Un árbol de un nodo: igual que `SettlementCamera` ---
	camera.zoom = Vector2.ONE
	camera.set_focus(0, -1, -1)
	var same := true
	for factor in [1.0 / ScaleCamera.WHEEL_STEP, ScaleCamera.WHEEL_STEP]:
		for _i in 40:
			var expected := clampf(camera.zoom.x * factor, ScaleCamera.ZOOM_MIN, ScaleCamera.ZOOM_MAX)
			camera._zoom_at(point, factor)
			same = same and is_equal_approx(camera.zoom.x, expected)
	failures += TestUtil.check(
		same and _requested.is_empty() and camera.depth >= 0.0 and camera.depth < 1.0,
		"sin padre ni hijo el zoom se acota en %.2f..%.2f como antes, y no pide cambiar de foco" % [
			ScaleCamera.ZOOM_MIN, ScaleCamera.ZOOM_MAX,
		],
		"sin padre ni hijo la cámara cambia: zoom %.3f, focos pedidos %s, depth %.3f" % [
			camera.zoom.x, _requested, camera.depth,
		]
	)

	# --- Alejarse desde un hijo: pide el padre, pasado el margen ---
	camera.zoom = Vector2.ONE
	camera.set_focus(0, 7, -1)
	var steps := 0
	var at_min_before := true
	while _requested.is_empty() and steps < 100:
		at_min_before = camera.zoom.x <= ScaleCamera.ZOOM_MIN + 1e-6
		camera._zoom_at(point, 1.0 / ScaleCamera.WHEEL_STEP)
		steps += 1
	failures += TestUtil.check(
		_requested == [7] and at_min_before and camera.depth >= 1.0,
		"alejarse más allá del mínimo pide el padre (%d muescas desde ×1, depth %.2f)" % [
			steps, camera.depth,
		],
		"alejarse no pide el padre: focos %s tras %d muescas, ¿en el mínimo? %s, depth %.3f" % [
			_requested, steps, at_min_before, camera.depth,
		]
	)

	# --- Dar marcha atrás desde el margen vuelve en el acto ---
	# Las mismas muescas de antes menos la última, que es la que cruzaba: se queda en el margen.
	_requested.clear()
	camera.zoom = Vector2.ONE
	camera.set_focus(0, 7, -1)
	for _i in steps - 1:
		camera._zoom_at(point, 1.0 / ScaleCamera.WHEEL_STEP)
	var depth_in_margin := camera.depth
	camera._zoom_at(point, ScaleCamera.WHEEL_STEP)
	failures += TestUtil.check(
		_requested.is_empty() and camera.zoom.x > ScaleCamera.ZOOM_MIN + 1e-6
			and depth_in_margin > camera.depth,
		"desde el margen, una muesca hacia dentro vuelve a acercar en el acto (×%.3f)" % camera.zoom.x,
		"el margen se traga la vuelta: zoom %.3f, focos %s" % [camera.zoom.x, _requested]
	)

	# --- Acercarse sobre el padre: entra en el último hijo visitado ---
	_requested.clear()
	camera.zoom = Vector2.ONE
	camera.set_focus(1, -1, 9)
	steps = 0
	var at_max_before := true
	while _requested.is_empty() and steps < 100:
		at_max_before = camera.zoom.x >= ScaleCamera.ZOOM_MAX - 1e-6
		camera._zoom_at(point, ScaleCamera.WHEEL_STEP)
		steps += 1
	failures += TestUtil.check(
		_requested == [9] and at_max_before and camera.depth < 1.0,
		"acercarse más allá del máximo entra en el último hijo visitado (%d muescas, depth %.6f < 1)" % [
			steps, camera.depth,
		],
		"acercarse no entra en el hijo: focos %s tras %d muescas, ¿en el máximo? %s, depth %.3f" % [
			_requested, steps, at_max_before, camera.depth,
		]
	)

	# --- Cambiar de foco reinicia «no la ha tocado» y la profundidad sigue al tier ---
	camera._user_moved = true
	camera.zoom = Vector2.ONE
	camera.set_focus(2, 3, -1)
	failures += TestUtil.check(
		not camera._user_moved and int(camera.depth) == 2,
		"cambiar de foco reinicia «no la ha tocado», y la parte entera de depth es el tier (%.2f)" % camera.depth,
		"tras cambiar de foco: tocada %s, depth %.3f" % [camera._user_moved, camera.depth]
	)

	failures += _anchored_zoom(camera)
	failures += _click_enters(camera)

	camera.free()
	TestUtil.finish(self, failures)


## La mancha de prueba: el hijo 5, a 300 px del centro y con 48 px de radio (3 celdas, la de un
## asentamiento de unas decenas de personas). Lo que `Main` le da a la cámara: `child_picker` y
## `blob_locator`, sin estado detrás.
const BLOB_ID := 5
const BLOB := Vector3(300.0, 120.0, 48.0)


func _give_blob(camera: ScaleCamera) -> void:
	camera.child_picker = func(world_point: Vector2) -> int:
		return BLOB_ID if world_point.distance_to(Vector2(BLOB.x, BLOB.y)) <= BLOB.z else -1
	camera.blob_locator = func(id: int) -> Vector3:
		return BLOB if id == BLOB_ID else Vector3(0.0, 0.0, -1.0)


## La vista agregada de una ciudad sin hijo «último visitado», a ×0,6 (la mancha se ve entera).
func _aggregate_view(camera: ScaleCamera) -> void:
	_requested.clear()
	camera.bounds = Rect2()
	# El hueco libre de una pantalla de 1280×720 con el dock a la derecha: el centro de lo que se ve
	# no es el de la ventana, y la mancha tiene que acabar en el primero.
	camera.view_rect = Rect2(Vector2.ZERO, Vector2(853.0, 720.0))
	camera.position = Vector2.ZERO
	camera.zoom = Vector2.ONE * 0.6
	camera.set_focus(2, -1, -1)
	camera._flight_id = -1


## Acercar con el puntero sobre la mancha acaba pidiendo ese hijo, con la mancha centrada, en menos
## muescas que el cruce de `ZOOM_MAX` (que además no llegaba: la mancha se desvanecía antes).
func _anchored_zoom(camera: ScaleCamera) -> int:
	var failures := 0
	_give_blob(camera)
	_aggregate_view(camera)
	failures += TestUtil.check(ChildMapRenderer.shows_at(camera.depth),
		"a ×0,6 se ve la vista agregada (depth %.2f)" % camera.depth,
		"a ×0,6 no se ve la vista agregada: depth %.3f" % camera.depth)
	# El puntero se queda donde estaba la mancha al empezar, como la mano del jugador.
	var pointer := camera._world_to_screen(Vector2(BLOB.x, BLOB.y))
	var steps := 0
	var anchored_all_along := true
	while _requested.is_empty() and steps < 100:
		camera._zoom_at(pointer, ScaleCamera.WHEEL_STEP)
		steps += 1
		if _requested.is_empty():
			anchored_all_along = anchored_all_along and camera.anchored_child() == BLOB_ID
	# Lo que costaba antes: de ×0,6 a `ZOOM_MAX` y tres muescas más.
	var old_steps := ceili(log(ScaleCamera.ZOOM_MAX * ScaleCamera.OVERSHOOT / 0.6)
			/ log(ScaleCamera.WHEEL_STEP))
	var max_steps := 20
	var off_center := camera._world_to_screen(Vector2(BLOB.x, BLOB.y)).distance_to(
			camera._free_center())
	var radius_on_screen := BLOB.z * camera.zoom.x
	var short_side := minf(camera.view_rect.size.x, camera.view_rect.size.y)
	failures += TestUtil.check(
		_requested == [BLOB_ID] and anchored_all_along and steps <= max_steps and steps < old_steps,
		"acercar sobre la mancha ancla el zoom y pide ese hijo en %d muescas (≤ %d; el cruce de ZOOM_MAX eran %d)" % [
			steps, max_steps, old_steps,
		],
		"acercar sobre la mancha no la pide: focos %s tras %d muescas, ¿anclada siempre? %s" % [
			_requested, steps, anchored_all_along,
		]
	)
	failures += TestUtil.check(
		off_center < 4.0 and (radius_on_screen >= short_side * ScaleCamera.ANCHOR_CROSS_FRACTION - 1e-3
			or is_equal_approx(camera.zoom.x, ScaleCamera.ZOOM_MAX)),
		"al cruzar la mancha está centrada (a %.1f px) y su radio llena 1/3 de pantalla (%.0f de %.0f px, ×%.2f)" % [
			off_center, radius_on_screen, short_side, camera.zoom.x,
		],
		"al cruzar la mancha no está centrada o es pequeña: a %.1f px, radio %.0f px, ×%.2f" % [
			off_center, radius_on_screen, camera.zoom.x,
		]
	)
	failures += TestUtil.check(camera.anchored_child() == -1,
		"tras pedir el hijo el ancla se suelta", "el ancla sigue puesta tras el cruce")

	# Alejar con el ancla puesta la suelta, y el zoom vuelve a ser el del puntero.
	_aggregate_view(camera)
	camera._zoom_at(pointer, ScaleCamera.WHEEL_STEP)
	var was_anchored := camera.anchored_child() == BLOB_ID
	camera._zoom_at(pointer, 1.0 / ScaleCamera.WHEEL_STEP)
	failures += TestUtil.check(was_anchored and camera.anchored_child() == -1 and _requested.is_empty(),
		"alejar con el zoom anclado suelta el ancla sin pedir nada",
		"alejar no suelta el ancla: ¿anclado antes? %s, después %d, focos %s" % [
			was_anchored, camera.anchored_child(), _requested,
		])

	# Sin mancha bajo el puntero: el zoom de siempre. Se compara con la misma secuencia en una
	# cámara sin picking ni manchas, que es la de antes de M3c.
	var empty_point := Vector2(150.0, 120.0)
	camera.child_picker = Callable()
	camera.blob_locator = Callable()
	_aggregate_view(camera)
	for _i in 6:
		camera._zoom_at(empty_point, ScaleCamera.WHEEL_STEP)
	var reference := [camera.position, camera.zoom]
	_give_blob(camera)
	_aggregate_view(camera)
	var nothing_there: bool = camera.child_picker.call(camera.screen_to_world(empty_point)) == -1
	for _i in 6:
		camera._zoom_at(empty_point, ScaleCamera.WHEEL_STEP)
	failures += TestUtil.check(
		nothing_there and camera.anchored_child() == -1 and _requested.is_empty()
			and camera.position.is_equal_approx(reference[0]) and camera.zoom == reference[1],
		"sin mancha bajo el puntero el zoom es exactamente el de antes (×%.3f, misma posición)" % camera.zoom.x,
		"sin mancha el zoom cambia: ancla %d, focos %s, %s/%s frente a %s" % [
			camera.anchored_child(), _requested, camera.position, camera.zoom, reference,
		])

	# De cerca la mancha no se ve, así que no ancla aunque el puntero esté encima.
	_aggregate_view(camera)
	camera.zoom = Vector2.ONE * 3.0
	camera.set_focus(2, -1, -1)
	camera._zoom_at(camera._world_to_screen(Vector2(BLOB.x, BLOB.y)), ScaleCamera.WHEEL_STEP)
	failures += TestUtil.check(camera.anchored_child() == -1,
		"de cerca, sin vista agregada, una mancha invisible no ancla el zoom",
		"una mancha invisible ancla el zoom")
	return failures


## Un clic en la mancha pide el hijo en el acto y la cámara vuela hasta ella; arrastrar no es clic.
func _click_enters(camera: ScaleCamera) -> int:
	var failures := 0
	_give_blob(camera)

	# Arrastrar desde la mancha es panear, no entrar.
	_aggregate_view(camera)
	var on_blob := camera._world_to_screen(Vector2(BLOB.x, BLOB.y))
	var before := camera.position
	_mouse(camera, on_blob, true)
	_motion(camera, on_blob + Vector2(30.0, 0.0), Vector2(30.0, 0.0))
	_mouse(camera, on_blob + Vector2(30.0, 0.0), false)
	failures += TestUtil.check(_requested.is_empty() and camera.position != before,
		"pulsar sobre la mancha y arrastrar 30 px panea y no pide nada",
		"arrastrar sobre la mancha: focos %s, ¿se movió? %s" % [_requested, camera.position != before])

	# Un clic fuera de las manchas no hace nada.
	_aggregate_view(camera)
	var empty_point := camera._world_to_screen(Vector2(-200.0, -150.0))
	_mouse(camera, empty_point, true)
	_mouse(camera, empty_point, false)
	failures += TestUtil.check(_requested.is_empty() and camera.flying_to() == -1,
		"un clic fuera de las manchas no pide nada", "un clic en el vacío pide %s" % [_requested])

	# El clic: un temblor de 3 px sigue siendo clic, y se pide al soltar.
	_aggregate_view(camera)
	on_blob = camera._world_to_screen(Vector2(BLOB.x, BLOB.y))
	_mouse(camera, on_blob, true)
	_motion(camera, on_blob + Vector2(3.0, 0.0), Vector2(3.0, 0.0))
	_mouse(camera, on_blob + Vector2(3.0, 0.0), false)
	failures += TestUtil.check(_requested == [BLOB_ID] and camera.flying_to() == BLOB_ID,
		"un clic en la mancha pide ese hijo al momento y empieza a volar hacia ella",
		"el clic en la mancha no lo pide: focos %s, vuelo %d" % [_requested, camera.flying_to()])
	# Otro clic durante el vuelo no pide un segundo cruce.
	_mouse(camera, on_blob, true)
	_mouse(camera, on_blob, false)
	var frames := 0
	while camera.flying_to() >= 0 and frames < 200:
		camera._process(1.0 / 60.0)
		frames += 1
	var expected_zoom := camera._cross_zoom(BLOB.z)
	var landed := camera._view_center().distance_to(Vector2(BLOB.x, BLOB.y))
	failures += TestUtil.check(
		_requested == [BLOB_ID] and landed < 0.5 and is_equal_approx(camera.zoom.x, expected_zoom)
			and frames <= ceili(ScaleCamera.FLIGHT_SECONDS * 60.0) + 1,
		"la cámara vuela hasta la mancha en %d fotogramas y se posa en su centro a ×%.2f; un segundo clic en vuelo no pide nada" % [
			frames, camera.zoom.x,
		],
		"el vuelo no llega: focos %s, a %.1f px del centro, ×%.3f (esperado ×%.3f), %d fotogramas" % [
			_requested, landed, camera.zoom.x, expected_zoom, frames,
		])

	# Lo mismo con el dedo: un toque es un clic, y dos dedos no lo son.
	_aggregate_view(camera)
	on_blob = camera._world_to_screen(Vector2(BLOB.x, BLOB.y))
	_touch(camera, 0, on_blob, true)
	_touch(camera, 1, on_blob + Vector2(200.0, 0.0), true)
	_touch(camera, 1, on_blob + Vector2(200.0, 0.0), false)
	_touch(camera, 0, on_blob, false)
	var pinch_requested := _requested.duplicate()
	_touch(camera, 0, on_blob, true)
	_touch(camera, 0, on_blob, false)
	failures += TestUtil.check(pinch_requested.is_empty() and _requested == [BLOB_ID],
		"un toque en la mancha la pide; poner dos dedos (pellizco) no",
		"toques: con dos dedos %s, con uno %s" % [pinch_requested, _requested])
	camera._flight_id = -1
	return failures


func _mouse(camera: ScaleCamera, at: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = at
	camera._unhandled_input(event)


func _motion(camera: ScaleCamera, at: Vector2, relative: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = at
	event.relative = relative
	camera._unhandled_input(event)


func _touch(camera: ScaleCamera, index: int, at: Vector2, pressed: bool) -> void:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.position = at
	event.pressed = pressed
	camera._unhandled_input(event)
