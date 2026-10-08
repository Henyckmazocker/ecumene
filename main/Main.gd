extends Node

## Arranque y cableado: simulación ↔ vista ↔ UI.
##
## Aquí está la única frontera del juego. La vista y el HUD **leen** del estado y **mutan**
## llamando a `SimEngine` y a los sistemas — nunca escribiendo en `WorldState`.

const AUTOSAVE_CYCLES := 30.0
## Segundos de vida que se le dan al pueblo antes del primer fotograma, para que al enfocar un
## nodo la gente ya esté repartida por sus asuntos en vez de amontonada donde nació.
const WARM_UP_SECONDS := 12.0
## Milisegundos por fotograma que se dedican a acreditar la ausencia. El resto del fotograma
## queda para dibujar: la barra tiene que moverse, no congelarse con otra cara.
const CATCHUP_BUDGET_MSEC := 8.0
## Lo menos que se enseña la barra de vuelta. Con la ausencia acreditándose en dos fotogramas,
## sin esto sería un pestañeo, y un pestañeo se lee como un fallo gráfico, no como una espera.
const CATCHUP_MIN_SECONDS := 0.6

var engine: SimEngine
var view: SettlementView
var camera: ScaleCamera
var hud: HUD

var _next_autosave: float = AUTOSAVE_CYCLES
var _focused_id: int = -1
## Los ancestros del nodo enfocado, del padre a la raíz, apuntados al enfocar. Si el foco
## colapsa ya no se puede leer su `parent_id` —el nodo no existe—, y el foco tiene que subir
## al ancestro vivo más cercano, no saltar a la raíz desde tres niveles más abajo.
var _focus_ancestors: PackedInt32Array = PackedInt32Array()
## El último hijo visitado desde cada padre (`padre → hijo`). Es a donde entra la cámara al
## acercarse sobre el padre cuando no hay ningún hijo bajo el puntero (`ChildMapRenderer.child_at`).
## Es de la vista, no de la partida: no se guarda y se vacía al ascender, que reparte ids nuevos.
var _last_child: Dictionary = {}
## El foco con el que se guardó la partida cargada, o -1. Solo se lee al arrancar.
var _saved_focus: int = -1
## Acreditación en curso. Mientras no sea `null`, la vista no se refresca y no se puede tocar
## nada: ver `_begin_catch_up`.
var _catch_up: SimEngine.CatchUpJob = null
var _catch_up_started: float = 0.0
var _catch_up_percent: int = -1
## Si la partida de este arranque salió de un save. Solo lo lee `Analytics` para `game_start`.
var _loaded: bool = false
## La velocidad que había antes de abrir el modal de consentimiento del primer arranque, o -1 si
## no está abierto. Mientras lo esté, el reloj va a ×0: lo que pasa antes de decidir no es de
## nadie, ni de la sesión que aún no existe ni del jugador que aún está leyendo.
var _speed_before_consent: int = -1
## Hacía falta decidir pero había una barra de vuelta delante: el modal espera a que acabe
## (`_end_catch_up`). Pararle el reloj a una acreditación a medias no tiene sentido, y dos paneles
## en el mismo hueco se pisan.
var _consent_pending: bool = false
## La vista agregada se enseña siempre, sea cual sea la profundidad. Solo lo pone `--shot-depth`.
var _force_child_map: bool = false
## El cambio de foco en curso no venía del zoom (la lista de colonias, un colapso, ascender): hay
## que encuadrar el nodo nuevo, y se hace cuando la vista lo tiene listo (`_on_focus_shown`), no
## antes, porque hasta entonces no se sabe cuánto mide.
var _frame_when_shown: bool = false


