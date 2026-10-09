extends Node

## Puente entre la partida y Augur, la analítica propia. Es **la única pieza que habla con el
## SDK** (`Augur`, el autoload de `addons/augur/`), y lo hace escuchando: nunca escribe en
## `WorldState` ni en un `SimNode` (regla 7). Lo único que toca de la simulación es
## `events.tracing`, que vive en el log y no en el modelo, y que `analytics_test` demuestra que
## no cambia un bit de `state_hash()`.
##
## Va en `platform/` junto a `Save` porque es la otra frontera con el exterior. Es autoload —el
## primero del proyecto— por dos razones: el SDK tiene que oír el cierre de ventana antes que la
## escena (por eso `Augur` va delante en `[autoload]`), y la dependencia tiene que verse en
## `project.godot` y no esconderse en `Main`.
##
## **Sin `attach()` no hace nada.** El autoload se carga también en los tests lanzados con
## `-s`, y en el modo captura; ninguno de los dos llama a `attach`, así que ni se configura el SDK
## ni se escribe `user://augur/`. Y sin clave, `attach` vuelve antes de configurar: el juego sin
## clave es exactamente el de antes, sin modal, sin ⚙️ y sin red.
##
## Tiene el arranque seguro (M1 del plan de integración: clave, canal y consentimiento), el
## `game_start` con el que empieza cada sesión (M2), el puente de eventos (M3) —cada `push` de
## acción del log sale como evento del contrato con su `actor`, el rastro del gobernador sale
## como `governor_decision`, y `Main` le avisa de la velocidad y de la política del gobernador—
## y la foto periódica de cada nodo (`node_sample`) más el resumen de una ausencia
## (`offline_return`), M4.

## Segundos **reales** sin un `governor_changed` nuevo para dar la política por elegida. Los
## deslizadores emiten en cada píxel que se mueven (`ui/HUD.gd`); lo que interesa es la política
## en la que se queda el jugador, no el recorrido hasta ella.
const POLICY_SETTLE_S := 2.0

## Ciclos de juego entre dos `node_sample`. **En ciclos y no en segundos reales**: los ritmos se
## comparan en ciclos, y una foto por reloj de pared daría ocho veces más fotos a ×8 que a ×1
## para la misma partida. A ×1 son 12 por hora y nodo.
const SAMPLE_EVERY := 300.0

## Endpoint de producción. Se sobrescribe con `AUGUR_ENDPOINT` en el entorno (dev, pruebas) o con
## `endpoint` en `augur_release.cfg`.
const DEFAULT_ENDPOINT := "https://augur.dcahomelab.com"
## Lo genera el plan de builds al exportar y **nunca entra al repo** (`.gitignore`). Sección
## `[augur]`, claves `key` y `endpoint`.
const RELEASE_CFG := "res://augur_release.cfg"

## `true` solo con clave y tras `Augur.configure()`. Es lo que la UI mirará para enseñar el modal
## y el ⚙️: sin clave, ninguno de los dos existe.
var enabled := false
## Para filtrar en los tableros: `dev` con la clave del entorno, `release` con la del fichero
## embebido, `debug` en un export de depuración (que también tiene la feature `template` y no
## puede ensuciar los ritmos de verdad).
var channel := "dev"

