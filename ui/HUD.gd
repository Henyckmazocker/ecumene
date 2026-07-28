class_name HUD
extends CanvasLayer

## HUD del asentamiento. Construido por código: un panel de estos es trivial de mantener así
## y no arrastra un `.tscn` enorme que hay que abrir en el editor para cambiar un margen
## (la misma decisión que en Worlding).
##
## Dos reglas de la guía de UX que se aplican aquí desde el primer hito, porque meterlas
## después significaría rehacer el layout:
##
##   1. **La tasa por ciclo va siempre pegada al stock.** En un incremental el número que el
##      jugador lee de verdad es la derivada, no el stock.
##   2. **Lo accionable, en el tercio inferior.** Es lo que hace que el mismo layout funcione
##      con un pulgar y con un ratón, sin dos diseños.

signal build_requested(building_index: int)
signal speed_requested(index: int)
signal job_changed(building_index: int, weight: float)

const IDLE_COLOR := Color(0.62, 0.62, 0.60)
const WARN_COLOR := Color(0.85, 0.35, 0.30)
const OK_COLOR := Color(0.65, 0.80, 0.62)

var _title: Label
var _pop_bar: PopulationBar
var _pop_label: Label
var _resource_rows: Dictionary = {}
var _resource_box: VBoxContainer
var _build_box: HBoxContainer
var _build_buttons: Dictionary = {}
var _job_box: VBoxContainer
var _job_sliders: Dictionary = {}
var _speed_buttons: Array[Button] = []
var _feed: Label
var _feed_lines: PackedStringArray = PackedStringArray()


func _ready() -> void:
	var root := MarginContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "top", "right", "bottom"]:
		root.add_theme_constant_override("margin_" + side, 16)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 8)
	rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(rows)

	rows.add_child(_build_top())
	var middle := Control.new()
	middle.size_flags_vertical = Control.SIZE_EXPAND_FILL
	middle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rows.add_child(middle)
	rows.add_child(_build_bottom())


# ---------------------------------------------------------------------------
# Construcción del layout
# ---------------------------------------------------------------------------

func _build_top() -> Control:
	var panel := _panel()
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 20)
	box.add_child(_title)

	_pop_bar = PopulationBar.new()
	_pop_bar.custom_minimum_size = Vector2(0, 18)
	box.add_child(_pop_bar)

	_pop_label = Label.new()
	_pop_label.add_theme_font_size_override("font_size", 13)
	box.add_child(_pop_label)

	_resource_box = VBoxContainer.new()
	_resource_box.add_theme_constant_override("separation", 2)
	box.add_child(_resource_box)
	return panel


func _build_bottom() -> Control:
	var panel := _panel()
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)

	_feed = Label.new()
	_feed.add_theme_font_size_override("font_size", 12)
	_feed.modulate = Color(1, 1, 1, 0.6)
	box.add_child(_feed)

	# Oficios y velocidad en la misma fila: el panel inferior se comía media pantalla, y en
	# móvil vertical eso es directamente inviable.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 24)
	box.add_child(row)

	_job_box = VBoxContainer.new()
	_job_box.add_theme_constant_override("separation", 2)
	_job_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_job_box)

	var speeds := HBoxContainer.new()
	speeds.add_theme_constant_override("separation", 6)
	speeds.alignment = BoxContainer.ALIGNMENT_END
	speeds.size_flags_vertical = Control.SIZE_SHRINK_END
	for i in ["⏸", "▶", "▶▶", "▶▶▶", "▶▶▶▶"]:
		var b := Button.new()
		b.text = i
		b.custom_minimum_size = Vector2(52, 44)  # el mínimo táctil de la guía de UX
		b.pressed.connect(_on_speed.bind(_speed_buttons.size()))
		speeds.add_child(b)
		_speed_buttons.append(b)
	row.add_child(speeds)

	_build_box = HBoxContainer.new()
	_build_box.add_theme_constant_override("separation", 6)
	box.add_child(_build_box)
	return panel