func _ready() -> void:
	engine = SimEngine.new()
	engine.name = "SimEngine"
	add_child(engine)

	view = SettlementView.new()
	view.name = "SettlementView"
	view.warm_up_seconds = WARM_UP_SECONDS
	add_child(view)
	view.focus_shown.connect(_on_focus_shown)

	camera = ScaleCamera.new()
	camera.name = "Camera"
	camera.enabled = true
	add_child(camera)
	# Alejarse más allá del mínimo sube al padre y acercarse entra en un hijo: la cámara solo lo
	# pide, y el cambio pasa por la misma ruta que la lista de colonias.
	camera.focus_requested.connect(_on_camera_crossed)
	# Al acercarse, se entra en el hijo que hay bajo el puntero. La cámara pregunta con un punto
	# del mundo, y la vista está en el origen: es el mismo punto en sus coordenadas locales.
	# Durante un cambio de foco a medias no hay nada que tocar: las manchas son del foco nuevo y aún
	# se están fundiendo, y un clic ahí (o el toque que Godot duplica como clic de ratón) pediría
	# un segundo cruce encima del primero. Se ignora, no se encola (M3c).
	camera.child_picker = func(world_point: Vector2) -> int:
		if view.is_transitioning():
			return -1
		return view.child_map.child_at(view.to_local(world_point))
	# Dónde está y cuánto mide una mancha, para el zoom anclado y el vuelo del clic (M3c).
	camera.blob_locator = func(id: int) -> Vector3:
		var blob := view.child_map.blob_of(id)
		var at := view.to_global(Vector2(blob.x, blob.y))
		return Vector3(at.x, at.y, blob.z)

	hud = HUD.new()
	hud.name = "HUD"
	add_child(hud)

	hud.build_requested.connect(_on_build)
	hud.speed_requested.connect(_on_speed)
	hud.workers_changed.connect(_on_workers_changed)
	hud.delegation_toggled.connect(_on_delegation_toggled)
	hud.governor_changed.connect(_on_governor_changed)
	hud.promotion_requested.connect(_on_promote)
	hud.found_requested.connect(_on_found)
	hud.accelerate_requested.connect(_on_accelerate)
	hud.route_requested.connect(_on_route)
	hud.upgrade_requested.connect(_on_upgrade)
	hud.legacy_requested.connect(_on_legacy)
	hud.ascension_requested.connect(_on_ascend)
	hud.focus_requested.connect(_on_focus_requested)
	# Conectar antes de arrancar: si no, el evento de fundación de la partida se pierde.
	engine.cycle_advanced.connect(_on_cycle_advanced)
	engine.events.event_pushed.connect(_on_event)
	# `--event-log` vuelca el diario a `user://logs/<categoría>.jsonl`, para depurar lo que la
	# captura no enseña. Nunca en los tests ni por defecto.
	engine.events.write_files = "--event-log" in OS.get_cmdline_user_args()

	_fit_content_scale()
	# Cargar y enfocar **antes** de acreditar: el pueblo se ve tal y como se dejó, y lo que
	# pasó mientras no estabas se cuenta encima de él en vez de en una pantalla negra.
	var away := _load_or_start()
	# El foco con que se guardó; si ese nodo ya no existe (o el save es de antes), la raíz.
	var start := engine.state.get_node_by_id(_saved_focus)
	_focus(start if start != null else engine.state.root())
	get_viewport().size_changed.connect(_on_viewport_resized)
	# La analítica se engancha con la partida ya cargada, y nunca en una captura: con
	# `AUGUR_KEY` en el entorno, una captura abriría sesiones que no son de nadie. Va **antes**
	# de la barra de vuelta porque `begin_offline` necesita saber ya si hay clave y qué partida
	# es; el consentimiento, en cambio, va después, porque mira si hay barra para esperarla.
	# `begin_catch_up` no da ningún paso, así que el `game_start` sale igual que antes: con el
	# estado de antes de la ausencia.
	var capture := _is_capture()
	if not capture:
		Analytics.attach(engine, _loaded)
	if away > 0.0:
		_begin_catch_up(away)
	if not capture:
		_setup_consent()
	_maybe_capture()


## La resolución base sigue a la orientación de la pantalla.
##
## `canvas_items` escala por el eje que peor encaja. Con una base fija de 1280×720, un móvil
## vertical de 720×1280 sale a 0.5625×: el viewport lógico se estira a 1280×2276, el dock se
## queda en un 23 % de la pantalla en vez del 42 %, y una fuente de 13 px se dibuja con 7. En
## vertical, entonces, la base es vertical, y el factor vuelve a 1.
##
## Solo toca el caso vertical: en apaisado la base sigue siendo la de siempre.
func _fit_content_scale() -> void:
	var window := get_window()
	if window == null:
		return
	var portrait := window.size.y > window.size.x
	window.content_scale_size = Vector2i(720, 1280) if portrait else Vector2i(1280, 720)


## Si este arranque es una captura (`--shot=<ruta>`). Mira lo mismo que `_maybe_capture`, que
## solo captura con una ruta no vacía, y existe aparte porque hay que saberlo **antes** de
## capturar: la analítica no puede engancharse a una partida que solo existe para una foto.
func _is_capture() -> bool:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot=") and arg.length() > 7:
			return true
	return false


