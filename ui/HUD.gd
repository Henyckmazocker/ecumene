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
## Mover gente a un oficio (`amount` negativo la saca).
signal workers_changed(building_index: int, amount: float)
signal delegation_toggled(delegated: bool)
signal promotion_requested()
signal upgrade_requested(id: String)

const IDLE_COLOR := Color(0.62, 0.62, 0.60)
const WARN_COLOR := Color(0.85, 0.35, 0.30)
const OK_COLOR := Color(0.65, 0.80, 0.62)

var _title: Label
var _pop_bar: PopulationBar
var _pop_label: Label
var _promotion_box: HBoxContainer
var _promotion_label: Label
var _promotion_button: Button
var _upgrade_panel: PanelContainer
var _upgrade_box: VBoxContainer
var _upgrade_buttons: Dictionary = {}
var _resource_rows: Dictionary = {}
var _resource_box: VBoxContainer
var _build_box: HBoxContainer
var _build_buttons: Dictionary = {}
var _job_box: VBoxContainer
var _job_rows: Dictionary = {}
var _idle_label: Label
var _step_buttons: Array[Button] = []
var _delegate_button: Button
var _speed_buttons: Array[Button] = []
## Cuánta gente mueve cada pulsación. Con miles de habitantes, ir de uno en uno es inviable.
var _step: int = 1
var _welcome: PanelContainer
var _welcome_body: Label
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

	# Franja central: el mundo se ve por debajo, y las mejoras se apoyan a la derecha para no
	# tapar el pueblo ni competir con la zona del pulgar.
	var middle := HBoxContainer.new()
	middle.size_flags_vertical = Control.SIZE_EXPAND_FILL
	middle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rows.add_child(middle)

	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	middle.add_child(gap)
	middle.add_child(_build_upgrades())

	rows.add_child(_build_bottom())
	_build_welcome()


## Pantalla de vuelta. Un panel modal, descartable de un toque.
##
## El catch-up ya funcionaba y era **invisible**: volvías y los números eran otros sin que
## nadie te contara nada. En un idle, lo que pasó mientras no estabas es la mitad del juego.
func _build_welcome() -> void:
	_welcome = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.08, 0.09, 0.97)
	style.set_border_width_all(2)
	style.border_color = Color(0.35, 0.45, 0.40)
	for corner in ["top_left", "top_right", "bottom_left", "bottom_right"]:
		style.set("corner_radius_" + corner, 10)
	for side in ["left", "top", "right", "bottom"]:
		style.set("content_margin_" + side, 24)
	_welcome.add_theme_stylebox_override("panel", style)
	_welcome.set_anchors_preset(Control.PRESET_CENTER)
	_welcome.visible = false
	add_child(_welcome)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	_welcome.add_child(box)

	var title := Label.new()
	title.text = "🌙 Mientras no estabas"
	title.add_theme_font_size_override("font_size", 22)
	box.add_child(title)

	_welcome_body = Label.new()
	_welcome_body.add_theme_font_size_override("font_size", 14)
	box.add_child(_welcome_body)

	var close := Button.new()
	close.text = "Continuar"
	close.custom_minimum_size = Vector2(0, 46)
	close.pressed.connect(func() -> void: _welcome.visible = false)
	box.add_child(close)


func show_offline(report: OfflineReport) -> void:
	if report == null or not report.has_anything_to_say():
		return
	_welcome_body.text = "\n".join(report.lines())
	_welcome.visible = true


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

	box.add_child(_build_promotion_row())
	return panel


## El eje vertical del juego, siempre a la vista.
##
## Mientras no se cumple el umbral enseña **cuánto falta**: en un incremental, saber a qué
## distancia está el próximo salto es la mitad del enganche. Cuando se cumple, se convierte en
## el botón más llamativo de la pantalla.
func _build_promotion_row() -> Control:
	_promotion_box = HBoxContainer.new()
	_promotion_box.add_theme_constant_override("separation", 12)

	_promotion_label = Label.new()
	_promotion_label.add_theme_font_size_override("font_size", 13)
	_promotion_box.add_child(_promotion_label)

	_promotion_button = Button.new()
	_promotion_button.custom_minimum_size = Vector2(0, 40)
	_promotion_button.pressed.connect(func() -> void: promotion_requested.emit())
	_promotion_box.add_child(_promotion_button)
	return _promotion_box


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

	var jobs_column := VBoxContainer.new()
	jobs_column.add_theme_constant_override("separation", 4)
	jobs_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(jobs_column)
	jobs_column.add_child(_build_jobs_header())

	_job_box = VBoxContainer.new()
	_job_box.add_theme_constant_override("separation", 2)
	jobs_column.add_child(_job_box)

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


