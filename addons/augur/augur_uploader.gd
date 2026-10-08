extends RefCounted

# Subida del SDK de Augur: arma lotes con lo pendiente en disco, los manda a POST /v1/batch y
# aplica la tabla de respuestas del plan. Sin class_name (lo carga augur.gd con preload).
#
# 🔴 El transporte se INYECTA: un Callable
#     transport.call(url: String, headers: PackedStringArray, body: String, done: Callable) -> int
# que devuelve OK si lanzó la petición (y más tarde llama a
#     done.call(result: int, code: int, headers: PackedStringArray, body: PackedByteArray|String)
# con los mismos argumentos que HTTPRequest.request_completed) o un error si no pudo lanzarla (y
# entonces no llama a done). En el juego envuelve el HTTPRequest hijo del autoload; en la suite
# es un falso que contesta el código que toque, así que toda la tabla se prueba sin red.
#
# Tabla de respuestas:
#   200                  acked[sesión] = último seq enviado; borra las terminadas y subidas
#   400 invalid_payload  push_error con el detail y descarta las sesiones del lote
#   400 no_consent       push_error, no se borra nada
#   401                  push_error y deja de subir en este arranque; los datos se quedan
#   413                  parte el lote por la mitad y reintenta; un evento solo → como 400
#   429                  espera Retry-After (o 60 s)
#   5xx / red / otro     espera 10 → 20 → 40 → … → 300 s; un 200 la devuelve a 10 s

signal response_handled(code: int, info: Dictionary)

const MAX_EVENTS := 1500                 # margen bajo los 2.000 del servidor
const MAX_BYTES := 400 * 1024            # margen bajo los 512 KB del servidor
const MAX_SESSIONS := 50                 # BatchValidator::MAX_SESSIONS
const BASE_DELAY_S := 10
const MAX_DELAY_S := 300
const DEFAULT_RETRY_AFTER_S := 60
const RESULT_SUCCESS := 0                # HTTPRequest.RESULT_SUCCESS
const RESULT_NOT_SENT := -1              # el transporte no pudo ni lanzar la petición

var _store                               # AugurStore
var _transport: Callable
var _url := ""
var _write_key := ""
var _sdk := ""
var _install_id := ""

var _in_flight := false
var _stopped := false                    # 401: no se sube más en este arranque
var _wait_until_ms := 0
var _backoff_s := BASE_DELAY_S
var _event_limit := MAX_EVENTS           # baja tras un 413, vuelve a MAX_EVENTS con un 200
var _batch: Array = []                   # [{session_id, path, last_seq, final}]
var _batch_events := 0
var _generation := 0                     # cancel() invalida la respuesta en vuelo

# Solo lectura para la suite y para integration_dev.gd.
var last_wait_s := 0
var requests_sent := 0
var _clock_ms := -1                      # >= 0: reloj falso de la suite


func _init(store, transport: Callable, endpoint: String, write_key: String, sdk: String, install_id: String) -> void:
	_store = store
	_transport = transport
	_url = endpoint.rstrip("/") + "/v1/batch"
	_write_key = write_key
	_sdk = sdk
	_install_id = install_id


# Lanza una subida si toca. No hace nada si hay una petición en vuelo (una como mucho), si un 401
# la paró, si se está esperando (429 / backoff) o si no hay nada pendiente. Devuelve si lanzó.
# `ignore_wait` (solo el cierre de la ventana) salta la espera del 429 / backoff, nunca el 401.
func upload(ignore_wait: bool = false) -> bool:
	if _stopped or _in_flight or (not ignore_wait and _now_ms() < _wait_until_ms):
		return false
	var built := build_batch(_event_limit)
	if built.is_empty():
		return false
	_batch = built.sessions
	_batch_events = built.events
	_in_flight = true
	requests_sent += 1
	var gen := _generation
	var headers := PackedStringArray(["Content-Type: application/json", "X-Augur-Key: " + _write_key])
	var done := func(result: int, code: int, resp_headers, body) -> void:
		_on_done(gen, result, code, resp_headers, body)
	var err: int = _transport.call(_url, headers, built.body, done)
	if err != OK:
		_on_done(gen, RESULT_NOT_SENT, 0, PackedStringArray(), "")
	return true


func is_in_flight() -> bool:
	return _in_flight


func is_stopped() -> bool:
	return _stopped


# Olvida la petición en vuelo (revocar el consentimiento borra lo que iba en ella).
func cancel() -> void:
	_generation += 1
	_in_flight = false
	_batch = []