## Modo de captura para verificar el apartado visual sin un humano delante:
##   godot-4 --path . -- --shot=user://shot.png --shot-cycles=400
## Adelanta la simulación los ciclos pedidos, guarda una imagen del viewport y sale.
## `--shot-focus-child=<n>` enfoca, tras los ciclos, el hijo vivo n-ésimo de la raíz: es la
## forma de fotografiar un hijo gestionado y las migas de pan de la cabecera.
func _maybe_capture() -> void:
	var shot := ""
	var cycles := 0.0
	var hour := -1.0
	var delegate := false
	var promote := false
	var legacy := -1.0
	var tab := -1
	var zoom := 0.0
	var catchup_at := -1.0
	var focus_child := -1
	var shot_depth := -1.0
	var shot_fade := -1.0
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			shot = arg.substr(7)
		elif arg.begins_with("--shot-cycles="):
			cycles = float(arg.substr(14))
		elif arg.begins_with("--shot-hour="):
			hour = float(arg.substr(12))
		elif arg == "--shot-governor":
			delegate = true
		elif arg == "--shot-promote":
			promote = true
		elif arg.begins_with("--shot-legacy="):
			legacy = float(arg.substr(14))
		elif arg.begins_with("--shot-tab="):
			tab = int(arg.substr(11))
		elif arg.begins_with("--shot-zoom="):
			zoom = float(arg.substr(12))
		elif arg.begins_with("--shot-catchup="):
			catchup_at = clampf(float(arg.substr(15)), 0.0, 1.0)
		elif arg.begins_with("--shot-focus-child="):
			focus_child = int(arg.substr(19))
		elif arg.begins_with("--shot-depth="):
			shot_depth = maxf(float(arg.substr(13)), 0.0)
		elif arg.begins_with("--shot-fade="):
			shot_fade = clampf(float(arg.substr(12)), 0.0, 1.0)
	if shot.is_empty():
		return
	if _catch_up != null:
		if catchup_at >= 0.0:
			# La barra de vuelta a medio camino. Es un estado que dura medio segundo y no se
			# puede fotografiar de otra manera: con `--offline=` se fuerza la ausencia y aquí se
			# para la acreditación donde se pida.
			while _catch_up.progress() < catchup_at and not _catch_up.is_done():
				engine.advance_catch_up(_catch_up, 0.001)
			hud.set_catch_up_progress(_catch_up.progress(), _catch_up.credited)
			await _save_shot(shot)
			return
		# Si no, una captura no espera barras: lo que quedaba de ausencia se acredita de un
		# tirón, y así la foto es siempre del mundo ya despierto.
		engine.advance_catch_up(_catch_up)
		_end_catch_up()
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
	if focus_child >= 0:
		var alive: Array[SimNode] = []
		for id in engine.state.root().children:
			var child := engine.state.get_node_by_id(id)
			if child != null:
				alive.append(child)
		if focus_child < alive.size():
			_on_focus_requested(alive[focus_child].id)
			_settle_capture_focus(shot_fade)
		else:
			push_warning("--shot-focus-child=%d: la raíz solo tiene %d hijos vivos" % [
				focus_child, alive.size(),
			])
	if shot_depth >= 0.0:
		_shot_depth(shot_depth, shot_fade)
	if promote:
		_on_promote()
	# La pestaña de legado solo existe cuando hay legado, y para tenerlo de verdad hay que
	# levantar un asentamiento hasta la cúspide y tirarlo. `--shot-legacy=40` lo da hecho: es la
	# única forma de fotografiar esa pestaña sin jugarse una partida entera delante.
	#
	# Deja el árbol **a medio recorrer**, comprando las raíces por la misma vía que el jugador:
	# lo que hay que poder mirar en una captura es un árbol con las tres cosas a la vez —lo
	# comprado, lo que está a tiro y lo que aún no—, no uno recién estrenado.
	if legacy >= 0.0:
		engine.state.legacy = legacy
		engine.state.peak_pop = maxf(engine.state.peak_pop, Ascension.MIN_PEAK_POP * 4.0)
		for id in ["fertile_soil", "chronicle", "fertile_soil"]:
			Ascension.buy(engine.state, id, engine.events)
		_refresh_hud()
	# La captura tiene que adelantar también el **reloj visual**: son dos simulaciones y la
	# hora del pueblo no depende del ciclo económico. `--shot-hour=13` fotografía el mediodía.
	if tab >= 0:
		hud.select_tab(tab)
	if hour >= 0.0:
		view.set_hour(hour)
	# El pixelart hay que juzgarlo de cerca: al encuadre por defecto un habitante mide cuatro
	# píxeles y da igual lo que lleve dibujado. `--shot-zoom=4` fotografía el diorama.
	if zoom > 0.0:
		camera.zoom = Vector2.ONE * zoom
	view.warm_up(WARM_UP_SECONDS)
	await _save_shot(shot)


## `--shot-depth=<d>`: la vista agregada. Enfoca el nodo de tier `floor(d)` —la raíz si lo es; si
## no, el primero de ese tier por id—, pone la cámara a la profundidad `d` y la centra en los
## hijos, con las manchas visibles aunque la fracción quede por debajo de la regla de `shows_at`.
func _shot_depth(d: float, fade := -1.0) -> void:
	var tier := int(floorf(d))
	var target := engine.state.root()
	if target.tier != tier:
		target = null
		for id in engine.state.ordered_ids():
			var node := engine.state.get_node_by_id(id)
			if node.tier == tier:
				target = node
				break
	if target == null:
		push_warning("--shot-depth=%.2f: no hay ningún nodo de tier %d; se queda la raíz" % [d, tier])
		target = engine.state.root()
	_on_focus_requested(target.id)
	_settle_capture_focus(fade)
	_force_child_map = true
	view.child_map.visible = true
	camera.set_depth(d)
	camera.center_on(view.child_map.content_rect().get_center())
	print("--shot-depth=%.2f: %s (tier %d), zoom ×%.2f, %d hijos, %d expediciones de este nodo" % [
		d, target.name, target.tier, camera.zoom.x, target.children.size(),
		engine.state.expeditions.filter(func(e: Expedition) -> bool:
			return e.parent_id == target.id).size(),
	])
	for e in engine.state.expeditions:
		if e.parent_id == target.id:
			print("  expedición: sale %.0f, llega %.0f, ahora %.0f (%.0f %%)" % [
				e.depart_cycle, e.arrive_cycle, engine.state.cycle,
				100.0 * (engine.state.cycle - e.depart_cycle) / (e.arrive_cycle - e.depart_cycle),
			])


