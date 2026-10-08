class_name UpgradeTreeView
extends Control

## Un árbol de progresión dibujado hacia abajo: filas por profundidad, conectores entre padre
## e hijo, y el estado de cada nodo a la vista.
##
## **No sabe de mejoras ni de legado.** Consume [Item], que es texto y un puñado de banderas, y
## emite [signal item_pressed]. Es lo único que permite que las dos pestañas —las mejoras del
## nodo y el árbol de legado, que no comparten ni catálogo ni moneda— se dibujen con este
## código y no con dos layouts que hay que mantener a la par.
##
## Los nodos son [Button] de verdad, no rectángulos pintados: la pulsación, el tooltip, el
## apagado y el foco de teclado salen gratis y se comportan como el resto del HUD. Lo único que
## se dibuja a mano son los conectores, que van en el [method _draw] de este control y por tanto
## **por debajo** de sus hijos.
##
## Los botones se reciclan por id en un diccionario y solo se les cambia el texto y la
## visibilidad — el mismo patrón que el resto de listas del HUD. Rehacer el subárbol en cada
## refresco perdería el foco y el estado de pulsación a cada ciclo.

signal item_pressed(id: String)

## En qué punto del árbol está un nodo. Lo traduce quien construye los [Item]; aquí solo se
## pinta.
enum State {
	OWNED,      ## comprado
	AVAILABLE,  ## a tiro: los requisitos están cumplidos
	LOCKED,     ## le falta algún requisito
}


## Un nodo del árbol. Todo texto ya formateado: este control no formatea nada.
class Item:
	extends RefCounted
	var id: String
	## Cabecera bajo la que se agrupa. Vacía, no se dibuja cabecera ninguna.
	var section: String = ""
	var icon: String = ""
	var label: String = ""
	## Segunda línea: el coste, o los rangos.
	var sublabel: String = ""
	var tooltip: String = ""
	## Ids de los que cuelga. Los que no estén en la lista se ignoran.
	var requires: PackedStringArray = PackedStringArray()
	var state: int = State.AVAILABLE
	## Se puede pulsar ahora mismo (hay con qué pagarlo y no manda un gobernador).
	var enabled: bool = false

	static func make(id: String, icon: String, label: String, sublabel: String,
			tooltip: String, requires: PackedStringArray, state: int, enabled: bool,
			section: String = "") -> Item:
		var it := Item.new()
		it.id = id
		it.icon = icon
		it.label = label
		it.sublabel = sublabel
		it.tooltip = tooltip
		it.requires = requires
		it.state = state
		it.enabled = enabled
		it.section = section
		return it


const SEP := 8.0
## Hueco entre filas. Es donde caben los conectores: más corto y el codo no se lee.
const ROW_GAP := 26.0
const SECTION_GAP := 12.0
const HEADER_H := 18.0
const NODE_MIN_W := 64.0
const NODE_MAX_W := 132.0
const NODE_H := 66.0
const FONT_SIZE := 11

const OWNED_COLOR := Color(0.65, 0.80, 0.62)   ## el mismo verde que `HUD.OK_COLOR`
const LINE_COLOR := Color(1, 1, 1, 0.5)
const LOCKED_LINE_COLOR := Color(1, 1, 1, 0.25)
const DASH := 5.0
const DASH_GAP := 4.0

var _items: Array = []
var _buttons: Dictionary = {}
var _headers: Array[Label] = []
## Las filas ya resueltas, tal y como las dejó [method set_items]. Colocar no vuelve a
## calcularlas: la forma del árbol depende del catálogo, no del ancho de la ventana.
var _layout_rows: Array = []
## Rectángulo resuelto de cada nodo, en coordenadas locales. Lo llena [method _relayout] y lo
## lee [method _draw]: sin esto, dibujar los conectores obligaría a preguntarle su sitio a cada
## botón, que es información que solo está bien un fotograma después.
var _rects: Dictionary = {}


func _ready() -> void:
	# El dock cambia de ancho al girar el móvil y al pasar de columna a hoja inferior. El árbol
	# se recoloca solo en vez de esperar a que alguien se acuerde de pedírselo.
	resized.connect(_relayout)


