class_name ScaleCamera
extends Camera2D

## Cámara de escalas: paneo y zoom con ratón y con dedos, y el zoom como **profundidad**.
##
## Antes se llamaba `SettlementCamera` y se quedaba dentro de un nodo. Ahora el zoom atraviesa
## escalas: alejarse más allá de `ZOOM_MIN` sube al padre, y acercarse más allá de `ZOOM_MAX`
## entra en un hijo. El gesto es el de siempre —rueda o pellizco, sin botones de entrar y
## salir—, porque es la principal seña de identidad del juego.
##
## **La cámara no conoce `WorldState`** (regla 7, también aquí): `Main` le dice con `set_focus`
## en qué tier está, quién es el padre y a qué hijo se entra, y cuando la profundidad cruza un
## entero ella solo emite `focus_requested`. Quien cambia el foco es `Main._focus`, la única ruta.
##
## Al acercarse, el hijo en el que se entra es el que está bajo el puntero (`child_picker`, M2), y si
## no hay ninguno, el último visitado.
##
## Desde M3c hay además dos atajos para entrar en un hijo desde la vista agregada, porque la mancha
## se desvanecía antes de llegar al cruce de `ZOOM_MAX` (`ChildMapRenderer.alpha_at`):
## - **zoom anclado**: si se acerca con el puntero sobre una mancha visible, el zoom se ancla a ella
##   (`anchored_child`): converge a su centro, la mancha no se desvanece, y se cruza en cuanto su
##   radio en pantalla llega a `ANCHOR_CROSS_FRACTION` del hueco libre;
## - **clic** (o toque) en una mancha: se pide el hijo en el acto y la cámara vuela hasta ella
##   mientras la vista funde una capa en la otra.
## Los dos cruzan por `focus_requested`, la misma ruta de siempre.
##
## La vista visible se queda en `ZOOM_MIN`/`ZOOM_MAX` mientras la profundidad sigue avanzando unas
## muescas más allá (`OVERSHOOT`), y al cruzar el entero `Main` enfoca el otro nodo. Desde M3 el
## cruce **no reencuadra**: la cámara se lleva consigo (`carry`) el mismo punto del mundo y el
## mismo zoom, y la vista funde una capa en la otra. Sin padre ni hijo, la profundidad se acota
## igual que el zoom, y la cámara se comporta exactamente como la `SettlementCamera` de antes.

## Pide a `Main` que enfoque otro nodo: el padre al alejarse, un hijo al acercarse.
signal focus_requested(node_id: int)

const ZOOM_MIN := 0.35
const ZOOM_MAX := 6.0
const WHEEL_STEP := 1.12
## Lo que hay que seguir empujando más allá del zoom extremo para cruzar de escala: tres muescas
## de rueda. Sin este margen, cualquier muesca de más en el mínimo te sacaría del nodo sin
## quererlo; con él, cruzar es una decisión.
const OVERSHOOT := WHEEL_STEP * WHEEL_STEP * WHEEL_STEP
## Fracción de profundidad a partir de la cual se empieza a preparar el nodo al que se cruzaría
## (`crossing_target`): por encima, el padre; por debajo de `1 − PREFETCH_FROM`, el hijo. 0,75 es
## ×0,6 alejándose y ×3,5 acercándose, unas cuantas muescas antes del cruce.
const PREFETCH_FROM := 0.75
## Segundos que tarda la cámara en volver dentro del mapa tras un cruce. El mapa nuevo puede
## acotar el paneo de otra manera que el viejo, y acotar de golpe sería un salto de la escena.
const SETTLE_SECONDS := 0.5
## Con el zoom anclado a una mancha, se cruza al hijo cuando el **radio** de la mancha en pantalla
## llega a esta fracción del lado corto del hueco libre (o al llegar a `ZOOM_MAX`, lo que antes
## pase: una mancha de un asentamiento recién fundado es tan pequeña que a ×6 aún no llega).
const ANCHOR_CROSS_FRACTION := 1.0 / 3.0
## Cuánto se acerca el centro de la mancha anclada al centro del hueco libre en cada muesca. Un
## tirón suave: lo que hay bajo el puntero no se escapa de golpe, y en las ~12 muescas hasta el cruce
## queda centrada (0,65^12 ≈ 0,6 % del desvío inicial).
const ANCHOR_PULL := 0.35
## Píxeles de pantalla que se puede mover el puntero (o el dedo) entre pulsar y soltar para que
## cuente como clic y no como arrastre. Un dedo nunca se queda quieto del todo.
const CLICK_SLOP := 8.0
## Segundos del vuelo hasta una mancha tras un clic. Lo que dura, más o menos, preparar el hijo y
## fundirlo: la cámara llega cuando la capa nueva ya se ve.
const FLIGHT_SECONDS := 0.45

