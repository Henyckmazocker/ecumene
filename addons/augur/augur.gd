extends Node

# SDK de Augur para Godot. Se registra como autoload `Augur` (sin class_name: chocaría con el
# nombre del autoload). Guarda en local y sube después: cada 10 s, con flush() y en configure().
#
# 🔴 _ready() no hace NADA observable: el autoload se carga también cuando un juego corre su
# suite con --script (M0). Todo arranca en configure(), y sin consentimiento no se escribe nada.
#
# Los ayudantes se cargan con preload y no tienen class_name, para que copiar addons/augur/ a
# un juego no le meta nombres globales.

const AugurStamp := preload("augur_stamp.gd")
const AugurStore := preload("augur_store.gd")
const AugurUploader := preload("augur_uploader.gd")

# Se emite al pedir cerrar la ventana con sesión abierta, ANTES de session_end: lo que el juego
# trackee aquí (p. ej. el run_end de una run viva) entra en la sesión antes de cerrarla. El
# autoload recibe la notificación antes que la escena del juego, así que el juego no puede
# escuchar el cierre por su cuenta y llegar a tiempo.
signal closing

const SDK_VERSION := "0.1.0"                       # va en el campo "sdk" como "godot/0.1.0"
const DEFAULT_ROOT := "user://augur/"
const MAX_NAME_LENGTH := 64
const MAX_LOCALE_LENGTH := 16
const DISK_CAP_BYTES := 10 * 1024 * 1024
const UPLOAD_INTERVAL_S := 10.0
const HTTP_TIMEOUT_S := 10.0
const CLOSE_TIMEOUT_S := 2.0                       # techo para retener la ventana al cerrar

var _root := DEFAULT_ROOT
var _cap_bytes := DISK_CAP_BYTES
var _configured := false
var _write_key := ""
var _endpoint := ""
var _client_version := ""
var _build_id := ""
var _install_id := ""
var _store = null                                  # AugurStore
var _session_id := ""
var _seq := 0
var _session_ticks := 0
var _uploader = null                               # AugurUploader
var _timer: Timer = null
var _http: HTTPRequest = null
var _http_done := Callable()
var _transport_override := Callable()              # solo la suite
var _close_timer: Timer = null
var _close_timeout_s := CLOSE_TIMEOUT_S
var _closing := false                              # WM_CLOSE_REQUEST recibido
var _close_sent := false                           # ya salió la subida del cierre
var _quit_done := false
var _quit_override := Callable()                   # solo la suite: sustituye a get_tree().quit()


# 🔴 PROCESS_MODE_ALWAYS en el nodo, en su Timer y en su HTTPRequest: el juego pausa el árbol al
# acabar una run y en cada pantalla de mejora, y con el modo por defecto la subida se congelaría
# justo cuando hay más eventos. Se pone en _init() y no en _ready(), que no hace nada (ver arriba).
func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


# --- API pública ---------------------------------------------------------------------------

# endpoint = origen sin barra final: "http://localhost:8897" o "https://augur.dcahomelab.com".
# Calcula el sello, carga state.cfg y, si ya hay consentimiento, abre sesión y sube lo pendiente.
# El Timer y el HTTPRequest se crean AQUÍ como hijos, nunca más tarde: un add_child() dentro del
# manejador de cierre falla con el padre ocupado (M0).
func configure(write_key: String, endpoint: String) -> void:
	if _configured:
		push_warning("Augur: configure() ya se llamó; se ignora")
		return
	_configured = true
	_write_key = write_key
	_endpoint = endpoint.rstrip("/")
	_client_version = AugurStamp.client_version()
	_build_id = AugurStamp.build_id()
	_store = AugurStore.new(_root)
	_store.load_state()
	_install_id = _store.get_install_id()
	if _install_id == "":
		_install_id = _uuid4()
		_store.set_install_id(_install_id)
		# Solo se persiste si ya existe una decisión en disco: sin consentimiento no se escribe
		# nada. Si no, el install_id se guarda con la primera set_consent().
		if _store.state_exists():
			_store.save_state()
	_setup_upload()
	# Sube también lo que dejaron arranques anteriores: con ended_at (cerraron bien) y sin él
	# (cierre brusco: llegan con ended_at null y el núcleo lo entiende así).
	if _store.has_consent_decision() and _store.get_consent():
		_open_session()
		_start_timer()
		_uploader.upload()


# true: lo guarda y abre sesión (session_start). false: lo guarda, cierra la sesión SIN
# subirla y BORRA sessions/ entera.
func set_consent(granted: bool) -> void:
	if not _configured:
		push_warning("Augur: set_consent() antes de configure(); se ignora")
		return
	_store.set_consent(granted)
	_store.save_state()
	if granted:
		if _session_id == "":
			_open_session()
		_start_timer()
	else:
		_timer.stop()
		_timer.autostart = false
		_uploader.cancel()
		_session_id = ""
		_hold_quit(false)
		_store.clear_acked()
		_store.save_state()
		_store.delete_all_sessions()