# --- armado del lote -----------------------------------------------------------------------

# Por cada sesión en disco (de la más vieja a la más nueva por started_at), los eventos con
# seq > acked y su ended_at si lo tiene y el lote llega a su último evento. Corta en `limit`
# eventos, MAX_BYTES de JSON y MAX_SESSIONS sesiones. Los eventos van con su línea original.
# Una sesión terminada sin nada pendiente se borra aquí. Devuelve {} si no hay nada que subir, o
# {"body", "sessions": [{session_id, path, last_seq, final}], "events"}.
func build_batch(limit: int) -> Dictionary:
	var parsed: Array = []
	var on_disk := {}
	for path in _store.list_session_files():
		var recs: Array = _store.read_records(path)
		if recs.is_empty() or not recs[0].data.has("session_id"):
			continue                             # cabecera ilegible: no se puede mandar
		var header: Dictionary = recs[0].data
		on_disk[str(header.session_id)] = true
		parsed.append({"path": path, "header": header, "recs": recs, "started_at": str(header.get("started_at", ""))})
	# Un acked sin fichero (el tope de 10 MB borró la sesión) ya no sirve de nada.
	for sid in _store.acked_ids():
		if not on_disk.has(sid):
			_store.erase_acked(sid)
	parsed.sort_custom(func(a, b):
		if a.started_at == b.started_at:
			return a.path < b.path
		return a.started_at < b.started_at)

	var prefix := "{\"consent\":true,\"sdk\":%s,\"install_id\":%s,\"sessions\":[" % [JSON.stringify(_sdk), JSON.stringify(_install_id)]
	var suffix := "]}"
	var bytes := _utf8_len(prefix) + _utf8_len(suffix)
	var parts: PackedStringArray = []
	var sessions: Array = []
	var events_total := 0
	for p in parsed:
		if sessions.size() >= MAX_SESSIONS or events_total >= limit:
			break
		var header: Dictionary = p.header
		var sid := str(header.session_id)
		var acked: int = _store.get_acked(sid)
		var pending: Array = []                   # [{seq, raw}]
		var ended_at = null
		for i in range(1, p.recs.size()):
			var d: Dictionary = p.recs[i].data
			if d.has("ended_at"):
				ended_at = d.ended_at
			elif d.has("seq") and int(d.seq) > acked:
				pending.append({"seq": int(d.seq), "raw": p.recs[i].raw})
		# Terminada = con ended_at, o huérfana de un arranque anterior (M3): una sesión que no es la
		# abierta ya no recibirá más eventos, así que subida hasta su último seq se borra aunque no
		# tenga ended_at (llega al núcleo con ended_at null = cierre brusco). Si no, se quedaría en
		# disco para siempre, releída en cada turno.
		var finished: bool = ended_at != null or sid != _store.current_session_id()
		if pending.is_empty():
			if finished and _store.delete_session(sid, p.path):
				_store.save_state()
			continue
		# Cabecera de la sesión con ended_at relleno para medir el peor caso.
		var head := _session_head(header, ended_at)
		var sep := 1 if not parts.is_empty() else 0
		var head_bytes := _utf8_len(head) + len(",\"events\":[]}") + sep
		if bytes + head_bytes > MAX_BYTES and not parts.is_empty():
			break
		var taken: PackedStringArray = []
		var taken_bytes := 0
		var last_seq := acked
		for e in pending:
			if events_total + taken.size() >= limit:
				break
			var add := _utf8_len(e.raw) + (1 if not taken.is_empty() else 0)
			var empty_batch := parts.is_empty() and taken.is_empty()
			if bytes + head_bytes + taken_bytes + add > MAX_BYTES and not empty_batch:
				break                                   # lo que no cabe va en el siguiente turno
			taken.append(e.raw)
			taken_bytes += add
			last_seq = e.seq
		if taken.is_empty():
			break
		var complete := taken.size() == pending.size()
		var final := complete and finished
		head = _session_head(header, ended_at if complete else null)
		var session_json := head.substr(0, head.length() - 1) + ",\"events\":[" + ",".join(taken) + "]}"
		parts.append(session_json)
		bytes += _utf8_len(session_json) + sep
		events_total += taken.size()
		sessions.append({"session_id": sid, "path": p.path, "last_seq": last_seq, "final": final})
	if sessions.is_empty():
		return {}
	return {"body": prefix + ",".join(parts) + suffix, "sessions": sessions, "events": events_total}