## Una captura no espera fotogramas: el cambio de foco se termina en el acto. Con `--shot-fade=<t>`
## se queda a medias, con el destino ya preparado y caliente y el fundido congelado en `t` (0 = solo
## el origen, 1 = solo el destino): es la foto del cruce, para ver si alguien sale amontonado o
## falta gente.
func _settle_capture_focus(fade: float) -> void:
	if not view.is_transitioning():
		return
	if fade >= 0.0:
		view.hold_fade(fade)
		print("--shot-fade=%.2f: fundido congelado (%d puntos visibles entre las dos capas)" % [
			fade, view.drawn_dots().size()])
	else:
		view.finish_transition()


func _save_shot(shot: String) -> void:
	# Dos fotogramas: uno para que los `Control` calculen su tamaño y otro para dibujarlos.
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(shot)
	print("captura guardada en %s" % ProjectSettings.globalize_path(shot))
	get_tree().quit()


## Carga la partida (o funda una nueva) y devuelve los **segundos de ausencia sin acreditar**.
## Acreditarlos es cosa de `_begin_catch_up`, ya con la vista montada y el mundo a la vista.
func _load_or_start() -> float:
	var elapsed := []
	var saved_view := {}
	var state := Save.read(elapsed, saved_view)
	_saved_focus = int(saved_view.get("focus", -1))
	_loaded = state != null
	if state == null:
		engine.start(int(Time.get_unix_time_from_system()))
		return _forced_offline_seconds()
	engine.adopt(state)
	# El siguiente autoguardado se cuenta desde el ciclo cargado. Sin esto, una partida que
	# vuelve en el ciclo 5.000 se autoguarda en el primer ciclo que pase —en mitad de la
	# acreditación— porque el contador seguía en 30.
	_next_autosave = engine.state.cycle + AUTOSAVE_CYCLES
	var away: float = elapsed[0] if not elapsed.is_empty() else 0.0
	return maxf(away, _forced_offline_seconds())


## `--offline=<segundos>` fuerza una ausencia. Es para poder ver la pantalla de vuelta y la
## barra sin cerrar el juego un día entero.
func _forced_offline_seconds() -> float:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--offline="):
			return maxf(float(arg.substr(10)), 0.0)
	return 0.0


# ---------------------------------------------------------------------------
# La vuelta: acreditar la ausencia sin colgar el juego
# ---------------------------------------------------------------------------

## Acreditar una ausencia larga cuesta demasiado para un solo fotograma, así que se reparte
## entre varios y se enseña por dónde va.
##
## Mientras dura, **la vista no se refresca** (`_on_cycle_advanced` y `_on_event` se callan) y
## no se puede tocar nada. No es solo por rendimiento: refrescar el HUD en cada uno de los 64
## pasos era el cuelgue, y dejar que el jugador construya sobre un mundo que está avanzando a
## saltos de 700 ciclos sería peor que hacerle esperar medio segundo.
func _begin_catch_up(away_seconds: float) -> void:
	_catch_up = engine.begin_catch_up(away_seconds)
	if _catch_up == null:
		return
	_catch_up_started = float(Time.get_ticks_msec()) / 1000.0
	_catch_up_percent = -1
	# Lo que pase hasta `_end_catch_up` se resume en un solo `offline_return`. La ausencia va
	# sin recortar: el tope lo cuenta el informe.
	Analytics.begin_offline(away_seconds)
	# La cámara escucha en `_unhandled_input`, y un `Control` no consume los eventos de dedo ni
	# los gestos: el velo del HUD no basta para dejarla quieta.
	camera.set_process_unhandled_input(false)
	hud.begin_catch_up(_catch_up.credited)


## Un fotograma de acreditación. Devuelve `true` si todavía queda (o si falta enseñar la barra
## el mínimo de tiempo), para que `_process` no siga con lo suyo.
func _advance_catch_up() -> bool:
	var finished := engine.advance_catch_up(_catch_up, CATCHUP_BUDGET_MSEC)
	var percent := int(_catch_up.progress() * 100.0)
	if percent != _catch_up_percent:
		_catch_up_percent = percent
		hud.set_catch_up_progress(_catch_up.progress(), _catch_up.credited)
	if not finished:
		return true
	var shown := float(Time.get_ticks_msec()) / 1000.0 - _catch_up_started
	if shown < CATCHUP_MIN_SECONDS:
		return true
	_end_catch_up()
	return false


