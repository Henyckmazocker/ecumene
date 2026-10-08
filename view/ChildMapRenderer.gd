class_name ChildMapRenderer
extends Node2D

## La vista agregada: los hijos del nodo enfocado como **manchas** sobre su propio terreno, y las
## expediciones en camino como marcas que viajan del nodo a donde nacerá la colonia.
##
## **Solo lee** (regla 7). Las posiciones salen de `WorldState.world_pos_of` y de
## `predicted_child_pos`, el tamaño de `total_pop` y el aviso de hambre del mismo
## `Integrator.snapshot` que usa el HUD. No hay estado nuevo: si se tira el renderer y se monta
## otro, pinta exactamente lo mismo.
##
## Las manchas **no son multitud** (regla 1): un hijo es un vector de stats, y aquí se pinta ese
## vector, no a su gente. La gente solo existe en el nodo enfocado.
##
## Un `MultiMesh` por tipo de marca, nunca un nodo de escena por hijo (regla 8): una región con
## seis pueblos y veinticuatro asentamientos son dos `MultiMesh` y un `_draw`, no treinta nodos.
##
## Va **en coordenadas locales de la `SettlementView`**: el nodo enfocado en (0, 0) y `cell_size`
## píxeles por celda. Un hijo cae en `(world_pos_of(hijo) − world_pos_of(enfocado)) × cell_size`,
## que es el mismo sitio del terreno del padre donde está de verdad.

## Fracción de profundidad (la parte decimal de `ScaleCamera.depth`) en el centro del fundido de
## la vista agregada. 0,5 es la mitad alejada del zoom del nodo, ×1,45: más cerca no caben los
## hijos en pantalla —caen a 35-58 celdas del centro— y las manchas solo taparían el detalle del
## pueblo. En M2 era un corte; desde M3 es un fundido de `FADE_DEPTH` de ancho centrado aquí.
const SHOW_FROM_DEPTH := 0.5
## Ancho del fundido, en fracción de profundidad: ~0,2 son unas cuatro muescas de rueda.
const FADE_DEPTH := 0.2

## Radio de una mancha, en celdas: un mínimo para que un asentamiento recién fundado se vea, más
## la raíz de la población —el área crece con la gente, no el radio—, con un techo por debajo de
## la mitad de la separación mínima entre hermanos (`WorldState.PLACE_SIBLING_GAP`, ~14 celdas en
## los nietos) para que dos manchas vecinas no se monten.
const BLOB_MIN_CELLS := 2.5
const BLOB_PER_SQRT_POP := 0.3
const BLOB_MAX_CELLS := 7.0
## Radio de la marca de una expedición, en celdas.
const EXPEDITION_CELLS := 1.6

## Color por escala del hijo. La aldea es cálida y apagada, y cada escala sube de tono: de un
## vistazo se ve qué hijos ya son pueblos.
const TIER_COLORS := [
	Color(0.93, 0.82, 0.52),  # asentamiento
	Color(0.96, 0.58, 0.26),  # pueblo
	Color(0.80, 0.38, 0.72),  # ciudad
	Color(0.38, 0.58, 0.94),  # región
	Color(0.30, 0.80, 0.72),  # país
	Color(0.92, 0.86, 0.30),  # imperio
	Color(0.95, 0.95, 0.95),  # planeta
]
## Hacia dónde se tiñe un hijo que pasa hambre. Mezclado, no sustituido: tiene que seguir
## leyéndose qué escala es.
const HUNGER_TINT := Color(0.92, 0.12, 0.10)
const HUNGER_MIX := 0.65

## Tamaño de la letra de los nombres, en píxeles **de pantalla**: se dibujan deshaciendo el zoom,
## así que miden lo mismo a cualquier distancia.
const LABEL_SIZE := 14
const LABEL_OUTLINE := 4

## Píxeles de mundo por celda. Lo fija la `SettlementView` (su `TILE`).
var cell_size: float = 16.0