func _panel() -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.09, 0.09, 0.82)
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8
	for side in ["left", "top", "right", "bottom"]:
		style.set("content_margin_" + side, 12)
	panel.add_theme_stylebox_override("panel", style)
	# A ancho completo: en móvil vertical una barra encogida al contenido queda descolgada, y
	# en escritorio da la impresión de un menú flotante en vez de un HUD.
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return panel


# ---------------------------------------------------------------------------
# Refresco
# ---------------------------------------------------------------------------

func refresh(node: SimNode, state: WorldState, params: SimParams, snap: Integrator.Snapshot,
		speed_index: int, crowd_size: int, represents: float) -> void:
	_title.text = "%s — %s · era %d · ciclo %d" % [
		node.name, node.def().name, state.era, int(state.cycle),
	]

	_pop_bar.pop = node.pop
	_pop_bar.housing = snap.housing
	_pop_bar.food_capacity = snap.food_capacity
	_pop_bar.queue_redraw()

	var limit := "alojamiento" if not snap.food_limited else "comida"
	var crowd_note := ""
	if crowd_size > 0 and represents > 1.01:
		crowd_note = " · %d puntos × %.1f hab" % [crowd_size, represents]
	_pop_label.text = "👥 %.1f de %.1f — limitado por %s%s" % [
		node.pop, snap.cap, limit, crowd_note,
	]
	_pop_label.modulate = WARN_COLOR if snap.starving else Color.WHITE

	_refresh_resources(node, params, snap)
	_refresh_jobs(node)
	_refresh_builds(node)
	for i in _speed_buttons.size():
		_speed_buttons[i].disabled = i == speed_index


func _refresh_resources(node: SimNode, params: SimParams, snap: Integrator.Snapshot) -> void:
	var caps := node.storage_caps(params)
	var visible := Content.goods_for_tier(node.tier)
	for i in Goods.COUNT:
		var show := visible.has(i) or node.stocks[i] > 0.0
		if not _resource_rows.has(i):
			if not show:
				continue
			var label := Label.new()
			label.add_theme_font_size_override("font_size", 14)
			_resource_box.add_child(label)
			_resource_rows[i] = label
		var row: Label = _resource_rows[i]
		row.visible = show
		if not show:
			continue
		var cap_text := "∞" if caps[i] == INF else "%.0f" % caps[i]
		var rate := snap.rates[i]
		row.text = "%s %s %.1f / %s   %+.2f/ciclo" % [
			Goods.ICONS[i], Goods.NAMES[i], node.stocks[i], cap_text, rate,
		]
		row.modulate = Color.WHITE if rate >= 0.0 else WARN_COLOR


## Un deslizador por oficio. Es la decisión más frecuente del juego, así que vive en pantalla
## y no detrás de un menú.
func _refresh_jobs(node: SimNode) -> void:
	for bi in node.buildings.size():
		var is_job := node.buildings[bi] > 0 and Content.building(bi).is_workplace()
		if not _job_sliders.has(bi):
			if not is_job:
				continue
			_job_sliders[bi] = _make_job_row(bi)
		var row: HBoxContainer = _job_sliders[bi]
		row.visible = is_job
		if not is_job:
			continue
		var slider: HSlider = row.get_child(1)
		if not slider.has_focus():
			slider.set_value_no_signal(node.jobs[bi])
		var workers := Integrator.effective_workers(node)[bi]
		var capacity := Content.building(bi).worker_slots * float(node.buildings[bi])
		var count: Label = row.get_child(2)
		count.text = "%.1f/%.0f" % [workers, capacity]
		count.modulate = OK_COLOR if workers >= capacity - 0.05 else Color.WHITE