## El mundo despierta: un solo refresco de vista y HUD para los 43.200 ciclos acreditados, y el
## informe de vuelta en el mismo panel donde estaba la barra.
func _end_catch_up() -> void:
	_catch_up = null
	camera.set_process_unhandled_input(true)
	# El nodo enfocado puede haberse despoblado mientras no estabas: se sube al ancestro vivo más
	# cercano, como cuando colapsa jugando, y no a la raíz.
	if focused() == null:
		_focus(_nearest_live_ancestor())
	else:
		view.refresh(focused())
		if view.focus_ready() and not _frame_when_shown:
			camera.reframe_if_untouched(view.settlement_extent(), view.terrain_bounds(),
				_view_rect())
		_refresh_hud()
	hud.end_catch_up(engine.last_offline)
	# El mismo informe que acaba de enseñar la pantalla: la cifra del tablero es la que leyó el
	# jugador. Antes del modal de consentimiento, que con él pendiente no hay sesión que mande.
	Analytics.end_offline(engine.last_offline)
	if _consent_pending:
		_consent_pending = false
		if Analytics.needs_consent_decision():
			_open_first_consent()


# ---------------------------------------------------------------------------
# Consentimiento de la analítica
# ---------------------------------------------------------------------------

## Con clave, el HUD monta el modal y el ⚙️; sin ella no existe ninguno de los dos. Si aún no hay
## decisión, el modal sale **antes de que corra el reloj**: esto se llama en `_ready`, antes del
## primer fotograma, así que no se cuela ni un tick.
func _setup_consent() -> void:
	if not Analytics.enabled:
		return
	hud.enable_consent()
	hud.consent_decided.connect(_on_consent_decided)
	hud.consent_settings_requested.connect(_on_consent_settings)
	if not Analytics.needs_consent_decision():
		return
	if _catch_up != null:
		_consent_pending = true
	else:
		_open_first_consent()


## El modal del primer arranque: velo, sin salida, y la partida a ×0 hasta que se elija.
func _open_first_consent() -> void:
	if _speed_before_consent < 0:
		_speed_before_consent = engine.speed_index
	engine.set_speed_index(0)
	_refresh_hud()
	hud.open_consent(true, false)


## La decisión pasa por `Analytics`, que es quien habla con el SDK (aceptar abre la sesión y
## manda `game_start`; rechazar borra la cola). Si era el modal del primer arranque, el reloj
## vuelve a la velocidad que tenía.
func _on_consent_decided(granted: bool) -> void:
	Analytics.set_consent(granted)
	if _speed_before_consent >= 0:
		engine.set_speed_index(_speed_before_consent)
		_speed_before_consent = -1
		_refresh_hud()


## ⚙️: el mismo modal, en modo «cambiar» y con la decisión vigente. Este no para el reloj, igual
## que la confirmación del ascenso: se puede volver sin cambiar nada.
func _on_consent_settings() -> void:
	hud.open_consent(false, Analytics.has_consent())


## Enfoca un nodo. La **única** ruta de cambio de foco.
##
## `carry`: el cambio lo ha pedido el zoom al cruzar de escala. La cámara se queda mirando el mismo
## punto del mundo con el mismo zoom, y la vista funde la capa vieja en la nueva. Sin `carry` (la
## lista de colonias, un colapso, ascender) también se funde, pero el nodo nuevo se encuadra en
## cuanto la vista lo tiene listo.
func _focus(node: SimNode, carry := false) -> void:
	if node == null:
		return
	_focused_id = node.id
	_focus_ancestors = PackedInt32Array()
	var parent := engine.state.get_node_by_id(node.parent_id)
	while parent != null:
		_focus_ancestors.append(parent.id)
		parent = engine.state.get_node_by_id(parent.parent_id)
	if node.parent_id >= 0:
		_last_child[node.parent_id] = node.id
	var shift := view.show_node(node, engine.state)
	if view.shown == SettlementView.Shown.FADE:
		# La vista prepara el destino por trozos y lo calienta sin enseñarlo: aquí no se gasta
		# nada. La cámara se lleva el punto que miraba, para que lo que se ve no se mueva.
		camera.carry(shift, view.terrain_bounds(), _view_rect())
		_frame_when_shown = not carry
	else:
		# Un pueblo cargado de una partida no puede verse vacío llenándose a cuentagotas: se
		# puebla de golpe y se le dan unos segundos de vida para que nadie salga en la puerta.
		_frame_when_shown = false
		view.warm_up(WARM_UP_SECONDS)
		camera.frame(view.settlement_extent(), view.terrain_bounds(), _view_rect())
	# A dónde se cruza con el zoom. La cámara no conoce `WorldState`: se le dicen los ids.
	var parent_id := node.parent_id if engine.state.get_node_by_id(node.parent_id) != null else -1
	var child_id := int(_last_child.get(node.id, -1))
	var child := engine.state.get_node_by_id(child_id)
	if child == null or child.parent_id != node.id:
		child_id = -1
	camera.set_focus(node.tier, parent_id, child_id, carry)
	# Volver a una capa que se estaba yendo: ya está lista, y `focus_shown` no va a llegar.
	if _frame_when_shown and view.focus_ready():
		_on_focus_shown()
	_refresh_hud()


