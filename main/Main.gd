extends Node

## Arranque y cableado: simulación ↔ vista ↔ UI.
##
## Aquí está la única frontera del juego. La vista y el HUD **leen** del estado y **mutan**
## llamando a `SimEngine` y a los sistemas — nunca escribiendo en `WorldState`.

const AUTOSAVE_CYCLES := 30.0
## Segundos de vida que se le dan al pueblo antes del primer fotograma, para que al enfocar un
## nodo la gente ya esté repartida por sus asuntos en vez de amontonada donde nació.
const WARM_UP_SECONDS := 12.0

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
	hud.workers_changed.connect(_on_workers_changed)
	hud.delegation_toggled.connect(_on_delegation_toggled)
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
	var hour := -1.0
	var delegate := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			shot = arg.substr(7)
		elif arg.begins_with("--shot-cycles="):
			cycles = float(arg.substr(14))
		elif arg.begins_with("--shot-hour="):
			hour = float(arg.substr(12))
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
	# La captura tiene que adelantar también el **reloj visual**: son dos simulaciones y la
	# hora del pueblo no depende del ciclo económico. `--shot-hour=13` fotografía el mediodía.
	if hour >= 0.0:
		view.set_hour(hour)
	view.warm_up(WARM_UP_SECONDS)
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
	# Un pueblo cargado de una partida no puede verse vacío llenándose a cuentagotas: se
	# puebla de golpe y se le dan unos segundos de vida para que nadie salga en la puerta.
	view.warm_up(WARM_UP_SECONDS)
	camera.frame(view.settlement_extent(), view.world_size(), _viewport_size())
	_refresh_hud()


func _viewport_size() -> Vector2:
	return Vector2(get_viewport().get_visible_rect().size)


func focused() -> SimNode:
	return engine.state.get_node_by_id(_focused_id) if engine.state != null else null


func _process(delta: float) -> void:
	if engine.state == null:
		return
	# **En tiempo real, no en ciclos.** El pueblo tiene su propio reloj: sigue vivo con la
	# pausa puesta y no se acelera al poner ×8. Aquí también converge la multitud hacia lo
	# que dicen los números, por segundos reales, no por ticks.
	view.advance(delta)


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


func _on_workers_changed(building_index: int, amount: float) -> void:
	var node := focused()
	if node == null or node.is_delegated():
		return
	Construction.add_workers(node, building_index, amount)
	view.refresh(node)
	_refresh_hud()


## Delegar y recuperar el mando. Sin esto no había forma de quitarle un nodo a un gobernador
## una vez puesto, y el juego se quedaba comprando y repartiendo solo para siempre.
func _on_delegation_toggled(delegated: bool) -> void:
	var node := focused()
	if node == null:
		return
	node.governor = Governor.balanced() if delegated else null
	engine.events.push("governor", engine.state.cycle, node.id,
		"%s pasa a manos de un gobernador" % node.name if delegated
		else "Retomas el mando de %s" % node.name, {"delegated": delegated})
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