## Se guarda para encender y apagar el rastro al cambiar el consentimiento, y para el puente de
## eventos. Solo se lee `events`; el estado de la partida no se toca desde aquí.
var _engine: SimEngine = null
## Si la partida de este arranque venía de un save. Lo sabe `Main`, que es quien carga; aquí solo
## viaja hasta `game_start`.
var _loaded := false
## Si la sesión abierta ya lleva su `game_start`. **Una sesión, un `game_start`**: aceptar otra
## vez desde ⚙️ con la sesión ya abierta no la reabre en el SDK, y tampoco puede duplicar el
## evento. Rechazar cierra la sesión, y lo baja: volver a aceptar abre una nueva, con el suyo.
var _started := false
## Ausencia en curso, resumida aparte. Durante una barra de vuelta no se reenvía **nada suelto**:
## un día delegado son docenas de `build` y cientos de decisiones que no le pasan al jugador
## delante, y van resumidas en un solo `offline_return`. Lo enciende `begin_offline` y lo apaga
## `end_offline`, los dos desde `Main`, que es quien pone y quita la barra.
##
## Va de barra a barra y no de acreditación a acreditación: el motor suelta su `_catch_up_job`
## en cuanto da el último paso, pero `Main` deja la barra puesta un mínimo de tiempo
## (`CATCHUP_MIN_SECONDS`) y en ese hueco el reloj normal ya corre. Lo que pase ahí tampoco lo
## ve el jugador, así que también va al resumen y no suelto.
var _offline := false
## Lo que dura la ausencia y lo que se cuenta de ella mientras dura. `_away_s` es la ausencia
## **sin recortar** (el `OfflineReport` solo guarda la acreditada), y los nodos delegados se
## cuentan al empezar: son los que el jugador dejó al mando, que es lo que decide si la
## ausencia se trocea en decisiones o se salda de un salto (`SimEngine.begin_catch_up`).
var _away_s := 0.0
var _off_delegated := 0
var _off_founded := 0
var _off_promoted := 0
var _off_decisions := 0
var _off_collapsed := 0
## Múltiplo de `SAMPLE_EVERY` en el que se hizo la última foto, `floor(cycle / 300)`. Se mueve
## siempre —con o sin consentimiento, en barra o no—, y solo se manda foto al subir: así un
## tick que cruza varios múltiplos (×8, o el final de una barra) da una sola, y la vuelta de
## una ausencia no dispara la foto de golpe sino en el múltiplo siguiente.
var _sample_bucket := 0
## Nodo con una política del gobernador pendiente de mandar, o -1. Solo uno: si el jugador pasa a
## retocar otro nodo antes de que venza la espera, la del primero ya está elegida y sale en el acto.
var _policy_node := -1
## Temporizador de la política. Se crea al primer cambio, no en `_ready`: el autoload también se
## carga en los tests y en captura, y ahí no tiene nada que esperar.
var _policy_timer: Timer = null


## Configura el SDK si hay clave. Se llama una vez desde `Main._ready`, después de cargar la
## partida y **nunca en captura**: una captura con `AUGUR_KEY` en el entorno no puede abrir
## sesiones.
##
## La clave sale primero del entorno (desarrollo) y, solo en un export, del fichero embebido. El
## orden importa: en el editor no hay fichero, y en un export el entorno manda para poder probar
## una build contra dev sin reexportar.
func attach(engine: SimEngine, loaded: bool = false) -> void:
	if enabled:
		return
	_engine = engine
	_loaded = loaded
	var key := OS.get_environment("AUGUR_KEY").strip_edges()
	var endpoint := OS.get_environment("AUGUR_ENDPOINT").strip_edges()
	if key.is_empty() and OS.has_feature("template"):
		var cfg := ConfigFile.new()
		if cfg.load(RELEASE_CFG) == OK:
			key = str(cfg.get_value("augur", "key", "")).strip_edges()
			if endpoint.is_empty():
				endpoint = str(cfg.get_value("augur", "endpoint", "")).strip_edges()
		channel = "debug" if OS.has_feature("template_debug") else "release"
	if key.is_empty():
		# Sin clave no existe la analítica: ni SDK configurado, ni disco, ni red.
		channel = "dev"
		return
	if endpoint.is_empty():
		endpoint = DEFAULT_ENDPOINT
	Augur.configure(key, endpoint)
	enabled = true
	# El puente solo se conecta con clave. `events` es del motor y sobrevive a la ascensión
	# (`adopt` cambia `state`, no el log), así que basta con conectarse una vez. Escuchar no
	# cambia nada: `event_pushed` y `traced` se emiten igual haya o no alguien al otro lado.
	engine.events.event_pushed.connect(_on_event)
	engine.events.traced.connect(_on_traced)
	# Las fotos de nodo van por ciclos del motor. Un estado nuevo (ascender, cargar) vuelve el
	# ciclo a su origen: el contador se recoloca ahí en vez de esperar al múltiplo de la era
	# vieja o, peor, de mandar una foto en el ciclo 0,1 por ver que el múltiplo «ha cambiado».
	engine.cycle_advanced.connect(_on_cycle_advanced)
	engine.state_replaced.connect(_on_state_replaced)
	_sample_bucket = _bucket(engine.state.cycle) if engine.state != null else 0
	# El SDK avisa antes de escribir `session_end`: lo último que se decidió aún cabe en la sesión.
	Augur.closing.connect(_flush_policy)
	# El rastro del gobernador solo se calcula si alguien va a mandarlo: con el consentimiento
	# sin decidir o rechazado, `_decide` ni arma el registro.
	engine.events.tracing = Augur.has_consent()
	# Con el consentimiento aceptado en un arranque anterior, `configure` ya ha abierto la sesión
	# de este: se marca aquí, que es el único sitio donde eso ocurre. Así la regla es una sola
	# —cada sesión que se abre lleva su `game_start`—, venga de `configure` o de `set_consent`.
	if Augur.has_consent():
		_game_start()