## La vista tiene listo el foco nuevo y empieza a fundirlo. Si el cambio no venía del zoom, es
## ahora cuando se sabe cuánto mide el pueblo y se puede encuadrar.
func _on_focus_shown() -> void:
	if not _frame_when_shown:
		return
	_frame_when_shown = false
	camera.frame(view.settlement_extent(), view.terrain_bounds(), _view_rect())


## El trozo de pantalla que el HUD deja libre. La cámara encuadra ahí, no en la ventana: con
## el dock ocupando un tercio del ancho, encuadrar contra la ventana entera deja el pueblo
## centrado en la pantalla y por tanto medio tapado.
func _view_rect() -> Rect2:
	return hud.free_rect()


func focused() -> SimNode:
	return engine.state.get_node_by_id(_focused_id) if engine.state != null else null


## El HUD pide entrar en un hijo o volver al padre. Es el mismo `_focus` de siempre: la vista
## funde la capa del nodo viejo en la del nuevo y el HUD pasa a gestionarlo igual que a la raíz.
func _on_focus_requested(id: int) -> void:
	if _catch_up != null or engine.state == null:
		return
	var node := engine.state.get_node_by_id(id)
	if node != null and node.id != _focused_id:
		# Solo aquí, cuando el jugador cambia de nodo: al arrancar, al ascender o al subir tras un
		# colapso el diario se queda como está, porque lo que acaba de pasar es justo lo que
		# cuenta («se despuebla y desaparece», la fundación del mundo).
		hud.clear_events()
		_focus(node)


## La cámara ha cruzado de escala con el zoom: el mismo cambio de foco, pero llevándose la vista.
func _on_camera_crossed(id: int) -> void:
	if _catch_up != null or engine.state == null:
		return
	var node := engine.state.get_node_by_id(id)
	if node != null and node.id != _focused_id:
		hud.clear_events()
		# Entrar en un hijo: su mancha se queda de fantasma en lo que se funde la capa nueva, o
		# la mancha anclada —entera hasta aquí— desaparecería de golpe. Al subir no hace nada.
		view.child_map.hand_off(id)
		_focus(node, true)


## El ancestro vivo más cercano del foco, o la raíz si no queda ninguno.
func _nearest_live_ancestor() -> SimNode:
	for id in _focus_ancestors:
		var node := engine.state.get_node_by_id(id)
		if node != null:
			return node
	return engine.state.root()


func _process(delta: float) -> void:
	if engine.state == null:
		return
	if _catch_up != null and _advance_catch_up():
		# Aun acreditando, la multitud sigue: el pueblo se ve vivo detrás del panel en vez de
		# congelado. Va en segundos reales y no toca el estado, así que no altera nada.
		view.advance(delta)
		return
	# La vista agregada se funde según la profundidad de la cámara (`ChildMapRenderer.alpha_at`), y
	# además con la capa del foco: al cruzar al padre, sus manchas aparecen con su terreno.
	# La mancha a la que está anclado el zoom (M3c) no se desvanece: va entera, solo con el fundido
	# de capas. El fantasma de la mancha por la que se acaba de entrar se apaga según se enciende
	# la capa del hijo.
	var focus_alpha := view.focus_alpha()
	var map_alpha := 1.0 if _force_child_map else ChildMapRenderer.alpha_at(camera.depth)
	map_alpha *= focus_alpha
	view.child_map.set_fade(map_alpha, camera.anchored_child(), focus_alpha, 1.0 - focus_alpha)
	view.child_map.visible = view.child_map.shows_anything()
	# Mientras el jugador se acerca al cruce, se va preparando el nodo al que llegaría: cuando
	# cruce, terreno, textura y `Layout` ya estarán en la caché de la vista.
	var crossing := camera.crossing_target(get_viewport().get_mouse_position())
	if crossing >= 0:
		view.prefetch(engine.state.get_node_by_id(crossing), engine.state)
	# **En tiempo real, no en ciclos.** El pueblo tiene su propio reloj: sigue vivo con la
	# pausa puesta y no se acelera al poner ×8. Aquí también converge la multitud hacia lo
	# que dicen los números, por segundos reales, no por ticks.
	view.advance(delta)


func _on_viewport_resized() -> void:
	# Girar el móvil cambia la orientación, y con ella la resolución base.
	_fit_content_scale()
	camera.frame(view.settlement_extent(), view.terrain_bounds(), _view_rect())