func has_consent_decision() -> bool:
	return _configured and _store.has_consent_decision()


func has_consent() -> bool:
	return _configured and _store.has_consent_decision() and _store.get_consent()


# Sin configure() o sin consentimiento: return, sin tocar disco. Nombre vacío o de más de 64
# caracteres → push_error y se descarta. props se copia (duplicate(true)).
func track(event_name: String, props: Dictionary = {}) -> void:
	if not _configured or _session_id == "":
		return
	if event_name == "" or event_name.length() > MAX_NAME_LENGTH:
		push_error("Augur: nombre de evento vacío o de más de %d caracteres: '%s'" % [MAX_NAME_LENGTH, event_name])
		return
	var record := {
		"seq": int(_seq),
		"name": event_name,
		"ts": iso_now(),
		"elapsed_ms": int(Time.get_ticks_msec() - _session_ticks),
		"props": props.duplicate(true),
	}
	if _store.append(record):
		_seq += 1


# Sube ya lo pendiente, sin esperar a los 10 s. Respeta la petición en vuelo (una como mucho),
# la espera de un 429 o del backoff, y el 401.
func flush() -> void:
	if not _configured or _session_id == "":
		return
	_uploader.upload()


func get_install_id() -> String:
	return _install_id


# --- subida --------------------------------------------------------------------------------

func _setup_upload() -> void:
	var transport := _transport_override
	if not transport.is_valid():
		_http = HTTPRequest.new()
		_http.name = "AugurHTTP"
		_http.timeout = HTTP_TIMEOUT_S
		_http.request_completed.connect(_on_http_completed)
		add_child(_http)
		transport = _http_transport
	if _http != null:
		_http.process_mode = Node.PROCESS_MODE_ALWAYS
	_timer = Timer.new()
	_timer.name = "AugurTimer"
	_timer.wait_time = UPLOAD_INTERVAL_S
	_timer.one_shot = false
	_timer.process_mode = Node.PROCESS_MODE_ALWAYS
	_timer.timeout.connect(_on_upload_timer)
	add_child(_timer)
	# El techo del cierre también se crea aquí: dentro de WM_CLOSE_REQUEST no se añaden nodos.
	_close_timer = Timer.new()
	_close_timer.name = "AugurCloseTimer"
	_close_timer.one_shot = true
	_close_timer.process_mode = Node.PROCESS_MODE_ALWAYS
	_close_timer.timeout.connect(_on_close_timeout)
	add_child(_close_timer)
	_uploader = AugurUploader.new(_store, transport, _endpoint, _write_key, "godot/" + SDK_VERSION, _install_id)
	_uploader.response_handled.connect(_on_upload_response)


# Fuera del árbol (la suite) un Timer no arranca: autostart lo arranca al entrar.
func _start_timer() -> void:
	if _timer.is_inside_tree():
		_timer.start()
	else:
		_timer.autostart = true


func _on_upload_timer() -> void:
	if _session_id != "":
		_uploader.upload()


# El transporte del juego: el HTTPRequest hijo. Una petición a la vez (el uploader lo garantiza).
func _http_transport(url: String, headers: PackedStringArray, body: String, done: Callable) -> int:
	if _http_done.is_valid():
		return ERR_BUSY
	_http_done = done
	var err := _http.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		_http_done = Callable()
	return err