## Lo último que se pintó, en coordenadas locales. Paralelos por índice.
var _ids := PackedInt32Array()
var _centers := PackedVector2Array()
var _radii := PackedFloat32Array()
var _names := PackedStringArray()
var _starving := PackedByteArray()
var _tiers := PackedByteArray()
## Expediciones: dónde va ahora la marca, a dónde va, y qué fracción del viaje lleva.
var _exp_positions := PackedVector2Array()
var _exp_targets := PackedVector2Array()
var _exp_progress := PackedFloat32Array()
## Destino previsto de cada expedición (clave → `Vector2i`). `predicted_child_pos` coloca un hijo
## de mentira con el algoritmo de `world_pos_of`, y eso cuesta decenas de muestras de ruido: con
## el árbol quieto sale lo mismo, así que se calcula una vez por forma del árbol.
var _target_cache: Dictionary = {}

var _blob_mesh: MultiMeshInstance2D
var _expedition_mesh: MultiMeshInstance2D
## Los nombres van en un nodo hijo para quedar **encima** de los `MultiMesh`: el `_draw` propio de
## un `CanvasItem` se pinta antes que sus hijos, y ahí van las líneas de viaje, que sí van debajo.
var _labels: Node2D
var _font: Font

## La opacidad de la vista agregada (`set_fade`) y la mancha que no se desvanece: la del hijo al que
## está anclado el zoom (M3c). Van por el color de cada instancia y no por el `modulate` del nodo,
## que lo tiñe todo por igual.
var _alpha: float = 1.0
var _pinned_id: int = -1
## La opacidad con que se pinta ahora la mancha anclada; 0 si no hay o si no es de este foco.
var _pinned_alpha_now: float = 0.0
## El «fantasma» de la mancha por la que se acaba de entrar (`hand_off`): tras el cruce, el hijo es
## el foco y su mancha ya no está entre las manchas, pero quitarla de golpe sería un salto. Se queda
## en el origen —donde ahora está el hijo— y se apaga mientras su capa se enciende.
var _ghost: Sprite2D
var _ghost_strength: float = 0.0


func _init() -> void:
	var disk := _disk_texture()
	_blob_mesh = _make_multimesh(disk)
	add_child(_blob_mesh)
	_expedition_mesh = _make_multimesh(disk)
	add_child(_expedition_mesh)
	_ghost = Sprite2D.new()
	_ghost.texture = disk
	_ghost.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_ghost.visible = false
	add_child(_ghost)
	_labels = Node2D.new()
	_labels.draw.connect(_draw_labels)
	add_child(_labels)
	# La fuente del tema de proyecto, la misma del HUD (con su reserva de emoji); sin tema, la de
	# Godot. Se toma una vez: nada de temas por control (ver el CLAUDE.md del repo).
	var theme := ThemeDB.get_project_theme()
	_font = theme.default_font if theme != null and theme.default_font != null \
			else ThemeDB.fallback_font


## Opacidad de la vista agregada a esta profundidad de cámara: 0 de cerca, 1 de lejos, y entre
## medias un fundido continuo (smoothstep) centrado en `SHOW_FROM_DEPTH`. **La regla de
## visibilidad**, una sola para `Main` y para los tests. Va por `modulate.a`, nunca por tema.
static func alpha_at(depth: float) -> float:
	var frac := depth - floorf(depth)
	return smoothstep(SHOW_FROM_DEPTH - FADE_DEPTH * 0.5, SHOW_FROM_DEPTH + FADE_DEPTH * 0.5, frac)


## Si a esta profundidad se ve algo de la vista agregada.
static func shows_at(depth: float) -> bool:
	return alpha_at(depth) > 0.0


## La opacidad de la vista agregada (la de `alpha_at` por la del fundido de capas), salvo para la
## mancha `pinned_id`, que se queda a `pinned_alpha` —entera— aunque las demás se apaguen: es la del
## hijo al que se está acercando el zoom anclado (M3c), y si se desvaneciera el jugador perdería de
## vista justo aquello en lo que entra. `ghost_fade` es cuánto queda del fantasma de `hand_off`
## (1 recién cruzado, 0 con la capa del hijo ya entera). Barato si nada cambia.
func set_fade(alpha: float, pinned_id := -1, pinned_alpha := 1.0, ghost_fade := 0.0) -> void:
	_set_ghost(ghost_fade)
	var pinned := _pinned_alpha_for(pinned_id, pinned_alpha)
	if is_equal_approx(alpha, _alpha) and pinned_id == _pinned_id \
			and is_equal_approx(pinned, _pinned_alpha_now):
		return
	_alpha = alpha
	_pinned_id = pinned_id
	_pinned_alpha_now = pinned
	# Las líneas de viaje van en el `_draw` propio: `self_modulate` las apaga sin tocar a los hijos.
	self_modulate.a = alpha
	_expedition_mesh.modulate.a = alpha
	_write_blob_colors()
	_labels.queue_redraw()