## Panel de mejoras. Enseña las que **están a la vista** (escala y requisitos cumplidos),
## aunque todavía no se puedan pagar: saber qué viene después es la mitad del enganche.
func _build_upgrades() -> Control:
	_upgrade_panel = _panel()
	_upgrade_panel.size_flags_horizontal = Control.SIZE_SHRINK_END
	_upgrade_panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_upgrade_panel.custom_minimum_size = Vector2(300, 0)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	_upgrade_panel.add_child(box)

	var title := Label.new()
	title.text = "🔬 Mejoras"
	title.add_theme_font_size_override("font_size", 15)
	box.add_child(title)

	_upgrade_box = VBoxContainer.new()
	_upgrade_box.add_theme_constant_override("separation", 4)
	box.add_child(_upgrade_box)
	return _upgrade_panel


func _refresh_upgrades(node: SimNode) -> void:
	var available := Upgrading.available_for(node)
	_upgrade_panel.visible = not available.is_empty()

	var seen := {}
	for def in available:
		var d: Upgrades.Def = def
		seen[d.id] = true
		if not _upgrade_buttons.has(d.id):
			_upgrade_buttons[d.id] = _make_upgrade_button(d)
		var button: Button = _upgrade_buttons[d.id]
		button.visible = true
		button.disabled = node.is_delegated() or not Upgrading.can_afford(node, d.id)
		button.text = "%s %s\n%s" % [d.icon, d.name, _cost_of(d.cost)]
	for id in _upgrade_buttons:
		if not seen.has(id):
			(_upgrade_buttons[id] as Button).visible = false


func _make_upgrade_button(def: Upgrades.Def) -> Button:
	var button := Button.new()
	button.custom_minimum_size = Vector2(0, 46)
	button.tooltip_text = def.describe()
	button.pressed.connect(func() -> void: upgrade_requested.emit(def.id))
	_upgrade_box.add_child(button)
	return button


static func _cost_of(cost: PackedFloat64Array) -> String:
	var parts := PackedStringArray()
	for i in Goods.COUNT:
		if cost[i] > 0.0:
			parts.append("%.0f %s" % [cost[i], Goods.ICONS[i]])
	return " ".join(parts)


## Cabecera del reparto: cuánta gente está sin destinar, con qué paso se mueve, y quién manda.
func _build_jobs_header() -> Control:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 14)

	_idle_label = Label.new()
	_idle_label.add_theme_font_size_override("font_size", 14)
	_idle_label.custom_minimum_size = Vector2(150, 0)
	header.add_child(_idle_label)

	var step_label := Label.new()
	step_label.text = "paso"
	step_label.add_theme_font_size_override("font_size", 12)
	step_label.modulate = Color(1, 1, 1, 0.6)
	header.add_child(step_label)

	for amount in [1, 10, 100]:
		var button := Button.new()
		button.text = str(amount)
		button.custom_minimum_size = Vector2(46, 32)
		button.pressed.connect(_on_step.bind(amount))
		header.add_child(button)
		_step_buttons.append(button)

	_delegate_button = Button.new()
	_delegate_button.custom_minimum_size = Vector2(0, 32)
	_delegate_button.toggle_mode = true
	_delegate_button.toggled.connect(func(on: bool) -> void: delegation_toggled.emit(on))
	header.add_child(_delegate_button)
	return header


func _on_step(amount: int) -> void:
	_step = amount
	for i in _step_buttons.size():
		_step_buttons[i].disabled = _step_buttons[i].text == str(amount)


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
	_refresh_promotion(node, state)
	_refresh_upgrades(node)
	_refresh_jobs(node)
	_refresh_builds(node)
	for i in _speed_buttons.size():
		_speed_buttons[i].disabled = i == speed_index
	if _step_buttons.size() == 3 and not _step_buttons[0].disabled \
			and not _step_buttons[1].disabled and not _step_buttons[2].disabled:
		_on_step(_step)  # marcar el paso activo la primera vez


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


