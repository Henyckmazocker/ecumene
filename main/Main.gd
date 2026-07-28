extends Node

## Arranque y cableado: simulación ↔ vista ↔ UI.
##
## Aquí está la única frontera del juego. La vista y el HUD **leen** del estado y **mutan**
## llamando a `SimEngine` y a los sistemas — nunca escribiendo en `WorldState`.

const AUTOSAVE_CYCLES := 30.0

var engine: SimEngine
var view: SettlementView
var camera: SettlementCamera
var hud: HUD

var _next_autosave: float = AUTOSAVE_CYCLES
var _focused_id: int = -1


func _ready() -> void:
	engine = SimEngine.new()
	engine.name = "SimEngine"
	add_child(engine)

	view = SettlementView.new()
	view.name = "SettlementView"
	add_child(view)

	camera = SettlementCamera.new()
	camera.name = "Camera"
	camera.enabled = true
	add_child(camera)

	hud = HUD.new()
	hud.name = "HUD"
	add_child(hud)

	hud.build_requested.connect(_on_build)
	hud.speed_requested.connect(_on_speed)
	hud.job_changed.connect(_on_job_changed)
	# Conectar antes de arrancar: si no, el evento de fundación de la partida se pierde.
	engine.cycle_advanced.connect(_on_cycle_advanced)
	engine.events.event_pushed.connect(_on_event)

	_load_or_start()
	_focus(engine.state.root())
	get_viewport().size_changed.connect(_on_viewport_resized)
	_maybe_capture()


## Modo de captura para verificar el apartado visual sin un humano delante:
##   godot-4 --path . -- --shot=user://shot.png --shot-cycles=400
## Adelanta la simulación los ciclos pedidos, guarda una imagen del viewport y sale.
func _maybe_capture() -> void:
	var shot := ""
	var cycles := 0.0
	var delegate := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			shot = arg.substr(7)
		elif arg.begins_with("--shot-cycles="):
			cycles = float(arg.substr(14))
		elif arg == "--shot-governor":
			delegate = true
	if shot.is_empty():
		return
	if delegate:
		# Para ver un asentamiento hecho sin jugarlo a mano.
		engine.state.root().governor = Governor.balanced()
	if cycles > 0.0:
		# En pasos, no de un salto: con un solo tick gigante el gobernador construiría todo
		# al final y la captura no enseñaría un asentamiento, sino un solar recién edificado.
		var step := 25.0
		for _i in int(ceil(cycles / step)):
			engine.tick(step)
		_focus(engine.state.root())
		view.refresh(focused())
		_refresh_hud()
	view.update_agents(engine.state.cycle)
	# Dos fotogramas: uno para que los `Control` calculen su tamaño y otro para dibujarlos.
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(shot)
	print("captura guardada en %s" % ProjectSettings.globalize_path(shot))
	get_tree().quit()


func _load_or_start() -> void:
	var elapsed := []
	var state := Save.read(elapsed)
	if state != null:
		engine.adopt(state)
		var away: float = elapsed[0] if not elapsed.is_empty() else 0.0
		if away > 0.0:
			engine.catch_up(away)
	else:
		engine.start(int(Time.get_unix_time_from_system()))


func _focus(node: SimNode) -> void:
	if node == null:
		return
	_focused_id = node.id
	view.show_node(node)
	camera.frame(view.settlement_extent(), view.world_size(), _viewport_size())
	_refresh_hud()


func _viewport_size() -> Vector2:
	return Vector2(get_viewport().get_visible_rect().size)


func focused() -> SimNode:
	return engine.state.get_node_by_id(_focused_id) if engine.state != null else null


func _process(_delta: float) -> void:
	if engine.state == null:
		return
	# Los agentes son función pura del ciclo de simulación, no del tiempo real: con la pausa
	# puesta se quedan quietos solos, sin que haya que acordarse de pararlos.
	view.update_agents(engine.state.cycle)


func _on_viewport_resized() -> void:
	camera.frame(view.settlement_extent(), view.world_size(), _viewport_size())


func _on_cycle_advanced(cycle: float) -> void:
	var node := focused()
	if node == null:
		# El nodo enfocado ha desaparecido (colapso): volver a la raíz.
		_focus(engine.state.root())
		return
	view.refresh(node)
	# El pueblo crece: se reencuadra, salvo que el jugador esté mirando algo a su aire.
	camera.reframe_if_untouched(view.settlement_extent(), view.world_size(), _viewport_size())
	_refresh_hud()
	if cycle >= _next_autosave:
		_next_autosave = cycle + AUTOSAVE_CYCLES
		Save.write(engine.state)


func _refresh_hud() -> void:
	var node := focused()
	if node == null:
		return
	var snap := Integrator.snapshot(node, engine.params, engine.current_modifiers())
	hud.refresh(node, engine.state, engine.params, snap, engine.speed_index,
		view.agent_count(), view.represents())


func _on_event(entry: Dictionary) -> void:
	hud.push_event(String(entry["text"]))


# ---------------------------------------------------------------------------
# Acciones del jugador — todas por las mismas funciones que usa el gobernador
# ---------------------------------------------------------------------------

func _on_build(building_index: int) -> void:
	var node := focused()
	if node == null:
		return
	if Construction.build(node, building_index, engine.state.cycle, engine.events):
		view.refresh(node)
		_refresh_hud()


func _on_job_changed(building_index: int, weight: float) -> void:
	var node := focused()
	if node == null:
		return
	Construction.set_job_weight(node, building_index, weight)
	view.refresh(node)
	_refresh_hud()


func _on_speed(index: int) -> void:
	engine.set_speed_index(index)
	_refresh_hud()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED:
		# Móvil y web pueden matar el proceso sin aviso: guardar al perder el foco es lo
		# único que garantiza que el tiempo offline se cuente desde el instante correcto.
		if engine != null and engine.state != null:
			Save.write(engine.state)