## Reemplaza el contenido del árbol.
##
## Es el único sitio donde se crean y se destruyen cosas. [method _relayout] solo coloca lo que
## ya existe: crear hijos desde un `resized` es meter un cambio de estructura dentro del propio
## cálculo del layout, y de ahí no salen más que sorpresas.
func set_items(items: Array) -> void:
	_items = items
	var seen := {}
	for item in _items:
		var it: Item = item
		seen[it.id] = true
		if not _buttons.has(it.id):
			_buttons[it.id] = _make_button(it.id)
		_dress(_buttons[it.id], it)
	for id in _buttons:
		if not seen.has(id):
			(_buttons[id] as Button).visible = false

	_layout_rows = _rows()
	var headers := 0
	for row in _layout_rows:
		if not String(row["section"]).is_empty():
			headers += 1
	while _headers.size() < headers:
		var label := Label.new()
		label.add_theme_font_size_override("font_size", 12)
		label.modulate = Color(1, 1, 1, 0.6)
		add_child(label)
		_headers.append(label)
	for i in _headers.size():
		_headers[i].visible = i < headers
	_relayout()


func _make_button(id: String) -> Button:
	var button := Button.new()
	# Ni un solo `add_theme_*_override`, y **un único `Theme` que no vuelve a cambiar nunca**: ver
	# la nota de [method _dress]. Se le pone antes de entrar en el árbol de escena, que es cuando
	# vestir a un control es gratis.
	button.theme = _flat_theme()
	# Recortar, no envolver: el nodo tiene un alto fijo y un nombre largo que se parte en tres
	# líneas empujaría el coste fuera del botón.
	button.clip_text = true
	button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	button.pressed.connect(func() -> void: item_pressed.emit(id))
	add_child(button)
	return button


## Deja el botón como pide el item.
##
## Todo lo que se escribe aquí es **barato**: texto, tooltip, apagado y tinte, y los cuatro salen
## antes si el valor no cambia. Lo caro está fuera del botón a propósito.
##
## El aspecto de un nodo solía ser un `Theme` por variante que se le asignaba al cambiar de
## estado, y eso costaba unos **6 ms por nodo**. No por el tema en sí: asignarlo invalida el
## control, invalidar obliga a reconformar su texto, y el texto lleva un emoji, así que hay que
## volver a resolver la fuente de reserva. El mismo botón sin emoji costaba 0,05 ms, y fuera del
## árbol de escena, 0,001. Con doce nodos cambiando a la vez —lo normal justo después de comprar
## algo— eran 77 ms clavados en un fotograma.
##
## Así que el fondo y el borde ya no viven en el tema del botón: los dibuja el propio árbol en
## [method _draw], que además es donde ya se dibujaban los conectores. Al botón solo le queda el
## texto, y el color de ese texto entra por `modulate`, que no invalida nada.
func _dress(button: Button, item: Item) -> void:
	button.visible = true
	var mark := "✓ " if item.state == State.OWNED else ""
	button.text = "%s%s\n%s\n%s" % [mark, item.icon, item.label, item.sublabel]
	button.tooltip_text = item.tooltip
	button.disabled = not item.enabled
	button.modulate = _text_color(item.state, item.enabled)


static func _variant_key(state: int, enabled: bool) -> int:
	return state * 2 + int(enabled)


## El color del texto de un nodo, que entra por `modulate` sobre una fuente blanca.
static func _text_color(state: int, enabled: bool) -> Color:
	match state:
		State.OWNED:
			return OWNED_COLOR
		State.AVAILABLE:
			return Color.WHITE if enabled else Color(1, 1, 1, 0.55)
	return Color(1, 1, 1, 0.45)


## El tema que llevan todos los botones del árbol, para siempre.
##
## Transparente: el fondo lo pone [method _draw]. Lo único que sigue aquí es lo que el botón
## necesita saber de sí mismo —el tamaño de letra, los márgenes que separan el texto del borde
## dibujado, y la reacción al ratón—. Como es el mismo objeto para todos, se asigna una vez por
## botón y nunca se vuelve a tocar.
##
## La reacción al ratón se queda en el tema porque **no depende del estado**: un nodo que no se
## puede comprar está `disabled`, y Godot no le aplica ni `hover` ni `pressed`. Sale solo lo que
## antes había que codificar en seis variantes.
static var _flat: Theme = null


