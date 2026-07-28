extends Node

## Arranque del juego. En M0 la vista es un panel de texto: el objetivo de este hito es que
## el núcleo determinista corra, se guarde y acredite el tiempo offline. El terreno 2D, los
## agentes y la cámara de zoom continuo llegan en M1–M3.

const AUTOSAVE_CYCLES := 30.0

var engine: SimEngine
var _label: Label
var _next_autosave: float = AUTOSAVE_CYCLES


func _ready() -> void:
	engine = SimEngine.new()
	engine.name = "SimEngine"
	add_child(engine)

	_build_ui()
	# Conectar antes de arrancar: si no, el evento de fundación de la partida se pierde.
	engine.cycle_advanced.connect(_on_cycle_advanced)
	engine.events.event_pushed.connect(_on_event)
	_load_or_start()


func _load_or_start() -> void:
	var elapsed := []
	var state := Save.read(elapsed)
	if state != null:
		engine.adopt(state)
		var away: float = elapsed[0] if not elapsed.is_empty() else 0.0
		if away > 0.0:
			var cycles := engine.catch_up(away)
			print("Ecumene: %0.f ciclos acreditados por %0.f s fuera." % [cycles, away])
	else:
		engine.start(int(Time.get_unix_time_from_system()))


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED:
		# Móvil y web pueden matar el proceso sin aviso: guardar al perder el foco es lo
		# único que garantiza que el tiempo offline se cuente desde el instante correcto.
		if engine != null and engine.state != null:
			Save.write(engine.state)


func _on_cycle_advanced(cycle: float) -> void:
	_refresh()
	if cycle >= _next_autosave:
		_next_autosave = cycle + AUTOSAVE_CYCLES
		Save.write(engine.state)


func _on_event(entry: Dictionary) -> void:
	print("[%6.0f] %s" % [entry["cycle"], entry["text"]])


# ---------------------------------------------------------------------------
# UI provisional
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	var root := MarginContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "top", "right", "bottom"]:
		root.add_theme_constant_override("margin_" + side, 24)
	layer.add_child(root)

	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 16)
	root.add_child(_label)


func _refresh() -> void:
	if engine.state == null:
		return
	var node := engine.state.root()
	var lines := PackedStringArray()
	lines.append("%s — %s (era %d)" % [node.name, node.def().name, engine.state.era])
	lines.append("Ciclo %0.f · población %0.1f (subárbol %0.1f) · techo %0.f" % [
		engine.state.cycle, node.pop, node.total_pop, node.housing(engine.params),
	])
	var caps := node.storage_caps(engine.params)
	for i in Goods.COUNT:
		if node.stocks[i] <= 0.0 and caps[i] == engine.params.base_storage:
			continue
		lines.append("  %s %s %0.1f / %s" % [
			Goods.ICONS[i], Goods.NAMES[i], node.stocks[i],
			"∞" if caps[i] == INF else "%0.f" % caps[i],
		])
	if node.starving:
		lines.append("  ⚠️ HAMBRUNA")
	_label.text = "\n".join(lines)