func _on_http_completed(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	var done := _http_done
	_http_done = Callable()
	if done.is_valid():
		done.call(result, code, headers, body)


# --- sesión --------------------------------------------------------------------------------

func _open_session() -> void:
	var session_id := _uuid4()
	var header := {
		"session_id": session_id,
		"client_version": _client_version,
		"build_id": _build_id,
		"platform": OS.get_name().to_lower(),
		"locale": OS.get_locale().substr(0, MAX_LOCALE_LENGTH),
		"context": _context(),
		"started_at": iso_now(),
	}
	if not _store.open_session(session_id, header):
		return
	_session_id = session_id
	_seq = 0
	_session_ticks = Time.get_ticks_msec()
	_store.enforce_cap(_cap_bytes, session_id)
	track("session_start")
	_hold_quit(true)


func _context() -> Dictionary:
	var size := DisplayServer.window_get_size()
	return {
		"screen": "%dx%d" % [size.x, size.y],
		"godot": str(Engine.get_version_info().string),
	}


# --- cierre --------------------------------------------------------------------------------
#
# Solo con sesión abierta se retiene el cierre (auto_accept_quit = false). Al pedir cerrar la
# ventana: session_end, ended_at, una subida, y quit() al responder O a los 2 s, lo que llegue
# antes. Sin sesión, auto_accept_quit no se toca y el cierre es el de siempre. Si el juego sale
# con get_tree().quit() no hay notificación: la sesión queda sin ended_at y se sube en el
# siguiente arranque como cierre brusco.

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_on_close_request()
	elif what == NOTIFICATION_EXIT_TREE and _session_id != "":
		_hold_quit(false)                          # quien retuvo el cierre lo suelta al irse
	elif what == NOTIFICATION_PREDELETE and _store != null:
		_store.close_session()


# Retiene (o suelta) el cierre de la ventana. Fuera del árbol (instancias de la suite) no hay
# SceneTree que tocar. Soltar solo lo hace quien lo retuvo.
func _hold_quit(hold: bool) -> void:
	if not is_inside_tree():
		return
	get_tree().auto_accept_quit = not hold


func _on_close_request() -> void:
	if _closing or not _configured or _session_id == "":
		return                                     # sin sesión: auto_accept_quit ya es true
	_closing = true
	var t0 := Time.get_ticks_msec()
	closing.emit()
	track("session_end")
	_store.append({"ended_at": iso_now()})
	# Cerrar el fichero la deja como sesión terminada: el 200 la borra del disco.
	_store.close_session()
	_session_id = ""
	_timer.stop()
	print_verbose("Augur: cierre pedido t=%d ms" % t0)
	if _close_timer.is_inside_tree():
		_close_timer.start(_close_timeout_s)
	# Si hay una petición en vuelo se espera a su respuesta (_on_upload_response lanza la final).
	# upload(true) no respeta la espera de un 429 o del backoff: es la última oportunidad.
	if _uploader.is_in_flight():
		return
	if _uploader.upload(true):
		_close_sent = true
	else:
		_quit("nada que subir")


func _on_upload_response(code: int, _info: Dictionary) -> void:
	if not _closing or _quit_done:
		return
	if _uploader.is_in_flight():
		return
	# Se lanza otra mientras quede tiempo si la que respondió era anterior al cierre, si un 200
	# deja más pendiente (> 1.500 eventos) o si un 413 pide medio lote; si no, se sale.
	if (not _close_sent or code == 200 or code == 413) and _uploader.upload(true):
		_close_sent = true
		return
	_quit("respuesta %d" % code)


func _on_close_timeout() -> void:
	if _closing:
		_quit("techo de %.1f s" % _close_timeout_s)


func _quit(why: String) -> void:
	if _quit_done:
		return
	_quit_done = true
	if _close_timer != null and _close_timer.is_inside_tree():
		_close_timer.stop()
	print_verbose("Augur: quit por %s" % why)
	if _quit_override.is_valid():
		_quit_override.call(why)
	elif is_inside_tree():
		get_tree().quit()


# --- utilidades ----------------------------------------------------------------------------

# ISO-8601 UTC con milisegundos y Z: Time.get_datetime_string_from_system() no los lleva.
static func iso_now() -> String:
	return iso_from_unix(Time.get_unix_time_from_system())


static func iso_from_unix(unix: float) -> String:
	var secs := int(floor(unix))
	var ms := clampi(int((unix - secs) * 1000.0), 0, 999)
	var d := Time.get_datetime_dict_from_unix_time(secs)
	return "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ" % [d.year, d.month, d.day, d.hour, d.minute, d.second, ms]


# UUID v4 desde 16 bytes aleatorios con los bits de versión (4) y variante (10xx).
static func _uuid4() -> String:
	var b := Crypto.new().generate_random_bytes(16)
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	var h := b.hex_encode()
	return "%s-%s-%s-%s-%s" % [h.substr(0, 8), h.substr(8, 4), h.substr(12, 4), h.substr(16, 4), h.substr(20, 12)]


# --- solo para la suite ----------------------------------------------------------------------

# Cambia la raíz de disco (user://augur_test_<n>/) y el tope. Antes de configure().
func _set_test_root(root: String, cap_bytes: int = DISK_CAP_BYTES) -> void:
	_root = root
	_cap_bytes = cap_bytes


# Transporte falso (ver augur_uploader.gd). Antes de configure().
func _set_test_transport(transport: Callable) -> void:
	_transport_override = transport


# Sustituye a get_tree().quit() en el cierre (la suite no puede salir) y acorta el techo.
func _set_test_quit(on_quit: Callable, close_timeout_s: float = CLOSE_TIMEOUT_S) -> void:
	_quit_override = on_quit
	_close_timeout_s = close_timeout_s


func _current_session_file() -> String:
	return _store.session_file(_session_id) if _store != null and _session_id != "" else ""