## Parte entera = tier del nodo enfocado; fracción = zoom dentro de él, de 0 (`ZOOM_MAX` y su
## margen) a casi 1 (`ZOOM_MIN` y su margen). Crece al alejarse, como crecen los tiers.
var depth: float = 0.0

## Ventana de terreno visible, en píxeles y centrada en el origen del mundo.
var bounds := Rect2()

## La parte de la pantalla que **no** tapa el HUD, en píxeles de pantalla.
##
## La cámara no encuadra contra la ventana sino contra este hueco. Con el dock ocupando un
## tercio del ancho, encuadrar contra la ventana entera deja el asentamiento centrado en la
## pantalla y por tanto medio escondido detrás del panel. Vacío hasta que alguien lo fija: la
## ventana entera, que es el comportamiento de siempre.
var view_rect := Rect2()

var _user_moved: bool = false
var _dragging: bool = false
## Toques activos, para distinguir un dedo (paneo) de dos (pellizco).
var _touches: Dictionary = {}
var _pinch_distance: float = 0.0
## El tier del nodo enfocado: la parte entera de `depth`.
var _tier: int = 0
## Hacia dónde se cruza, o -1 si no hay a dónde. Los pone `Main` en cada cambio de foco.
var _parent_id: int = -1
var _child_id: int = -1
## El zoom que pide el gesto, que puede pasarse de los extremos hasta `OVERSHOOT` si hay a dónde
## cruzar. El `zoom` visible es este acotado a `ZOOM_MIN`..`ZOOM_MAX`.
var _wanted_zoom: float = 1.0
## Mientras sea > 0, la cámara vuelve dentro del mapa poco a poco en vez de acotarse de golpe.
var _settle_left: float = 0.0

## Quién hay bajo el puntero al acercarse: una función de `Main` que recibe un punto del mundo y
## devuelve el id del hijo pintado ahí (`ChildMapRenderer.child_at`), o -1. La cámara sigue sin
## conocer `WorldState`: solo pregunta. Sin función, o sin hijo bajo el puntero, se entra en el
## último visitado (`_child_id`), como en M1.
var child_picker := Callable()
## Dónde está y cuánto mide la mancha de un hijo: una función de `Main` que recibe el id y devuelve
## `Vector3(x, y, radio)` en coordenadas del mundo (`ChildMapRenderer.blob_of`), con radio ≤ 0 si
## no hay mancha. Para el zoom anclado y el vuelo del clic. Igual que `child_picker`: la cámara
## pregunta, no conoce `WorldState`.
var blob_locator := Callable()

## El hijo al que está anclado el zoom, o -1. Lo lee `Main` para que esa mancha no se desvanezca.
var _anchor_id: int = -1
## El vuelo tras un clic: el hijo, de dónde y a dónde (centro del hueco libre y zoom), y cuánto va
## (0..1). `_flight_id` < 0 es que no se vuela.
var _flight_id: int = -1
var _flight_from := Vector2.ZERO
var _flight_to := Vector2.ZERO
var _flight_from_zoom: float = 1.0
var _flight_to_zoom: float = 1.0
var _flight_t: float = 0.0
## El clic en curso: dónde se pulsó y si ya se ha movido demasiado para serlo. `_press_valid` falso
## es que no hay clic posible (no se pulsó, o se movió, o entró un segundo dedo).
var _press_at := Vector2.ZERO
var _press_valid: bool = false


