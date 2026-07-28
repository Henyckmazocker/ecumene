class_name SettlementCamera
extends Camera2D

## Cámara del asentamiento: paneo y zoom con ratón y con dedos.
##
## Es el embrión de la `ScaleCamera` de M3, donde el zoom pasará a ser una **profundidad
## continua** que atraviesa las siete escalas. De momento se queda dentro de un nodo, pero el
## gesto ya es el definitivo —rueda o pellizco, sin botones de entrar y salir—, porque es la
## principal seña de identidad del juego y conviene tenerlo bien desde el principio.

const ZOOM_MIN := 0.35
const ZOOM_MAX := 6.0
const WHEEL_STEP := 1.12

var bounds := Vector2.ZERO

var _user_moved: bool = false
var _dragging: bool = false
## Toques activos, para distinguir un dedo (paneo) de dos (pellizco).
var _touches: Dictionary = {}
var _pinch_distance: float = 0.0


## Encuadra la mancha construida dentro de un mapa de lado `world_size`.
##
## Lo que se encuadra es el asentamiento, **no el mapa**: a la distancia del mapa entero los
## habitantes miden un píxel y no se ve nada de lo que hace especial al juego.
func frame(extent: Rect2, world_size: float, viewport: Vector2) -> void:
	bounds = Vector2.ONE * world_size
	position = extent.get_center()
	if extent.size.x > 0.0 and extent.size.y > 0.0:
		var fit := minf(viewport.x / extent.size.x, viewport.y / extent.size.y)
		zoom = Vector2.ONE * clampf(fit, ZOOM_MIN, ZOOM_MAX)
	_clamp_position()


## Reencuadra solo si el jugador no ha tocado la cámara: crecer el pueblo no puede robarle
## el zoom a quien está mirando un detalle.
func reframe_if_untouched(extent: Rect2, world_size: float, viewport: Vector2) -> void:
	if _user_moved:
		return
	frame(extent, world_size, viewport)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _dragging:
		_user_moved = true
	elif event is InputEventMouseButton and event.button_index in [
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		_user_moved = true
	elif event is InputEventScreenDrag or event is InputEventMagnifyGesture:
		_user_moved = true

	if event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion and _dragging:
		position -= event.relative / zoom
		_clamp_position()
	elif event is InputEventScreenTouch:
		_handle_touch(event)
	elif event is InputEventScreenDrag:
		_handle_drag(event)
	elif event is InputEventMagnifyGesture:
		_zoom_at(event.position, event.factor)


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	match event.button_index:
		MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE:
			_dragging = event.pressed
		MOUSE_BUTTON_WHEEL_UP:
			if event.pressed:
				_zoom_at(event.position, WHEEL_STEP)
		MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed:
				_zoom_at(event.position, 1.0 / WHEEL_STEP)


func _handle_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		_touches[event.index] = event.position
	else:
		_touches.erase(event.index)
	# Al pasar de dos dedos a uno hay que reiniciar la referencia del pellizco, o el zoom
	# pega un salto.
	_pinch_distance = _current_pinch()


func _handle_drag(event: InputEventScreenDrag) -> void:
	_touches[event.index] = event.position
	if _touches.size() >= 2:
		var distance := _current_pinch()
		if _pinch_distance > 0.0 and distance > 0.0:
			_zoom_at(_pinch_center(), distance / _pinch_distance)
		_pinch_distance = distance
	else:
		position -= event.relative / zoom
		_clamp_position()


func _current_pinch() -> float:
	if _touches.size() < 2:
		return 0.0
	var points: Array = _touches.values()
	return (points[0] as Vector2).distance_to(points[1] as Vector2)


func _pinch_center() -> Vector2:
	var points: Array = _touches.values()
	if points.size() < 2:
		return get_viewport_rect().size * 0.5
	return ((points[0] as Vector2) + (points[1] as Vector2)) * 0.5


## Zoom **anclado al puntero**: lo que hay bajo el dedo se queda bajo el dedo. Hacerlo hacia
## el centro de la pantalla se siente mal en cuanto el mapa es más grande que la vista.
func _zoom_at(screen_point: Vector2, factor: float) -> void:
	var before := get_screen_transform().affine_inverse() * screen_point
	var target := clampf(zoom.x * factor, ZOOM_MIN, ZOOM_MAX)
	if is_equal_approx(target, zoom.x):
		return
	zoom = Vector2.ONE * target
	# `get_screen_transform` no refleja el zoom nuevo hasta el siguiente fotograma: se
	# reconstruye a mano la posición equivalente.
	var after := get_screen_transform().affine_inverse() * screen_point
	position += before - after
	_clamp_position()


func _clamp_position() -> void:
	if bounds == Vector2.ZERO:
		return
	var view := get_viewport_rect().size / zoom * 0.5
	# Si el mapa cabe entero en pantalla, se queda centrado en vez de poder irse de paseo.
	position.x = bounds.x * 0.5 if view.x >= bounds.x * 0.5 \
		else clampf(position.x, view.x, bounds.x - view.x)
	position.y = bounds.y * 0.5 if view.y >= bounds.y * 0.5 \
		else clampf(position.y, view.y, bounds.y - view.y)