# La sesión sin eventos, serializada con JSON.stringify (termina en "}"). Solo los campos del
# contrato; un locale o build_id vacíos van como null (el validador rechaza cadenas vacías).
func _session_head(header: Dictionary, ended_at) -> String:
	var locale = header.get("locale", null)
	var build_id = header.get("build_id", null)
	var context = header.get("context", null)
	var h := {
		"session_id": str(header.session_id),
		"client_version": str(header.get("client_version", "")),
		"build_id": build_id if typeof(build_id) == TYPE_STRING and build_id.strip_edges() != "" else null,
		"platform": str(header.get("platform", "")),
		"locale": locale if typeof(locale) == TYPE_STRING and locale.strip_edges() != "" else null,
		"context": context if typeof(context) == TYPE_DICTIONARY else null,
		"started_at": str(header.get("started_at", "")),
		"ended_at": ended_at,
	}
	return JSON.stringify(h)


# --- respuestas ----------------------------------------------------------------------------

func _on_done(gen: int, result: int, code: int, headers, body) -> void:
	if gen != _generation:
		return
	_in_flight = false
	var text: String = body.get_string_from_utf8() if body is PackedByteArray else str(body)
	var info := {"result": result, "code": code, "events": _batch_events, "sessions": _batch.size()}
	var parsed = JSON.parse_string(text) if text.strip_edges().begins_with("{") else null
	var data: Dictionary = parsed if typeof(parsed) == TYPE_DICTIONARY else {}
	info["body"] = data
	var batch := _batch
	_batch = []

	if result != RESULT_SUCCESS:
		_back_off()
	elif code == 200:
		_backoff_s = BASE_DELAY_S
		_event_limit = MAX_EVENTS
		last_wait_s = 0
		_wait_until_ms = 0
		_ack(batch)
	elif code == 400 and str(data.get("error", "")) == "no_consent":
		push_error("Augur: el servidor respondió no_consent (no debería pasar); no se borra nada")
	elif code == 400:
		push_error("Augur: lote rechazado (invalid_payload): %s — se descartan sus sesiones; es un bug del SDK" % str(data.get("detail", text)))
		_discard(batch)
	elif code == 401:
		push_error("Augur: clave rotada o mal configurada (401 invalid_key); no se sube más en este arranque")
		_stopped = true
	elif code == 413:
		if batch.size() == 1 and _batch_events <= 1:
			push_error("Augur: un solo evento da 413 (batch_too_large); se descarta como un 400")
			_discard(batch)
		else:
			_event_limit = maxi(1, _batch_events / 2)
			info["split_to"] = _event_limit
			response_handled.emit(code, info)
			upload()
			return
	elif code == 429:
		var wait := _retry_after(headers)
		last_wait_s = wait
		_wait_until_ms = _now_ms() + wait * 1000
	else:
		_back_off()
	info["wait_s"] = last_wait_s
	response_handled.emit(code, info)


func _ack(batch: Array) -> void:
	for s in batch:
		_store.set_acked(s.session_id, s.last_seq)
		if s.final:
			_store.delete_session(s.session_id, s.path)
	_store.save_state()


# Reenviar un lote inválido daría el mismo 400 para siempre. Las sesiones cerradas se borran; la
# abierta no puede (su fichero sigue escribiéndose), así que se dan por subidos sus eventos.
func _discard(batch: Array) -> void:
	for s in batch:
		if s.session_id == _store.current_session_id():
			_store.set_acked(s.session_id, s.last_seq)
		else:
			_store.delete_session(s.session_id, s.path)
	_store.save_state()


func _back_off() -> void:
	last_wait_s = _backoff_s
	_wait_until_ms = _now_ms() + _backoff_s * 1000
	_backoff_s = mini(_backoff_s * 2, MAX_DELAY_S)


func _retry_after(headers) -> int:
	if headers != null:
		for h in headers:
			var line := str(h)
			if line.to_lower().begins_with("retry-after:"):
				var v := line.substr(line.find(":") + 1).strip_edges()
				if v.is_valid_int() and int(v) >= 0:
					return int(v)
	return DEFAULT_RETRY_AFTER_S


func _now_ms() -> int:
	return _clock_ms if _clock_ms >= 0 else Time.get_ticks_msec()


static func _utf8_len(s: String) -> int:
	return s.to_utf8_buffer().size()