## Hay clave pero el jugador todavía no ha dicho ni sí ni no: toca el modal del primer arranque.
func needs_consent_decision() -> bool:
	return enabled and not Augur.has_consent_decision()


func has_consent() -> bool:
	return enabled and Augur.has_consent()


## Guarda la decisión del jugador. Rechazar hace que el SDK borre su cola local; aceptar abre
## sesión. El rastro sigue a la decisión para no calcular lo que no se va a mandar.
func set_consent(granted: bool) -> void:
	if not enabled:
		return
	Augur.set_consent(granted)
	if _engine != null:
		_engine.events.tracing = granted
	if granted:
		_game_start()
	else:
		# El SDK ha cerrado la sesión sin subirla y ha borrado la cola: la próxima que se abra es
		# otra, y necesitará su propio `game_start`.
		_started = false


## El evento con el que empieza cada sesión: la foto de la partida en el instante en que se
## empieza a observar. Lee el estado, nunca lo escribe. Props planas, con `era`, `cycle` y
## `channel` como todos los eventos del contrato.
func _game_start() -> void:
	if _started or _engine == null or _engine.state == null:
		return
	_started = true
	var state := _engine.state
	var tier_max := 0
	var delegated := 0
	for id in state.ordered_ids():
		var node := state.get_node_by_id(id)
		tier_max = maxi(tier_max, node.tier)
		if node.is_delegated():
			delegated += 1
	Augur.track("game_start", {
		"loaded": _loaded,
		"era": state.era,
		"cycle": state.cycle,
		"nodes": state.nodes.size(),
		"tier_max": tier_max,
		"delegated_nodes": delegated,
		"channel": channel,
	})


# ---------------------------------------------------------------------------
# El puente: del log de la partida a los eventos del contrato
# ---------------------------------------------------------------------------

## Si se puede mandar algo ahora. Sin clave o sin consentimiento, nada; y durante una barra de
## vuelta, nada suelto (ver `_offline`). Hasta M4 la barra se adivinaba leyendo el
## `_catch_up_job` privado del motor; ahora `Main` la anuncia (`begin_offline`/`end_offline`) y
## esa lectura sobra: además se quedaba corta, porque el motor lo suelta antes de que se quite
## la barra.
func _sending() -> bool:
	return enabled and Augur.has_consent() and not _offline