func _pinned_alpha_for(pinned_id: int, pinned_alpha: float) -> float:
	return pinned_alpha if pinned_id >= 0 and _ids.has(pinned_id) else 0.0


## Opacidad con que se pinta la mancha `i`.
func _blob_alpha(i: int) -> float:
	return _pinned_alpha_now if _ids[i] == _pinned_id else _alpha


## Si hay algo que dibujar: manchas o marcas con opacidad, la mancha anclada o el fantasma.
func shows_anything() -> bool:
	return (has_content() and _alpha > 0.0) or _pinned_alpha_now > 0.0 or _ghost.visible


## Se va a entrar en el hijo `id` (cruce hacia abajo): su mancha se queda como fantasma en el
## origen, con la opacidad que tenía, y `set_fade` la apaga mientras se enciende la capa del hijo.
## Sin esto, la mancha anclada —entera hasta el último momento— desaparecería de un fotograma a otro.
func hand_off(id: int) -> void:
	var i := _ids.find(id)
	if i < 0:
		return
	_ghost_strength = _blob_alpha(i)
	if _ghost_strength <= 0.0:
		return
	var color := _blob_color(i)
	_ghost.self_modulate = Color(color, _ghost_strength)
	# El disco es de 64 téxeles: se escala para medir el diámetro de la mancha.
	_ghost.scale = Vector2.ONE * _radii[i] * 2.0 / float(_ghost.texture.get_width())
	_ghost.position = Vector2.ZERO
	_ghost.visible = true


func _set_ghost(fade: float) -> void:
	if not _ghost.visible:
		return
	if fade <= 0.0:
		_ghost.visible = false
		_ghost_strength = 0.0
		return
	_ghost.self_modulate.a = _ghost_strength * clampf(fade, 0.0, 1.0)


## Centro y radio de la mancha de un hijo, en coordenadas locales: `Vector3(x, y, radio)`, con
## radio −1 si no se pinta. Para que la cámara ancle el zoom y vuele hasta ella sin conocer el
## estado.
func blob_of(id: int) -> Vector3:
	var i := _ids.find(id)
	if i < 0:
		return Vector3(0.0, 0.0, -1.0)
	return Vector3(_centers[i].x, _centers[i].y, _radii[i])


## Relee los hijos y las expediciones del nodo enfocado. Barato —O(hijos + expediciones)— y sin
## escribir nada: `mods` son los del motor (`SimEngine.current_modifiers`) para los hijos que lleva
## el jugador; los delegados se miran con los suyos, como los integra el motor.
func refresh(focus: SimNode, state: WorldState, params: SimParams,
		mods: Integrator.Modifiers = null) -> void:
	_ids.clear()
	_centers.clear()
	_radii.clear()
	_names.clear()
	_starving.clear()
	_tiers.clear()
	_exp_positions.clear()
	_exp_targets.clear()
	_exp_progress.clear()
	if focus != null and state != null:
		_collect_children(focus, state, params, mods)
		_collect_expeditions(focus, state)
	_write_meshes()
	queue_redraw()
	_labels.queue_redraw()


func _collect_children(focus: SimNode, state: WorldState, params: SimParams,
		mods: Integrator.Modifiers) -> void:
	var origin := state.world_pos_of(focus)
	var delegated_mods: Integrator.Modifiers = null
	for cid in focus.children:
		var child := state.get_node_by_id(cid)
		if child == null:
			continue
		var hungry := false
		if params != null:
			var m := mods
			if child.is_delegated():
				if delegated_mods == null:
					delegated_mods = SimEngine.delegated_modifiers(state, params)
				m = delegated_mods
			hungry = Integrator.snapshot(child, params, m).starving
		_ids.append(child.id)
		_centers.append(Vector2(state.world_pos_of(child) - origin) * cell_size)
		_radii.append(blob_radius_cells(child.total_pop) * cell_size)
		_names.append(child.name)
		_starving.append(1 if hungry else 0)
		_tiers.append(child.tier)