static func _flat_theme() -> Theme:
	if _flat != null:
		return _flat
	_flat = Theme.new()
	_flat.set_font_size("font_size", "Button", FONT_SIZE)
	var empty := StyleBoxEmpty.new()
	for side in ["left", "top", "right", "bottom"]:
		empty.set("content_margin_" + side, 4)
	for state_name in ["normal", "disabled", "focus"]:
		_flat.set_stylebox(state_name, "Button", empty)
	_flat.set_stylebox("hover", "Button", _overlay(Color(1, 1, 1, 0.07)))
	_flat.set_stylebox("pressed", "Button", _overlay(Color(0, 0, 0, 0.18)))
	# Blanco en los cinco: quien tiñe es el `modulate` de cada botón.
	for color_name in ["font_color", "font_disabled_color", "font_hover_color",
			"font_pressed_color", "font_focus_color"]:
		_flat.set_color(color_name, "Button", Color.WHITE)
	return _flat


## Los seis fondos, uno por par (estado, pulsable). Se construyen una vez y los comparten todos
## los árboles: [method _draw] solo los estampa.
##
## Lo comprado y lo bloqueado están los dos apagados —ninguno se puede pulsar— y por motivos
## opuestos, así que no pueden verse igual. Y se pintan a mano en vez de dejarlo en el tema por
## omisión porque en un árbol la mayoría de los nodos está siempre deshabilitada: con el estilo
## `disabled` de serie para todos, el árbol entero se lee como texto suelto sobre el panel y deja
## de haber nodos que mirar.
static var _styles: Array[StyleBoxFlat] = []


static func _node_background(state: int, enabled: bool) -> StyleBoxFlat:
	if _styles.is_empty():
		_styles.resize(6)
		for s in [State.OWNED, State.AVAILABLE, State.LOCKED]:
			for e in [false, true]:
				_styles[_variant_key(s, e)] = _build_background(s, e)
	return _styles[_variant_key(state, enabled)]


static func _build_background(state: int, enabled: bool) -> StyleBoxFlat:
	var bg := Color(0.11, 0.13, 0.13)
	var border := Color(1, 1, 1, 0.12)
	match state:
		State.OWNED:
			bg = Color(0.11, 0.17, 0.14)
			border = OWNED_COLOR
		State.AVAILABLE:
			bg = Color(0.13, 0.17, 0.17)
			border = Color(0.45, 0.58, 0.54) if enabled else Color(1, 1, 1, 0.18)
	return _node_style(bg, border)