## Las props que lleva todo evento del contrato. `cycle` es el del propio registro: en la
## ascensión es el ciclo final de la era que se deja, no el cero de la nueva.
func _base(cycle: float, actor: String) -> Dictionary:
	return {
		"era": _engine.state.era if _engine != null and _engine.state != null else 0,
		"cycle": cycle,
		"channel": channel,
		"actor": actor,
	}


## Tier de un nodo que puede ya no existir (colapso, ascensión): -1 en vez de reventar.
func _tier_of(node_id: int) -> int:
	var node := _node(node_id)
	return node.tier if node != null else -1


func _node(node_id: int) -> SimNode:
	if _engine == null or _engine.state == null:
		return null
	return _engine.state.get_node_by_id(node_id)


## Cada `push` de acción del log, traducido al contrato. `world` no sale (lo cubre `game_start`)
## y `offline` tampoco (lo resume `offline_return`, M4). Las props son **planas** y copiadas
## del registro o leídas del estado en el instante del `push`: nada de referencias.
func _on_event(entry: Dictionary) -> void:
	if _offline:
		_count_offline(entry)
		return
	if not _sending():
		return
	var category := String(entry.get("category", ""))
	var cycle := float(entry.get("cycle", 0.0))
	var node_id := int(entry.get("node", -1))
	var actor := String(entry.get("actor", "player"))
	var data: Dictionary = entry.get("data", {})
	var props := _base(cycle, actor)
	match category:
		"build":
			props["node_id"] = node_id
			props["tier"] = _tier_of(node_id)
			props["building"] = String(data.get("building", ""))
			props["owned"] = int(data.get("owned", 0))
		"upgrade":
			props["node_id"] = node_id
			props["tier"] = _tier_of(node_id)
			props["upgrade"] = String(data.get("upgrade", ""))
		"promotion":
			var node := _node(node_id)
			props["node_id"] = node_id
			props["tier"] = int(data.get("tier", node.tier if node != null else -1))
			props["subtree_pop"] = node.total_pop if node != null else 0.0
		"found":
			props["node_id"] = node_id
			props["parent_id"] = int(data.get("parent", -1))
			props["tier"] = int(data.get("tier", _tier_of(node_id)))
		"collapse":
			# El nodo ya se ha borrado cuando llega esto: el tier viaja en `data`.
			props["node_id"] = node_id
			props["tier"] = int(data.get("tier", -1))
		"ascension":
			# Llega **antes** de que `Main` adopte el mundo nuevo: el estado del motor todavía
			# es el de la era que se deja, y de él sale `peak_pop`. `era` es la nueva.
			props["era"] = int(data.get("era", props["era"]))
			props["gained"] = float(data.get("gained", 0.0))
			props["peak_tier"] = int(data.get("peak_tier", 0))
			props["peak_pop"] = _engine.state.peak_pop if _engine.state != null else 0.0
		"legacy":
			props["id"] = String(data.get("id", ""))
		"governor":
			# Lo emite `Main` al delegar o retomar el mando; lo decide el jugador.
			var node := _node(node_id)
			props["node_id"] = node_id
			props["tier"] = node.tier if node != null else -1
			props["delegated"] = bool(data.get("delegated", false))
			props["pop"] = node.pop if node != null else 0.0
			Augur.track("delegation", props)
			return
		# 🛒 Objetos (`Shop`). Salen como el resto, del log: `Shop` no sabe que hay analítica.
		SimEventLog.ITEM_BOUGHT:
			props["node_id"] = node_id
			props["tier"] = _tier_of(node_id)
			props["item"] = String(data.get("item", ""))
			props["good"] = String(data.get("good", ""))
			props["price"] = float(data.get("price", 0.0))
		SimEventLog.ITEM_USED:
			props["node_id"] = node_id
			props["tier"] = _tier_of(node_id)
			props["item"] = String(data.get("item", ""))
			props["nodes"] = int(data.get("nodes", 0))
			props["all"] = bool(data.get("all", false))
		SimEventLog.ITEM_DRIPPED:
			props["item"] = String(data.get("item", ""))
		_:
			return
	Augur.track(category, props)