## `Main` avisa del nodo enfocado tras cada `_focus`: su tier, su padre y el hijo en el que se
## entra al acercarse (en M1, el último visitado desde aquí). -1 es «no hay».
##
## Cambiar de foco reinicia «el jugador no la ha tocado»: lo que miraba en el nodo de antes no
## dice nada del nuevo, y sin esto el primer reencuadre tras entrar en un hijo no llegaría nunca.
## Salvo con `keep_view`: si el cruce lo ha hecho el propio zoom, el jugador sí la ha tocado, y
## un reencuadre automático le robaría el gesto a medias.
func set_focus(tier: int, parent_id: int, child_id: int, keep_view := false) -> void:
	_tier = tier
	_parent_id = parent_id
	_child_id = child_id
	_user_moved = keep_view
	# El ancla es de una mancha del nodo de antes. El vuelo, en cambio, sigue: el cruce del clic se
	# pide al empezarlo, y `carry` ya le ha movido el destino con la vista.
	_anchor_id = -1
	_wanted_zoom = zoom.x
	depth = _depth_for(_wanted_zoom)


## Encuadra la mancha construida dentro de la ventana de terreno.
##
## Lo que se encuadra es el asentamiento, **no el mapa**: a la distancia del mapa entero los
## habitantes miden un píxel y no se ve nada de lo que hace especial al juego. Y se encuadra
## en `view`, el hueco que deja el HUD, no en la ventana.
func frame(extent: Rect2, world_bounds: Rect2, view: Rect2) -> void:
	_settle_left = 0.0
	_flight_id = -1
	_anchor_id = -1
	bounds = world_bounds
	view_rect = view
	if extent.size.x > 0.0 and extent.size.y > 0.0:
		var fit := minf(view.size.x / extent.size.x, view.size.y / extent.size.y)
		zoom = Vector2.ONE * clampf(fit, ZOOM_MIN, ZOOM_MAX)
	_wanted_zoom = zoom.x
	depth = _depth_for(_wanted_zoom)
	_set_view_center(extent.get_center())
	_clamp_position()


## El foco ha cambiado y la vista ha movido su origen `shift` píxeles: la cámara se mueve lo mismo
## para seguir mirando **el mismo punto del mundo**, con el mismo zoom. Es lo que hace del cruce
## un fundido y no un corte. Si el mapa nuevo acota el paneo de otra manera, se vuelve dentro
## poco a poco (`SETTLE_SECONDS`).
func carry(shift: Vector2, world_bounds: Rect2, view: Rect2) -> void:
	position += shift
	# El vuelo de un clic va en coordenadas del mundo, que acaban de moverse con la vista.
	_flight_from += shift
	_flight_to += shift
	bounds = world_bounds
	view_rect = view
	_settle_left = SETTLE_SECONDS


func _process(delta: float) -> void:
	if _flight_id >= 0:
		# El vuelo manda sobre el reposo: acaba en el centro del hijo, que está dentro del mapa.
		_settle_left = maxf(_settle_left - delta, 0.0)
		_advance_flight(delta)
		return
	if _settle_left <= 0.0:
		return
	_settle_left -= delta
	var target := _clamped(_view_center())
	if _settle_left <= 0.0:
		_set_view_center(target)
		return
	# Exponencial y no lineal: arranca con el gesto y se posa, sin un frenazo al final.
	_set_view_center(_view_center().lerp(target, 1.0 - exp(-delta * 10.0)))