func _on_cycle_advanced(cycle: float) -> void:
	# Acreditando una ausencia no se refresca nada: son hasta 64 pasos y ninguno se va a
	# mirar. Refrescar en todos ellos es lo que colgaba el juego al volver.
	if _catch_up != null:
		return
	var node := focused()
	if node == null:
		# El nodo enfocado ha desaparecido (colapso): subir al ancestro vivo más cercano, no
		# saltar a la raíz desde tres niveles más abajo.
		_focus(_nearest_live_ancestor())
		return
	view.refresh(node)
	# El pueblo crece: se reencuadra, salvo que el jugador esté mirando algo a su aire. Y no a
	# mitad de un cambio de foco: hasta que la vista lo tiene listo no se sabe cuánto mide.
	if view.focus_ready() and not _frame_when_shown:
		camera.reframe_if_untouched(view.settlement_extent(), view.terrain_bounds(), _view_rect())
	_refresh_hud()
	if cycle >= _next_autosave:
		_next_autosave = cycle + AUTOSAVE_CYCLES
		_save()
		engine.events.flush()


func _refresh_hud() -> void:
	var node := focused()
	if node == null:
		return
	var mods := engine.current_modifiers()
	# Las manchas de los hijos se releen cada vez que el HUD: tras cada ciclo y cada acción. Es
	# O(hijos), y así la expedición recién lanzada o el hijo que pasa hambre salen en el acto.
	view.child_map.refresh(node, engine.state, engine.params, mods)
	var snap := Integrator.snapshot(node, engine.params, mods)
	hud.refresh(node, engine.state, engine.params, snap, engine.speed_index,
		view.agent_count(), view.represents())


func _on_event(entry: Dictionary) -> void:
	# Lo que pasó mientras no estabas se cuenta en el informe de vuelta, no línea a línea en el
	# diario: un gobernador con 24 h por delante construye docenas de veces.
	if _catch_up != null:
		return
	if not _concerns_focus(int(entry.get("node", -1))):
		return
	hud.push_event(String(entry["text"]))


## Si un evento va al diario del nodo enfocado: el diario sigue al foco. Entra lo del propio
## nodo y lo de su subárbol —enfocado el pueblo, que su colonia crezca también es noticia—, y
## no lo de su padre ni sus hermanos. Un evento sin nodo vivo detrás (un colapso, que ya ha
## borrado el suyo, o uno del mundo) se cuenta siempre: no hay a quién atribuirlo.
func _concerns_focus(node_id: int) -> bool:
	var node := engine.state.get_node_by_id(node_id)
	if node == null:
		return true
	while node != null:
		if node.id == _focused_id:
			return true
		node = engine.state.get_node_by_id(node.parent_id)
	return false


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


func _on_upgrade(id: String) -> void:
	var node := focused()
	if node == null or node.is_delegated():
		return
	if Upgrading.buy(node, id, engine.state.cycle, engine.events):
		_refresh_hud()


## El legado no es del nodo, es de la partida: se compra sobre `state`, no sobre el asentamiento
## enfocado, y por eso un gobernador no lo bloquea.
func _on_legacy(id: String) -> void:
	if Ascension.buy(engine.state, id, engine.events):
		_refresh_hud()
		_save()


## Prestigio: se reinicia el mundo a cambio de legado.
##
## `Ascension.ascend` **devuelve un estado nuevo** en vez de vaciar el que hay, así que lo que
## hay que hacer aquí es adoptarlo por el mismo camino que una partida cargada. Guardar en el
## acto no es opcional: si el proceso muere antes del siguiente autoguardado, el jugador vuelve
## al mundo que acaba de dejar atrás y con el legado sin cobrar.
func _on_ascend() -> void:
	var fresh := Ascension.ascend(engine.state, engine.params, engine.events)
	if fresh == engine.state:
		return
	engine.adopt(fresh)
	# El ciclo vuelve a cero. Sin reponer esto, el próximo autoguardado se queda esperando un
	# ciclo que ya pasó en la era anterior y no llega nunca.
	_next_autosave = engine.state.cycle + AUTOSAVE_CYCLES
	# Los ids de la era anterior no significan nada en esta.
	_last_child.clear()
	_focus(engine.state.root())
	_save()


## Subir de escala: el eje vertical del juego.
##
## El mundo se abre. La ventana de terreno crece y aparece mundo nuevo alrededor, pero como la
## generación está anclada en coordenadas absolutas, **lo que ya se veía sale idéntico** y ni
## los edificios ni la gente se mueven un píxel. Solo cambia cuánto alcanzas a ver.
func _on_promote() -> void:
	var node := focused()
	if node == null or not Promotion.can_promote(engine.state, node):
		return
	Promotion.promote(engine.state, node, engine.events)
	view.refresh(node)
	# Reencuadre incondicional: promocionar es el momento del juego, y merece que se vea el
	# mundo nuevo aunque el jugador estuviera mirando un detalle.
	camera.frame(view.settlement_extent(), view.terrain_bounds(), _view_rect())
	_refresh_hud()
	_save()