## El rastro del gobernador. `GovernorSys._trace_decision` ya lo arma plano y solo cuando el
## checkpoint hizo algo; aquí se le añade lo común y sale tal cual. No pasa por `push`, así que
## el diario del dock no lo ve nunca.
func _on_traced(kind: String, cycle: float, _node_id: int, data: Dictionary) -> void:
	if _offline:
		# Una decisión es un checkpoint que hizo algo (`GovernorSys._trace_decision`): se cuenta,
		# no se manda. Solo llega con el rastro encendido, que es lo mismo que con consentimiento.
		if kind == "governor_decision":
			_off_decisions += 1
		return
	if not _sending():
		return
	var props := data.duplicate()
	props["era"] = _engine.state.era if _engine.state != null else 0
	props["cycle"] = cycle
	props["channel"] = channel
	Augur.track(kind, props)


## Velocidad elegida por el jugador. `Main` lo llama desde `_on_speed`, que es solo la ruta del
## HUD: el ×0 del modal de consentimiento va directo al motor y no pasa por aquí.
func on_speed(index: int) -> void:
	if not _sending():
		return
	var props := _base(_engine.state.cycle, "player")
	props["index"] = index
	Augur.track("speed", props)


## Un retoque de la política del gobernador. No se manda aún: se rearma la espera, y sale la que
## quede cuando el jugador lleve `POLICY_SETTLE_S` sin tocar nada. El temporizador corre en
## pausa (`PROCESS_MODE_ALWAYS`) porque retocar la política con el juego parado es lo normal.
func on_policy_changed(node: SimNode) -> void:
	if not _sending() or node == null:
		return
	if _policy_node >= 0 and _policy_node != node.id:
		_flush_policy()
	_policy_node = node.id
	if _policy_timer == null:
		_policy_timer = Timer.new()
		_policy_timer.one_shot = true
		_policy_timer.process_mode = Node.PROCESS_MODE_ALWAYS
		_policy_timer.timeout.connect(_flush_policy)
		add_child(_policy_timer)
	_policy_timer.start(POLICY_SETTLE_S)


## Manda la política pendiente, la que tiene el nodo **ahora**. Si entretanto se retomó el mando
## o el nodo desapareció, no hay política que contar.
func _flush_policy() -> void:
	if _policy_node < 0:
		return
	var node := _node(_policy_node)
	_policy_node = -1
	if _policy_timer != null:
		_policy_timer.stop()
	if node == null or node.governor == null or not enabled or not Augur.has_consent():
		return
	var g := node.governor
	var w := g.normalized()
	var props := _base(_engine.state.cycle, "player")
	props["node_id"] = node.id
	props["w_food"] = w[GovernorSys.P_FOOD]
	props["w_growth"] = w[GovernorSys.P_GROWTH]
	props["w_industry"] = w[GovernorSys.P_INDUSTRY]
	props["w_expansion"] = w[GovernorSys.P_EXPANSION]
	props["may_build"] = g.may_build
	props["may_research"] = g.may_research
	props["may_promote"] = g.may_promote
	props["may_expand"] = g.may_expand
	Augur.track("governor_policy", props)


# ---------------------------------------------------------------------------
# Fotos de nodo: el estado de cada nodo cada 300 ciclos
# ---------------------------------------------------------------------------

func _bucket(cycle: float) -> int:
	return int(floor(cycle / SAMPLE_EVERY))


## Cada tick del motor. Solo hace algo al pasar a un múltiplo de `SAMPLE_EVERY` **más alto** que
## el último: si un tick cruza varios, sale una sola foto, porque el estado que se fotografía es
## el mismo. El contador se mueve aunque no se mande (sin consentimiento, en barra): una foto
## pendiente no se arrastra hasta que vuelva a poder mandarse.
func _on_cycle_advanced(cycle: float) -> void:
	var bucket := _bucket(cycle)
	if bucket <= _sample_bucket:
		return
	_sample_bucket = bucket
	if _sending():
		_sample_nodes()