func _refresh_promotion(node: SimNode, state: WorldState) -> void:
	var tier_def := node.def()
	if tier_def.promote_pop <= 0.0:
		_promotion_box.visible = false
		return
	_promotion_box.visible = true

	var next_name := Content.tier(node.tier + 1).name
	var ready := Promotion.can_promote(state, node)
	_promotion_button.visible = ready
	if ready:
		_promotion_button.text = "⬆️  Ascender a %s" % next_name
		_promotion_label.text = Content.tier(node.tier + 1).unlocks
		_promotion_label.modulate = OK_COLOR
		return

	# Bloqueado por el techo de anidamiento: cumple el umbral pero su padre no da más de sí.
	if tier_def.can_promote(node.total_pop, node.building_total()):
		_promotion_label.text = "⛔ %s no puede pasar de %s estando bajo su capital" % [
			node.name, tier_def.name,
		]
		_promotion_label.modulate = WARN_COLOR
		return

	_promotion_label.text = "⬆️ %s: %s hab · %d/%d edificios" % [
		next_name,
		_progress(node.total_pop, tier_def.promote_pop),
		node.building_total(), tier_def.promote_buildings,
	]
	_promotion_label.modulate = Color(1, 1, 1, 0.75)


static func _progress(current: float, target: float) -> String:
	return "%s/%s" % [_short(current), _short(target)]


## Números grandes legibles: en un incremental se llega a millones enseguida.
static func _short(value: float) -> String:
	if value >= 1.0e9:
		return "%.2f G" % (value / 1.0e9)
	if value >= 1.0e6:
		return "%.2f M" % (value / 1.0e6)
	if value >= 10000.0:
		return "%.1f k" % (value / 1000.0)
	return "%.0f" % value


## Una fila por oficio con **botones de más y menos**. Es la decisión más frecuente del juego,
## así que vive en pantalla y no detrás de un menú.
##
## Antes era un deslizador de peso relativo, y era el control equivocado: un deslizador dice
## «más o menos por aquí» cuando lo que hay que decir es «seis personas a la granja». Con
## botones el número es exacto, se ve cuánta gente cabe, y queda claro que a nadie lo destinan
## por ti.
func _refresh_jobs(node: SimNode) -> void:
	var workers := Integrator.effective_workers(node)
	var idle := Integrator.idle_population(node)

	_idle_label.text = "👤 %.0f sin destinar" % idle
	_idle_label.modulate = IDLE_COLOR if idle < 1.0 else Color.WHITE

	if _delegate_button != null:
		var delegated := node.is_delegated()
		_delegate_button.set_pressed_no_signal(delegated)
		_delegate_button.text = "🎖️ Gobernador" if delegated else "🖐️ A mano"
		_delegate_button.tooltip_text = "Un gobernador reparte y construye por ti, al %d %% de rendimiento." % 85

	for bi in node.buildings.size():
		var is_job := node.buildings[bi] > 0 and Content.building(bi).is_workplace()
		if not _job_rows.has(bi):
			if not is_job:
				continue
			_job_rows[bi] = _make_job_row(bi)
		var row: HBoxContainer = _job_rows[bi]
		row.visible = is_job
		if not is_job:
			continue

		var capacity := Construction.capacity_of(node, bi)
		var count: Label = row.get_node("count")
		count.text = "%.0f / %.0f" % [workers[bi], capacity]
		count.modulate = OK_COLOR if workers[bi] >= capacity - 0.05 else Color.WHITE

		# Deshabilitar cuando la acción no haría nada: se ve de un vistazo si el tope es de
		# puestos construidos o de gente disponible.
		(row.get_node("minus") as Button).disabled = node.jobs[bi] <= 0.0 or node.is_delegated()
		(row.get_node("plus") as Button).disabled = node.is_delegated() \
			or node.jobs[bi] >= capacity - 0.001 or idle < 1.0


func _make_job_row(building_index: int) -> HBoxContainer:
	var def := Content.building(building_index)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var label := Label.new()
	label.text = "%s %s" % [def.icon, def.name]
	label.custom_minimum_size = Vector2(140, 0)
	label.add_theme_font_size_override("font_size", 13)
	row.add_child(label)

	row.add_child(_worker_button("minus", "−", building_index, -1.0))

	var count := Label.new()
	count.name = "count"
	count.custom_minimum_size = Vector2(76, 0)
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	count.add_theme_font_size_override("font_size", 13)
	row.add_child(count)

	row.add_child(_worker_button("plus", "+", building_index, 1.0))

	_job_box.add_child(row)
	return row


func _worker_button(node_name: String, text: String, building_index: int,
		direction: float) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = text
	button.custom_minimum_size = Vector2(44, 40)  # mínimo táctil de la guía de UX
	button.pressed.connect(func() -> void:
		workers_changed.emit(building_index, direction * float(_step)))
	return button


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
		# Delegado, construye el gobernador: los botones se apagan para que quede claro que
		# ya no mandas tú, en vez de que parezca que el juego compra a tus espaldas.
		b.disabled = node.is_delegated() or not Construction.can_build(node, bi)


static func _cost_text(node: SimNode, building_index: int) -> String:
	return _cost_of(Construction.cost_of(node, building_index))


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