func _make_job_row(building_index: int) -> HBoxContainer:
	var def := Content.building(building_index)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var label := Label.new()
	label.text = "%s %s" % [def.icon, def.name]
	label.custom_minimum_size = Vector2(140, 0)
	label.add_theme_font_size_override("font_size", 13)
	row.add_child(label)

	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 3.0
	slider.step = 0.1
	slider.custom_minimum_size = Vector2(180, 44)
	slider.value_changed.connect(func(v: float) -> void: job_changed.emit(building_index, v))
	row.add_child(slider)

	var count := Label.new()
	count.custom_minimum_size = Vector2(70, 0)
	count.add_theme_font_size_override("font_size", 13)
	row.add_child(count)

	_job_box.add_child(row)
	return row


func _refresh_builds(node: SimNode) -> void:
	for bi in Content.buildings_for_tier(node.tier):
		if not _build_buttons.has(bi):
			var button := Button.new()
			button.custom_minimum_size = Vector2(0, 44)
			button.pressed.connect(func() -> void: build_requested.emit(bi))
			_build_box.add_child(button)
			_build_buttons[bi] = button
		var b: Button = _build_buttons[bi]
		var def := Content.building(bi)
		b.text = "%s %s ×%d\n%s" % [
			def.icon, def.name, node.buildings[bi], _cost_text(node, bi),
		]
		b.disabled = not Construction.can_build(node, bi)


static func _cost_text(node: SimNode, building_index: int) -> String:
	var cost := Construction.cost_of(node, building_index)
	var parts := PackedStringArray()
	for i in Goods.COUNT:
		if cost[i] > 0.0:
			parts.append("%.0f %s" % [cost[i], Goods.ICONS[i]])
	return " ".join(parts)


func push_event(text: String) -> void:
	# Agrupar repeticiones: «construye Cabaña» ×6 seguidas no aporta seis líneas de nada.
	if not _feed_lines.is_empty():
		var last := _feed_lines[_feed_lines.size() - 1]
		if last == text or last.begins_with(text + " ×"):
			var count := 2 if last == text else int(last.get_slice(" ×", 1)) + 1
			_feed_lines[_feed_lines.size() - 1] = "%s ×%d" % [text, count]
			_feed.text = "\n".join(_feed_lines)
			return
	_feed_lines.append(text)
	if _feed_lines.size() > 2:
		_feed_lines = _feed_lines.slice(_feed_lines.size() - 2)
	_feed.text = "\n".join(_feed_lines)


func _on_speed(index: int) -> void:
	speed_requested.emit(index)


# ---------------------------------------------------------------------------

## Barra de población con **dos marcas**: alojamiento y capacidad alimentaria.
##
## Es la pieza de UI que hace legible la mecánica central. Un jugador que ve la población
## parada y una sola barra llena no sabe qué hacer; viendo cuál de las dos marcas está por
## debajo, sabe si le faltan casas o le falta campo.
class PopulationBar:
	extends Control

	var pop: float = 0.0
	var housing: float = 0.0
	var food_capacity: float = 0.0

	func _draw() -> void:
		var w := size.x
		var h := size.y
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.14, 0.16, 0.16))

		var scale_max := maxf(housing, 1.0)
		if food_capacity != INF:
			scale_max = maxf(scale_max, food_capacity)
		scale_max = maxf(scale_max, pop) * 1.05

		var limited_by_food := food_capacity < housing
		var fill := Color(0.45, 0.66, 0.48) if not limited_by_food else Color(0.72, 0.62, 0.32)
		draw_rect(Rect2(Vector2.ZERO, Vector2(w * pop / scale_max, h)), fill)

		_mark(housing / scale_max * w, h, Color(0.72, 0.78, 0.86), "🏠")
		if food_capacity != INF:
			_mark(food_capacity / scale_max * w, h, Color(0.88, 0.76, 0.34), "🌾")

	func _mark(x: float, h: float, color: Color, _label: String) -> void:
		draw_line(Vector2(x, 0), Vector2(x, h), color, 2.0)