## Estado nuevo: el contador vuelve al múltiplo del ciclo con el que llega, sin mandar nada. Es
## lo que pasa al ascender, donde el ciclo vuelve a 0.
func _on_state_replaced(state: WorldState) -> void:
	_sample_bucket = _bucket(state.cycle) if state != null else 0


## Una foto por nodo vivo, en el orden determinista del motor. **Solo lee**: lo que no está
## guardado en el nodo se deriva con las mismas funciones que la simulación y el gobernador
## (`Integrator.snapshot`, `idle_population`, `storage_caps`), nunca con una cuenta aparte que
## pudiera enseñar otra cosa. La única escritura posible es la caché de efectos de mejora del
## nodo (`SimNode.effects()`), que el tick ya ha rellenado antes de emitir `cycle_advanced`; no
## se guarda ni entra en `state_hash`, y la misma llamada la hacen el HUD y el gobernador.
func _sample_nodes() -> void:
	var state := _engine.state
	var params := _engine.params
	if state == null:
		return
	for id in state.ordered_ids():
		var node := state.get_node_by_id(id)
		Augur.track("node_sample", _node_sample(state, node, params))


## Las props de una foto. Planas y con escalares copiados.
func _node_sample(state: WorldState, node: SimNode, params: SimParams) -> Dictionary:
	# Sin mods. `GovernorSys._decide` sí los lleva (legado × peaje, desde el plan «Balance de la
	# era»), así que en un nodo delegado el `cap` y el `limit` de esta foto pueden no coincidir
	# con los de `governor_decision`: aquí se mira la economía sin multiplicadores, allí la que se
	# integra. Quien compare los dos eventos tiene que contar con esa diferencia.
	var snap := Integrator.snapshot(node, params)
	var idle := Integrator.idle_population(node)
	var props := _base(state.cycle, "system")
	# Una foto no la decide nadie: el contrato no lleva `actor`.
	props.erase("actor")
	props["node_id"] = node.id
	props["tier"] = node.tier
	props["depth"] = GovernorSys._depth(state, node)
	props["delegated"] = node.is_delegated()
	props["children"] = node.children.size()
	props["pop"] = node.pop
	props["cap"] = snap.cap
	props["housing"] = snap.housing
	# `INF` cuando la comida no limita (`Integrator._food_capacity`), y el JSON no tiene infinito:
	# sale -1, «la comida no pone techo». Un número grande inventado se colaría en las medias.
	props["food_cap"] = snap.food_capacity if is_finite(snap.food_capacity) else -1.0
	props["limit"] = _limit(node, snap)
	props["idle"] = idle
	props["buildings"] = node.building_total()
	var caps := node.storage_caps(params)
	for good in [Goods.FOOD, Goods.WOOD, Goods.STONE, Goods.TOOLS, Goods.GOLD]:
		var top: float = caps[good]
		props["fill_" + Goods.IDS[good]] = node.stocks[good] / top \
			if is_finite(top) and top > 0.0 else 0.0
	# La cultura no tiene tope (`Goods.UNCAPPED`): va el stock, no un llenado.
	props["culture"] = node.stocks[Goods.CULTURE]
	# Un oficio por edificio del tier, con o sin puestos: un tablero no puede distinguir «cero
	# destinados» de «no venía en la foto».
	for bi in Content.buildings_for_tier(node.tier):
		props["jobs_" + Content.building(bi).id] = node.jobs[bi] if bi < node.jobs.size() else 0.0
	# Derivadas ya calculadas, porque los `where` y las métricas de Augur solo operan sobre props
	# del mismo evento (tableros «Techo alcanzado» y «Ociosos: IA vs. a mano»).
	props["cap_use"] = node.pop / snap.cap if snap.cap > 0.0 else 0.0
	props["idle_share"] = idle / node.pop if node.pop > 0.0 else 0.0
	return props