## Fundar un hijo a mano: la misma `Promotion.launch_expedition` que usa el gobernador, sin ruta
## propia. El hijo nace al llegar la expedición.
## Un nodo delegado no se toca desde aquí (regla 3): el botón ya sale apagado, y esto es la red.
##
## Con `delegate` la colonia nace con un gobernador equilibrado, por `GovernorSys.delegate` al
## llegar, la misma ruta que usa el gobernador cuando funda. No copia la política del padre porque
## aquí el padre **nunca** está delegado: si lo estuviera, esta función ya habría salido.
##
## Los eventos no salen de aquí: `expedition` lo emite `launch_expedition` al salir, y `found` y la
## delegación («pasa a manos de un gobernador») los emite `Promotion.arrive` al llegar, con el
## actor de quien la mandó. Es la misma ruta para el gobernador, y el hijo no existe hasta entonces.
##
## La cuenta atrás no la lleva `Main`: la fila de fundar la lee de `found_child_blocker` en cada
## refresco del HUD.
func _on_found(delegate: bool) -> void:
	var node := focused()
	if node == null or node.is_delegated():
		return
	var sent := Promotion.launch_expedition(engine.state, node, engine.params, engine.events,
		Governor.balanced() if delegate else null)
	if sent == null:
		return
	view.refresh(node)
	_refresh_hud()
	_save()


## ⏩ Acelerar con oro la expedición en camino del nodo enfocado: la misma
## `Promotion.accelerate_expedition` que miraría cualquiera, sin ruta propia. Un nodo delegado no se
## toca desde aquí (regla 3): el botón ya sale apagado, y esto es la red. El evento `accelerate` lo
## emite el sistema.
func _on_accelerate() -> void:
	var node := focused()
	if node == null or node.is_delegated():
		return
	if not Promotion.accelerate_expedition(engine.state, node, engine.params, engine.events):
		return
	_refresh_hud()
	_save()


## Crear una ruta, cambiarle el caudal o borrarla (`rate` 0), siempre por `Logistics.set_route`:
## la misma que usará el gobernador regional. Un nodo delegado no se toca desde aquí (regla 3): los
## botones ya salen apagados, y esto es la red.
##
## Solo entre el nodo enfocado y uno de sus hijos: la lista vive en el padre, que es quien paga el
## 🐎. Se guarda al vuelo, como la política del gobernador: es la acción entera.
func _on_route(from_id: int, to_id: int, good: int, rate: float) -> void:
	var node := focused()
	if node == null or node.is_delegated():
		return
	var other := to_id if from_id == node.id else from_id
	var child := engine.state.get_node_by_id(other)
	if child == null or child.parent_id != node.id:
		return
	# Crear o cambiar pasa por la misma lista de condiciones que enseña el HUD. Borrar no: una
	# ruta que ya existe se puede quitar siempre.
	if rate > 0.0 and not Logistics.route_blocker(engine.state, from_id, to_id, good).is_empty():
		return
	Logistics.set_route(engine.state, from_id, to_id, good, rate)
	_refresh_hud()
	_save()


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


## Retocar la política del gobernador. Delegar deja de ser un interruptor: se le dice a qué da
## prioridad y qué tiene permitido hacer.
##
## Se guarda al vuelo porque no hay ninguna otra acción que lo confirme —mover un deslizador es
## la acción entera—, y perder la política al cerrar sería perder la partida entera de gestión.
func _on_governor_changed(field: String, value: float) -> void:
	var node := focused()
	if node == null or node.governor == null:
		return
	if field.begins_with("may_"):
		node.governor.set(field, value > 0.5)
	elif field == "order":
		# El ordinal llega como `float` por la misma señal que el resto de la política; aquí se
		# vuelve enum. Fuera de rango cae en `NONE`, nunca en una orden que nadie pidió.
		var ordinal := int(value)
		node.governor.order = ordinal as Governor.Order \
			if ordinal >= 0 and ordinal < Governor.Order.size() else Governor.Order.NONE
	else:
		node.governor.set(field, value)
	_save()
	# La orden es un clic, no un arrastre, y su frase no la pinta el propio botón: con el juego
	# en pausa no llegaría un ciclo que la refrescase.
	if field == "order":
		_refresh_hud()
	# A la analítica le llega la política en la que se queda el jugador, no cada píxel del
	# deslizador: `Analytics` espera a que deje de tocar antes de mandarla.
	Analytics.on_policy_changed(node)


## Solo la velocidad que pide el jugador desde el HUD llega a la analítica, y solo si cambia: el
## ×0 del modal de consentimiento va directo al motor y no es una decisión de nadie.
func _on_speed(index: int) -> void:
	var before := engine.speed_index
	engine.set_speed_index(index)
	_refresh_hud()
	if engine.speed_index != before:
		Analytics.on_speed(engine.speed_index)


## Guardar, siempre por aquí: la partida y, fuera de ella, el nodo enfocado, para volver a él al
## cargar. El foco no entra en `WorldState` ni en `state_hash`.
func _save() -> void:
	Save.write(engine.state, {"focus": _focused_id})


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED:
		# Móvil y web pueden matar el proceso sin aviso: guardar al perder el foco es lo
		# único que garantiza que el tiempo offline se cuente desde el instante correcto.
		if engine != null and engine.state != null:
			_save()
			engine.events.flush()