## Una marca por expedición que sale de este nodo, interpolada entre el nodo y el sitio donde nacerá
## la colonia. El id que tendrá es `next_id` más su puesto en `expeditions`, que va en orden de
## llegada y cada llegada funda un nodo con el siguiente id; así el destino es **exacto** mientras
## el árbol no cambie, y al llegar la marca se convierte en la mancha justo donde estaba.
func _collect_expeditions(focus: SimNode, state: WorldState) -> void:
	var origin := state.world_pos_of(focus)
	for i in state.expeditions.size():
		var e: Expedition = state.expeditions[i]
		if e.parent_id != focus.id:
			continue
		var future_id := state.next_id + i
		var key := "%d:%d:%d:%d" % [future_id, focus.id, state.nodes.size(), state.next_id]
		if not _target_cache.has(key):
			if _target_cache.size() > 32:
				_target_cache.clear()
			_target_cache[key] = state.predicted_child_pos(focus, future_id)
		var target := Vector2((_target_cache[key] as Vector2i) - origin) * cell_size
		var span := e.arrive_cycle - e.depart_cycle
		var t := clampf((state.cycle - e.depart_cycle) / span, 0.0, 1.0) if span > 0.0 else 1.0
		_exp_targets.append(target)
		_exp_progress.append(t)
		_exp_positions.append(target * t)


static func blob_radius_cells(total_pop: float) -> float:
	return clampf(BLOB_MIN_CELLS + BLOB_PER_SQRT_POP * sqrt(maxf(total_pop, 0.0)),
			BLOB_MIN_CELLS, BLOB_MAX_CELLS)


static func tier_color(tier: int) -> Color:
	return TIER_COLORS[clampi(tier, 0, TIER_COLORS.size() - 1)]


func _write_meshes() -> void:
	var mm := _blob_mesh.multimesh
	mm.instance_count = _ids.size()
	# La mancha anclada pudo ser de otro foco: se vuelve a mirar si sigue entre las de ahora.
	_pinned_alpha_now = _pinned_alpha_now if _ids.has(_pinned_id) else 0.0
	for i in _ids.size():
		var d := _radii[i] * 2.0
		mm.set_instance_transform_2d(i, Transform2D(0.0, Vector2(d, d), 0.0, _centers[i]))
	_write_blob_colors()
	var em := _expedition_mesh.multimesh
	em.instance_count = _exp_positions.size()
	var size := Vector2.ONE * EXPEDITION_CELLS * 2.0 * cell_size
	for i in _exp_positions.size():
		em.set_instance_transform_2d(i, Transform2D(0.0, size, 0.0, _exp_positions[i]))
		em.set_instance_color(i, Color(1.0, 0.97, 0.88))


## El color de cada mancha lleva su opacidad: así una puede quedarse entera mientras las demás se
## apagan, cosa que el `modulate` del nodo no permite.
func _write_blob_colors() -> void:
	var mm := _blob_mesh.multimesh
	for i in mini(_ids.size(), mm.instance_count):
		mm.set_instance_color(i, Color(_blob_color(i), _blob_alpha(i)))


func _blob_color(i: int) -> Color:
	var color := tier_color(_tiers[i])
	if _starving[i] == 1:
		color = color.lerp(HUNGER_TINT, HUNGER_MIX)
	return color


## El hijo bajo un punto en coordenadas locales (las de la `SettlementView`), o -1. O(hijos), sin
## física: contra los círculos que se acaban de pintar. Si dos se tocan, gana el centro más cercano.
func child_at(local_point: Vector2) -> int:
	var best := -1
	var best_d := INF
	for i in _ids.size():
		var d := local_point.distance_to(_centers[i])
		if d <= _radii[i] and d < best_d:
			best = _ids[i]
			best_d = d
	return best


## El rectángulo que ocupan las manchas, las marcas y los destinos, con el nodo dentro. Para
## encuadrar la vista agregada en la captura.
func content_rect() -> Rect2:
	var rect := Rect2(Vector2.ZERO, Vector2.ZERO)
	for i in _centers.size():
		rect = rect.merge(Rect2(_centers[i] - Vector2.ONE * _radii[i], Vector2.ONE * _radii[i] * 2.0))
	for p in _exp_targets:
		rect = rect.expand(p)
	return rect