## Qué frena al nodo, con **el mismo criterio** que `governor_decision`
## (`GovernorSys._trace_decision`): comida si es ella la que pone el techo; alojamiento si la
## población ya está pegada a él (`GovernorSys.TRACE_AT_CAP`, el mismo umbral, no otro); si no,
## nada.
func _limit(node: SimNode, snap: Integrator.Snapshot) -> String:
	if snap.food_limited:
		return "food"
	if node.pop >= snap.cap * GovernorSys.TRACE_AT_CAP:
		return "housing"
	return "none"


# ---------------------------------------------------------------------------
# La vuelta: una ausencia, un evento
# ---------------------------------------------------------------------------

## `Main` pone la barra de vuelta. Desde aquí y hasta `end_offline` no sale nada suelto: se
## cuenta. Sin clave no hay nada que contar (ni siquiera está conectado el puente), y en
## captura `attach` no se llama: las dos cosas dejan esto en nada.
func begin_offline(away_seconds: float) -> void:
	if not enabled or _engine == null or _engine.state == null:
		return
	_offline = true
	_away_s = away_seconds
	_off_founded = 0
	_off_promoted = 0
	_off_decisions = 0
	_off_collapsed = 0
	_off_delegated = 0
	for id in _engine.state.ordered_ids():
		if _engine.state.get_node_by_id(id).is_delegated():
			_off_delegated += 1


## Lo que el log dice de la ausencia, contado. `founded` y `promoted` son los del gobernador
## (sin jugador delante, nadie más funda ni promociona). `collapse` lo emite el motor como
## `system`, también durante la acreditación (`SimEngine._prune`). `famine` no se cuenta ni se
## manda: es un aviso para el diario, no una métrica.
func _count_offline(entry: Dictionary) -> void:
	var category := String(entry.get("category", ""))
	var by_governor := String(entry.get("actor", "")) == "governor"
	match category:
		"found":
			if by_governor:
				_off_founded += 1
		"promotion":
			if by_governor:
				_off_promoted += 1
		"collapse":
			_off_collapsed += 1


## `Main` quita la barra con el informe de vuelta en la mano. Sale **un** `offline_return`.
##
## `built` y `upgraded` salen del mismo `OfflineReport` que enseña la pantalla
## (`buildings_built`, `upgrades_bought`), no de contar `build` en el log: el informe compara
## fotos del estado, así que también cuenta las dos cabañas con las que nace cada colonia
## fundada, y la cifra del tablero tiene que ser la que leyó el jugador. Sin consentimiento no
## hay sesión y no se manda nada, pero el estado de barra se baja igual.
func end_offline(report: OfflineReport) -> void:
	if not _offline:
		return
	_offline = false
	if report == null or not enabled or not Augur.has_consent() or _engine.state == null:
		return
	var props := _base(_engine.state.cycle, "system")
	props.erase("actor")
	props["away_s"] = _away_s
	props["credited_s"] = report.seconds_credited
	props["capped"] = report.capped
	props["nodes_delegated"] = _off_delegated
	props["pop_before"] = report.pop_before
	props["pop_after"] = report.pop_after
	props["built"] = report.buildings_built
	props["upgraded"] = report.upgrades_bought
	props["founded"] = _off_founded
	props["promoted"] = _off_promoted
	props["decisions"] = _off_decisions
	props["collapsed"] = _off_collapsed
	Augur.track("offline_return", props)


## En móvil la app puede morir en segundo plano sin aviso de cierre, y en escritorio perder el
## foco suele ser el preludio de cerrar: se sube lo pendiente sin esperar a los 10 s del SDK,
## política a medio asentar incluida.
func _notification(what: int) -> void:
	if not enabled:
		return
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_flush_policy()
		Augur.flush()