static func _node_style(bg: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.set_border_width_all(1)
	style.border_color = border
	for corner in ["top_left", "top_right", "bottom_left", "bottom_right"]:
		style.set("corner_radius_" + corner, 6)
	return style


## El realce del ratón, que se estampa **encima** del fondo que dibuja el árbol. Por eso es un
## velo translúcido y no un color opaco: el fondo que hay debajo depende del estado y este no.
static func _overlay(tint: Color) -> StyleBoxFlat:
	var style := _node_style(tint, Color(0, 0, 0, 0))
	style.set_border_width_all(0)
	for side in ["left", "top", "right", "bottom"]:
		style.set("content_margin_" + side, 4)
	return style


# ---------------------------------------------------------------------------
# Colocación
# ---------------------------------------------------------------------------

## Profundidad de cada id: 0 si no cuelga de nadie, 1 + la mayor de sus requisitos si cuelga.
##
## Los requisitos que no estén en la lista se ignoran, así que un nodo cuyo padre se ha quedado
## fuera —otra escala, otro catálogo— cae arriba del todo en vez de desaparecer. Función pura:
## es lo que hace comprobable la forma del árbol sin abrir una ventana.
static func depths(items: Array) -> Dictionary:
	var by_id := {}
	for item in items:
		by_id[(item as Item).id] = item
	var memo := {}
	for item in items:
		_depth_of((item as Item).id, by_id, memo, {})
	return memo


static func _depth_of(id: String, by_id: Dictionary, memo: Dictionary,
		visiting: Dictionary) -> int:
	if memo.has(id):
		return int(memo[id])
	# Guardia de ciclo: un catálogo con una dependencia circular es un error de datos, pero
	# colgar el juego al dibujarlo sería peor que colocar el nodo arriba.
	if visiting.has(id) or not by_id.has(id):
		return 0
	visiting[id] = true
	var depth := 0
	for required in (by_id[id] as Item).requires:
		if by_id.has(required):
			depth = maxi(depth, _depth_of(required, by_id, memo, visiting) + 1)
	visiting.erase(id)
	memo[id] = depth
	return depth


## Filas del árbol: una por cada par (sección, profundidad) que exista, en orden de aparición de
## la sección y de profundidad creciente dentro de ella.
##
## Dentro de una fila, **cada hijo se coloca bajo su padre**: es lo que evita que los conectores
## se crucen. Sin esto, el orden lo daba el catálogo y bastaba con declarar dos ramas
## intercaladas —que es justo lo que hace `data/Upgrades.gd`— para que las líneas se cruzaran y
## el árbol dejara de leerse. Quien escribe el catálogo no tendría por qué saberlo.
func _rows() -> Array:
	var depth := depths(_items)
	var order := []
	var by_key := {}
	for item in _items:
		var it: Item = item
		var key := "%s|%d" % [it.section, int(depth.get(it.id, 0))]
		if not by_key.has(key):
			by_key[key] = []
			order.append({"section": it.section, "depth": int(depth.get(it.id, 0)), "key": key})
		(by_key[key] as Array).append(it)
	# Estable y por secciones: `sort_custom` con un comparador que solo mira la profundidad
	# conserva el orden de aparición de las secciones.
	var sections := []
	for row in order:
		if not sections.has(row["section"]):
			sections.append(row["section"])
	order.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var sa: int = sections.find(a["section"])
		var sb: int = sections.find(b["section"])
		if sa != sb:
			return sa < sb
		return int(a["depth"]) < int(b["depth"]))

	var column_of := {}
	var out := []
	for row in order:
		out.append({"section": row["section"], "items": _aligned(by_key[row["key"]], column_of)})
	return out


## Ordena una fila poniendo a cada hijo en la columna de su padre, y apunta en `column_of` dónde
## ha quedado cada uno para que la fila siguiente pueda alinearse contra esta.
##
## Se recorre de arriba abajo, así que cuando toca una fila sus padres ya tienen columna. Quien
## no tiene padre —o lo tiene fuera de la lista— conserva su sitio en el catálogo.
static func _aligned(items: Array, column_of: Dictionary) -> Array:
	var keyed := []
	for i in items.size():
		var it: Item = items[i]
		var total := 0.0
		var parents := 0
		for required in it.requires:
			if column_of.has(required):
				total += float(column_of[required])
				parents += 1
		keyed.append({
			"key": total / float(parents) if parents > 0 else float(i),
			"index": i,
			"item": it,
		})
	keyed.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if not is_equal_approx(float(a["key"]), float(b["key"])):
			return float(a["key"]) < float(b["key"])
		return int(a["index"]) < int(b["index"]))
	var out := []
	for entry in keyed:
		column_of[(entry["item"] as Item).id] = out.size()
		out.append(entry["item"])
	return out