func has_content() -> bool:
	return not _ids.is_empty() or not _exp_positions.is_empty()


func _process(_delta: float) -> void:
	# Las líneas y los nombres se dibujan a grosor y tamaño de pantalla, así que dependen del zoom:
	# se rehacen cada fotograma mientras se ven. Son unas pocas llamadas de dibujo.
	if is_visible_in_tree():
		queue_redraw()
		_labels.queue_redraw()


## Escala de pantalla de este nodo: cuántos píxeles de pantalla mide uno de mundo.
func _screen_scale() -> float:
	var s := get_global_transform_with_canvas().get_scale().x
	return s if s > 0.0 else 1.0


## Debajo de las marcas: el trayecto de cada expedición, hecho y por hacer, y un anillo donde
## nacerá la colonia.
func _draw() -> void:
	var px := 1.0 / _screen_scale()
	for i in _exp_targets.size():
		var target := _exp_targets[i]
		var now := _exp_positions[i]
		draw_line(Vector2.ZERO, now, Color(1.0, 0.97, 0.88, 0.85), 2.0 * px)
		draw_dashed_line(now, target, Color(1.0, 0.97, 0.88, 0.55), 2.0 * px, 8.0 * px)
		draw_arc(target, BLOB_MIN_CELLS * cell_size, 0.0, TAU, 32,
				Color(1.0, 0.97, 0.88, 0.55), 2.0 * px)


## Los nombres, encima de todo y deshaciendo el zoom. Solo los que caben enteros en pantalla: a
## medio salir no se leen y ensucian el borde.
func _draw_labels() -> void:
	if _font == null:
		return
	var xf := get_global_transform_with_canvas()
	var scale := _screen_scale()
	var screen := get_viewport_rect()
	for i in _ids.size():
		_label(xf, scale, screen, _centers[i] + Vector2(0.0, _radii[i]), _names[i], _blob_alpha(i))
	for i in _exp_positions.size():
		_label(xf, scale, screen, _exp_positions[i] + Vector2(0.0, EXPEDITION_CELLS * cell_size),
				"en camino · %d %%" % int(_exp_progress[i] * 100.0), _alpha)
	_labels.draw_set_transform_matrix(Transform2D.IDENTITY)


func _label(xf: Transform2D, scale: float, screen: Rect2, anchor: Vector2, text: String,
		alpha: float) -> void:
	if alpha <= 0.0:
		return
	var size := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_SIZE)
	var top_center := xf * anchor
	var box := Rect2(top_center - Vector2(size.x * 0.5, 0.0), size + Vector2(0.0, 4.0))
	if not screen.encloses(box):
		return
	_labels.draw_set_transform(anchor, 0.0, Vector2.ONE / scale)
	var at := Vector2(-size.x * 0.5, _font.get_ascent(LABEL_SIZE) + 2.0)
	_labels.draw_string_outline(_font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_SIZE,
			LABEL_OUTLINE, Color(0.0, 0.0, 0.0, 0.8))
	_labels.draw_string(_font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_SIZE, Color.WHITE)


func _make_multimesh(texture: Texture2D) -> MultiMeshInstance2D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.mesh = SettlementView._make_quad()
	var inst := MultiMeshInstance2D.new()
	inst.multimesh = mm
	inst.texture = texture
	# Lineal, al revés que el pixelart: la mancha es un disco y a ×0,35 tiene que verse redondo.
	inst.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	return inst


## Un disco blanco con el borde oscuro y el canto suavizado. Blanco para que el color de cada
## instancia lo tiña; el borde, más oscuro, para que la mancha se lea sobre cualquier terreno.
static func _disk_texture() -> Texture2D:
	const N := 64
	var image := Image.create_empty(N, N, false, Image.FORMAT_RGBA8)
	var c := (N - 1) * 0.5
	for y in N:
		for x in N:
			var r := Vector2(x - c, y - c).length() / (N * 0.5)
			var alpha := clampf((1.0 - r) * N * 0.5, 0.0, 1.0)
			var shade := 1.0 if r < 0.82 else 0.35
			image.set_pixel(x, y, Color(shade, shade, shade, alpha * 0.92))
	return ImageTexture.create_from_image(image)