## Reencuadra solo si el jugador no ha tocado la cámara: crecer el pueblo no puede robarle
## el zoom a quien está mirando un detalle.
func reframe_if_untouched(extent: Rect2, world_bounds: Rect2, view: Rect2) -> void:
	# El mapa puede haber crecido —y el HUD haber cambiado de forma— aunque no toque reencuadrar.
	bounds = world_bounds
	view_rect = view
	if _user_moved:
		_clamp_position()
		return
	frame(extent, world_bounds, view)


## El punto del mundo que cae en el centro del hueco libre.
##
## `position` es el punto que cae en el centro de la **ventana**. Cuando el HUD tapa un lado,
## los dos dejan de coincidir, y todo lo que se razona en términos de «lo que el jugador ve»
## —encuadrar y acotar el paneo— tiene que hacerse con este, no con `position`.
func _view_center() -> Vector2:
	return position + _view_shift()


func _set_view_center(point: Vector2) -> void:
	position = point - _view_shift()


func _view_shift() -> Vector2:
	if view_rect.size == Vector2.ZERO:
		return Vector2.ZERO
	return (view_rect.get_center() - get_viewport_rect().size * 0.5) / zoom


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _dragging:
		_user_moved = true
	elif event is InputEventMouseButton and event.button_index in [
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		_user_moved = true
	elif event is InputEventScreenDrag or event is InputEventMagnifyGesture:
		_user_moved = true
	# Cualquier gesto del jugador le devuelve la cámara: el vuelo de un clic se para donde esté.
	# (Pulsar sin mover aún no lo es: puede ser el segundo toque del mismo clic.)
	if _flight_id >= 0 and (event is InputEventScreenDrag or event is InputEventMagnifyGesture
			or (event is InputEventMouseMotion and _dragging)
			or (event is InputEventMouseButton and event.button_index in [
				MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN])):
		_flight_id = -1

	if event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion and _dragging:
		_track_press(event.position)
		_pan(event.relative)
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
			# El clic es del botón izquierdo y del ratón de verdad: el que Godot emula desde un
			# toque (`DEVICE_ID_EMULATION`) ya lo cuenta `_handle_touch`, y contarlo dos veces
			# pediría el hijo dos veces.
			if event.button_index == MOUSE_BUTTON_LEFT \
					and event.device != InputEvent.DEVICE_ID_EMULATION:
				if event.pressed:
					_press_at = event.position
					_press_valid = true
				elif _press_valid:
					_press_valid = false
					if event.position.distance_to(_press_at) <= CLICK_SLOP:
						click_at(event.position)
		MOUSE_BUTTON_WHEEL_UP:
			if event.pressed:
				_zoom_at(event.position, WHEEL_STEP)
		MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed:
				_zoom_at(event.position, 1.0 / WHEEL_STEP)


func _handle_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		_touches[event.index] = event.position
		# Un toque es un dedo solo que se levanta donde se puso. Con un segundo dedo es pellizco.
		_press_valid = _touches.size() == 1
		_press_at = event.position
	else:
		_touches.erase(event.index)
		if _press_valid and _touches.is_empty():
			_press_valid = false
			if event.position.distance_to(_press_at) <= CLICK_SLOP:
				click_at(event.position)
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
		_track_press(event.position)
		_pan(event.relative)


## Pulsar y arrastrar más de `CLICK_SLOP` deja de ser un clic.
func _track_press(screen_point: Vector2) -> void:
	if _press_valid and screen_point.distance_to(_press_at) > CLICK_SLOP:
		_press_valid = false


## Paneo de un dedo o del ratón. Panear suelta el ancla: quien aparta la vista de la mancha ya no
## quiere entrar en ella, y el siguiente zoom no puede arrastrarle de vuelta.
func _pan(relative: Vector2) -> void:
	position -= relative / zoom
	_anchor_id = -1
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
##
## Más allá de los extremos el zoom visible no se mueve, pero la profundidad sí: si hay padre
## (o hijo) se sigue empujando hasta `OVERSHOOT`, y al cruzar el entero se pide el cambio de foco.
func _zoom_at(screen_point: Vector2, factor: float) -> void:
	# Alejar suelta el ancla: es la forma de arrepentirse de entrar.
	if factor < 1.0:
		_anchor_id = -1
	elif factor > 1.0 and _anchor_id < 0:
		_anchor_id = _blob_under(screen_point)
	if _anchor_id >= 0 and factor > 1.0 and _zoom_anchored(factor):
		return
	# Si alguien ha puesto el zoom a mano (`--shot-zoom`), manda el visible.
	if not is_equal_approx(clampf(_wanted_zoom, ZOOM_MIN, ZOOM_MAX), zoom.x):
		_wanted_zoom = zoom.x
	# Dar marcha atrás desde el margen vuelve en el acto: el margen solo se acumula empujando.
	var wanted := _wanted_zoom
	if factor > 1.0:
		wanted = maxf(wanted, ZOOM_MIN)
	elif factor < 1.0:
		wanted = minf(wanted, ZOOM_MAX)
	wanted *= factor
	# El hijo en el que se entraría: el que está bajo el puntero, si lo hay. Solo se pregunta
	# pasado `ZOOM_MAX`, que es el único sitio donde importa.
	var child := _child_id
	if wanted > ZOOM_MAX:
		child = _child_under(screen_point)
	var low := ZOOM_MIN / OVERSHOOT if _parent_id >= 0 else ZOOM_MIN
	var high := ZOOM_MAX * OVERSHOOT if child >= 0 else ZOOM_MAX
	if _parent_id >= 0 and wanted <= low * (1.0 + 1e-9):
		# Se cruza el entero hacia arriba. `Main` enfoca al padre y lo encuadra desde cero, así
		# que aquí no se toca nada más.
		depth = float(_tier + 1)
		focus_requested.emit(_parent_id)
		return
	if child >= 0 and wanted >= high * (1.0 - 1e-9):
		depth = float(_tier) - 1e-6
		focus_requested.emit(child)
		return
	_wanted_zoom = clampf(wanted, low, high)
	depth = _depth_for(_wanted_zoom)

	var before := get_screen_transform().affine_inverse() * screen_point
	var target := clampf(_wanted_zoom, ZOOM_MIN, ZOOM_MAX)
	if is_equal_approx(target, zoom.x):
		return
	zoom = Vector2.ONE * target
	# `get_screen_transform` no refleja el zoom nuevo hasta el siguiente fotograma: se
	# reconstruye a mano la posición equivalente.
	var after := get_screen_transform().affine_inverse() * screen_point
	position += before - after
	_clamp_position()


## Zoom anclado a la mancha `_anchor_id`: acerca hacia **su centro**, no hacia el puntero, tirando
## de él hacia el centro del hueco libre (`ANCHOR_PULL`), y cruza en cuanto su radio en pantalla
## llega a `ANCHOR_CROSS_FRACTION` (o a `ZOOM_MAX`). Devuelve falso si la mancha ya no existe: el
## ancla se suelta y el zoom sigue como siempre.
func _zoom_anchored(factor: float) -> bool:
	var blob := _blob(_anchor_id)
	if blob.z <= 0.0:
		_anchor_id = -1
		return false
	var center := Vector2(blob.x, blob.y)
	var cross_zoom := _cross_zoom(blob.z)
	var target := minf(zoom.x * factor, cross_zoom)
	var goal := _world_to_screen(center).lerp(_free_center(), ANCHOR_PULL)
	zoom = Vector2.ONE * target
	position = center - (goal - get_viewport_rect().size * 0.5) / zoom
	_wanted_zoom = target
	depth = _depth_for(target)
	_clamp_position()
	if target >= cross_zoom * (1.0 - 1e-9):
		var id := _anchor_id
		_anchor_id = -1
		depth = float(_tier) - 1e-6
		focus_requested.emit(id)
	return true


## Un clic (o un toque) en `screen_point`: si cae sobre una mancha visible, se pide ese hijo **en el
## acto** y la cámara vuela hasta ella (`FLIGHT_SECONDS`) mientras la vista prepara y funde el
## cruce. Fuera de una mancha, o con un vuelo ya en marcha, no hace nada: un clic no es un paneo.
func click_at(screen_point: Vector2) -> void:
	if _flight_id >= 0:
		return
	var id := _blob_under(screen_point)
	if id < 0:
		return
	var blob := _blob(id)
	_anchor_id = -1
	_flight_id = id
	_flight_t = 0.0
	_flight_from = _view_center()
	_flight_to = Vector2(blob.x, blob.y)
	_flight_from_zoom = zoom.x
	_flight_to_zoom = _cross_zoom(blob.z)
	_user_moved = true
	# Primero el vuelo y luego la señal: `Main` hace `carry` dentro de ella y mueve el vuelo con la
	# vista. Y el vuelo sigue después del cruce, ya dentro del hijo.
	focus_requested.emit(id)


## El hijo al que está anclado el zoom, o -1. La mancha anclada no se desvanece.
func anchored_child() -> int:
	return _anchor_id


## El hijo hacia el que se vuela tras un clic, o -1.
func flying_to() -> int:
	return _flight_id


func _advance_flight(delta: float) -> void:
	_flight_t = minf(_flight_t + delta / FLIGHT_SECONDS, 1.0)
	# Suave a la salida y a la llegada; el zoom en escala logarítmica, como la rueda.
	var t := smoothstep(0.0, 1.0, _flight_t)
	var z := _flight_from_zoom * pow(_flight_to_zoom / _flight_from_zoom, t)
	zoom = Vector2.ONE * z
	_wanted_zoom = z
	depth = _depth_for(z)
	_set_view_center(_flight_from.lerp(_flight_to, t))
	if _flight_t >= 1.0:
		_flight_id = -1
		_settle_left = 0.0
		_clamp_position()


## La mancha visible bajo un punto de pantalla, o -1. Solo en la vista agregada
## (`ChildMapRenderer.shows_at`, la misma regla con la que `Main` la enseña): una mancha que no se
## ve no se puede tocar. Y solo si hay a quién preguntar por su sitio.
func _blob_under(screen_point: Vector2) -> int:
	if not child_picker.is_valid() or not blob_locator.is_valid():
		return -1
	if not ChildMapRenderer.shows_at(depth):
		return -1
	var id: int = child_picker.call(screen_to_world(screen_point))
	if id < 0 or _blob(id).z <= 0.0:
		return -1
	return id


func _blob(id: int) -> Vector3:
	if id < 0 or not blob_locator.is_valid():
		return Vector3(0.0, 0.0, -1.0)
	return blob_locator.call(id)


## El zoom al que una mancha de `radius` píxeles de mundo llena `ANCHOR_CROSS_FRACTION` del lado
## corto del hueco libre; como mucho `ZOOM_MAX`.
func _cross_zoom(radius: float) -> float:
	var size := view_rect.size if view_rect.size != Vector2.ZERO else get_viewport_rect().size
	return minf(minf(size.x, size.y) * ANCHOR_CROSS_FRACTION / maxf(radius, 1e-3), ZOOM_MAX)


## El centro del hueco libre, en píxeles del viewport.
func _free_center() -> Vector2:
	return view_rect.get_center() if view_rect.size != Vector2.ZERO \
			else get_viewport_rect().size * 0.5


## La inversa de `screen_to_world`.
func _world_to_screen(world_point: Vector2) -> Vector2:
	return (world_point - position) * zoom + get_viewport_rect().size * 0.5


## El hijo bajo el puntero según `child_picker`, o el último visitado si no hay ninguno.
func _child_under(screen_point: Vector2) -> int:
	if child_picker.is_valid():
		var picked: int = child_picker.call(screen_to_world(screen_point))
		if picked >= 0:
			return picked
	return _child_id


## Un punto de pantalla (del viewport) en coordenadas del mundo. Se calcula con `position` y `zoom`
## y no con `get_screen_transform`, que no ve el zoom nuevo hasta el siguiente fotograma.
func screen_to_world(screen_point: Vector2) -> Vector2:
	return position + (screen_point - get_viewport_rect().size * 0.5) / zoom


## El nodo al que se cruzaría si se sigue empujando el zoom, para ir preparándolo (`SettlementView
## .prefetch`): el padre si ya se está lejos, el hijo bajo el puntero (o el último visitado) si se
## está cerca, y -1 en medio. La cámara sigue sin conocer `WorldState`: devuelve un id.
func crossing_target(screen_point: Vector2) -> int:
	# Con el zoom anclado se sabe ya a dónde se va, sea cual sea la profundidad.
	if _anchor_id >= 0:
		return _anchor_id
	var frac := depth - floorf(depth)
	if _parent_id >= 0 and frac >= PREFETCH_FROM:
		return _parent_id
	if frac <= 1.0 - PREFETCH_FROM:
		return _child_under(screen_point)
	return -1


## Pone la cámara a una profundidad concreta dentro del nodo enfocado: la parte decimal de `d` se
## convierte en zoom con la inversa de `_depth_for`. La parte entera la manda `set_focus`. Para la
## captura de la vista agregada (`--shot-depth`); cuenta como que el jugador la ha movido, para que
## el reencuadre automático no se la lleve.
func set_depth(d: float) -> void:
	var top := ZOOM_MAX * OVERSHOOT
	var bottom := ZOOM_MIN / OVERSHOOT
	var frac := clampf(d - floorf(d), 0.0, 0.999999)
	_wanted_zoom = top / pow(top / bottom, frac)
	zoom = Vector2.ONE * clampf(_wanted_zoom, ZOOM_MIN, ZOOM_MAX)
	depth = _depth_for(_wanted_zoom)
	_user_moved = true
	_clamp_position()


## Centra el hueco libre en un punto del mundo, dentro de lo que deja el paneo.
func center_on(point: Vector2) -> void:
	_set_view_center(point)
	_clamp_position()


## Acota el paneo contra el borde del mapa.
##
## Se acota el **hueco libre**, no la ventana: así el vacío de más allá del terreno queda
## exactamente detrás del HUD, que es opaco, en vez de asomar por la zona jugable.
##
## Tras un cruce (`carry`) no acota de golpe: lo hace `_process` poco a poco.
func _clamp_position() -> void:
	if _settle_left > 0.0:
		return
	_set_view_center(_clamped(_view_center()))


func _clamped(point: Vector2) -> Vector2:
	if bounds.size == Vector2.ZERO:
		return point
	var size := view_rect.size if view_rect.size != Vector2.ZERO else get_viewport_rect().size
	var half := size / zoom * 0.5
	var center := bounds.get_center()
	# Si el mapa cabe entero en el hueco, se queda centrado en vez de poder irse de paseo.
	point.x = center.x if half.x * 2.0 >= bounds.size.x \
		else clampf(point.x, bounds.position.x + half.x, bounds.end.x - half.x)
	point.y = center.y if half.y * 2.0 >= bounds.size.y \
		else clampf(point.y, bounds.position.y + half.y, bounds.end.y - half.y)
	return point


## La profundidad de un zoom pedido, en escala logarítmica —cada muesca de rueda vale lo mismo—:
## `ZOOM_MAX` con su margen es la parte entera justa, y `ZOOM_MIN` con el suyo, el entero de arriba.
func _depth_for(wanted: float) -> float:
	var top := ZOOM_MAX * OVERSHOOT
	var bottom := ZOOM_MIN / OVERSHOOT
	var frac := log(top / clampf(wanted, bottom, top)) / log(top / bottom)
	return float(_tier) + clampf(frac, 0.0, 0.999999)