## Coloca los botones y calcula el alto que hace falta.
##
## El ancho del nodo **se adapta al hueco**, no al revés: el dock va de 320 a 480 px y el
## `ScrollContainer` que envuelve esto tiene el scroll horizontal desactivado a propósito, así
## que un ancho fijo se recortaría en cuanto la fila más ancha no cupiese.
func _relayout() -> void:
	_rects.clear()
	if size.x <= 0.0 or _layout_rows.is_empty():
		queue_redraw()
		return

	var columns := 1
	for row in _layout_rows:
		columns = maxi(columns, (row["items"] as Array).size())
	var node_w := clampf((size.x - SEP * float(columns - 1)) / float(columns),
		NODE_MIN_W, NODE_MAX_W)

	var header_index := 0
	var section := ""
	var first := true
	var y := 0.0
	for row in _layout_rows:
		if String(row["section"]) != section:
			section = String(row["section"])
			if not first:
				y += SECTION_GAP
			if not section.is_empty() and header_index < _headers.size():
				var header := _headers[header_index]
				header.position = Vector2(0.0, y)
				header.size = Vector2(size.x, HEADER_H)
				header.text = section
				header_index += 1
				y += HEADER_H + 4.0
		first = false

		var items: Array = row["items"]
		var total := node_w * float(items.size()) + SEP * float(items.size() - 1)
		var x := (size.x - total) * 0.5
		for item in items:
			var it: Item = item
			var rect := Rect2(x, y, node_w, NODE_H)
			var button: Button = _buttons[it.id]
			button.position = rect.position
			button.size = rect.size
			_rects[it.id] = rect
			x += node_w + SEP
		y += NODE_H + ROW_GAP

	# Sin el hueco entre filas de la última: debajo del árbol no hay nada que conectar.
	var height := maxf(y - ROW_GAP, 0.0)
	# Solo si de verdad ha cambiado: tocar el mínimo hace que el contenedor recalcule, y
	# recalcular vuelve por `resized`. Escribirlo con el mismo valor sería morderse la cola.
	if not is_equal_approx(custom_minimum_size.y, height):
		custom_minimum_size.y = height
	queue_redraw()


# ---------------------------------------------------------------------------
# Conectores
# ---------------------------------------------------------------------------

## El fondo de cada nodo y las líneas entre padre e hijo.
##
## Los conectores van en codo de tres tramos: baja del padre, cruza a la vertical del hijo y baja
## hasta él. En diagonal se cruzarían entre ellas en cuanto una fila tiene tres nodos, y el árbol
## dejaría de leerse. El color y el trazo los manda **el hijo**: la línea cuenta si ese camino ya
## está andado (continua y verde), abierto (continua) o todavía cerrado (punteada y apagada).
##
## Los fondos también se dibujan aquí, y no en el tema de cada botón, porque cambiarle el tema a
## un control que está en el árbol de escena cuesta milisegundos (ver [method _dress]). Esto es
## un `draw_style_box` por nodo sobre un control que ya se estaba dibujando de todas formas, y
## cae **por debajo** de los hijos, que es justo donde tiene que estar el fondo de un botón.
func _draw() -> void:
	for item in _items:
		var it: Item = item
		if _rects.has(it.id):
			draw_style_box(_node_background(it.state, it.enabled), _rects[it.id])

	for item in _items:
		var it: Item = item
		if not _rects.has(it.id):
			continue
		var child: Rect2 = _rects[it.id]
		for required in it.requires:
			if not _rects.has(required):
				continue
			var parent: Rect2 = _rects[required]
			var from := Vector2(parent.position.x + parent.size.x * 0.5, parent.end.y)
			var to := Vector2(child.position.x + child.size.x * 0.5, child.position.y)
			var mid := (from.y + to.y) * 0.5
			var color := LINE_COLOR
			if it.state == State.OWNED:
				color = OWNED_COLOR
			elif it.state == State.LOCKED:
				color = LOCKED_LINE_COLOR
			var dashed := it.state == State.LOCKED
			_segment(from, Vector2(from.x, mid), color, dashed)
			_segment(Vector2(from.x, mid), Vector2(to.x, mid), color, dashed)
			_segment(Vector2(to.x, mid), to, color, dashed)


func _segment(from: Vector2, to: Vector2, color: Color, dashed: bool) -> void:
	if not dashed:
		draw_line(from, to, color, 2.0)
		return
	# A mano: `CanvasItem` no dibuja líneas discontinuas.
	var length := from.distance_to(to)
	if length <= 0.0:
		return
	var step := DASH + DASH_GAP
	var direction := (to - from) / length
	var travelled := 0.0
	while travelled < length:
		var end := minf(travelled + DASH, length)
		draw_line(from + direction * travelled, from + direction * end, color, 2.0)
		travelled += step
