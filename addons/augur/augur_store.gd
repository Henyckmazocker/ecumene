extends RefCounted

# Disco del SDK de Augur. La raíz llega por parámetro (augur.gd usa user://augur/, la suite
# user://augur_test_<n>/):
#
#   <root>/state.cfg                    [augur] install_id, consent (ausente = sin decisión)
#                                       [acked] <session_uuid> = último seq aceptado por el servidor
#   <root>/sessions/<session_uuid>.jsonl
#     línea 1: cabecera {"session_id", "client_version", "build_id", "platform", "locale",
#              "context", "started_at"}
#     línea n: {"seq", "name", "ts", "elapsed_ms", "props"}
#     última:  {"ended_at": "..."} solo si la sesión cerró bien (M3)
#
# Nada de aquí toca el disco hasta que se le pide escribir: cargar un state.cfg que no existe
# no crea la carpeta.

const STATE_FILE := "state.cfg"
const SESSIONS_DIR := "sessions"
const SESSION_EXT := "jsonl"

var root: String
var _state := ConfigFile.new()
var _file: FileAccess = null
var _session_id := ""


func _init(root_dir: String) -> void:
	root = root_dir if root_dir.ends_with("/") else root_dir + "/"


# --- state.cfg -----------------------------------------------------------------------------

func load_state() -> void:
	_state = ConfigFile.new()
	var path := root + STATE_FILE
	if FileAccess.file_exists(path):
		var err := _state.load(path)
		if err != OK:
			push_warning("Augur: no se pudo leer %s (error %d); se empieza de cero" % [path, err])
			_state = ConfigFile.new()


func state_exists() -> bool:
	return FileAccess.file_exists(root + STATE_FILE)


func save_state() -> void:
	DirAccess.make_dir_recursive_absolute(root)
	var err := _state.save(root + STATE_FILE)
	if err != OK:
		push_error("Augur: no se pudo guardar %s (error %d)" % [root + STATE_FILE, err])


func get_install_id() -> String:
	return str(_state.get_value("augur", "install_id", ""))


func set_install_id(id: String) -> void:
	_state.set_value("augur", "install_id", id)


func has_consent_decision() -> bool:
	return _state.has_section_key("augur", "consent")


func get_consent() -> bool:
	return bool(_state.get_value("augur", "consent", false))


func set_consent(granted: bool) -> void:
	_state.set_value("augur", "consent", granted)


# [acked] <session_uuid> = último seq que el servidor aceptó. Ausente = -1 (nada aceptado).
func get_acked(session_id: String) -> int:
	return int(_state.get_value("acked", session_id, -1))


func set_acked(session_id: String, seq: int) -> void:
	_state.set_value("acked", session_id, int(seq))


func erase_acked(session_id: String) -> void:
	if _state.has_section_key("acked", session_id):
		_state.erase_section_key("acked", session_id)


func acked_ids() -> PackedStringArray:
	return _state.get_section_keys("acked") if _state.has_section("acked") else PackedStringArray()


func clear_acked() -> void:
	if _state.has_section("acked"):
		_state.erase_section("acked")


# --- sesiones ------------------------------------------------------------------------------

func sessions_path() -> String:
	return root + SESSIONS_DIR + "/"


func session_file(session_id: String) -> String:
	return sessions_path() + session_id + "." + SESSION_EXT


# Crea el .jsonl con la cabecera y lo deja abierto mientras dura la sesión. WRITE la primera
# vez: READ_WRITE no crea el fichero.
func open_session(session_id: String, header: Dictionary) -> bool:
	close_session()
	DirAccess.make_dir_recursive_absolute(sessions_path())
	var f := FileAccess.open(session_file(session_id), FileAccess.WRITE)
	if f == null:
		push_error("Augur: no se pudo crear %s (error %d)" % [session_file(session_id), FileAccess.get_open_error()])
		return false
	_file = f
	_session_id = session_id
	return append(header)


# Una línea por registro, con flush(): si el juego peta se pierde como mucho la que se escribía.
func append(record: Dictionary) -> bool:
	if _file == null:
		return false
	_file.store_line(JSON.stringify(record))
	_file.flush()
	return true


func current_session_id() -> String:
	return _session_id


func close_session() -> void:
	if _file != null:
		_file.close()
	_file = null
	_session_id = ""


# Borra sessions/ entera (revocar el consentimiento). Cierra antes la sesión abierta.
func delete_all_sessions() -> void:
	close_session()
	var dir := sessions_path()
	if not DirAccess.dir_exists_absolute(dir):
		return
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir + f)
	DirAccess.remove_absolute(dir)


func list_session_files() -> PackedStringArray:
	var out: PackedStringArray = []
	var dir := sessions_path()
	if not DirAccess.dir_exists_absolute(dir):
		return out
	for f in DirAccess.get_files_at(dir):
		if f.get_extension() == SESSION_EXT:
			out.append(dir + f)
	return out


# Tope de disco sobre sessions/: borra sesiones ENTERAS, de la más vieja a la más nueva por el
# started_at de su cabecera, hasta quedar en `max_bytes` o menos. `keep_id` (la actual) no se
# borra nunca. Borrar eventos sueltos dejaría huecos de seq que parecerían pérdidas del servidor.
# Devuelve las rutas borradas.
func enforce_cap(max_bytes: int, keep_id: String) -> PackedStringArray:
	var deleted: PackedStringArray = []
	var total := 0
	var candidates: Array = []
	for path in list_session_files():
		var size := _file_size(path)
		total += size
		if path.get_file().get_basename() == keep_id:
			continue
		candidates.append({"path": path, "size": size, "started_at": _started_at(path)})
	if total <= max_bytes:
		return deleted
	# Cabecera ilegible → started_at "" → se considera la más vieja.
	candidates.sort_custom(func(a, b):
		if a.started_at == b.started_at:
			return a.path < b.path
		return a.started_at < b.started_at)
	for c in candidates:
		if total <= max_bytes:
			break
		if DirAccess.remove_absolute(c.path) == OK:
			total -= c.size
			deleted.append(c.path)
	return deleted


func sessions_size() -> int:
	var total := 0
	for path in list_session_files():
		total += _file_size(path)
	return total


# Lee un .jsonl entero. Una línea que no es JSON (un corte a mitad al petar el juego) se
# descarta con push_warning; el resto se devuelve en orden.
func read_session(path: String) -> Array:
	var out: Array = []
	for rec in read_records(path):
		out.append(rec.data)
	return out


# Como read_session(), pero cada registro lleva también su línea tal cual: {"data", "raw"}. El
# uploader manda los eventos con la línea ORIGINAL, porque JSON.parse_string() vuelve float
# todo número y reserializarlo cambiaría un {"i": 4} de props por {"i": 4.0}.
func read_records(path: String) -> Array:
	var out: Array = []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	var n := 0
	while not f.eof_reached():
		var line := f.get_line()
		n += 1
		if line.strip_edges() == "":
			continue
		var parsed = _parse(line)
		if typeof(parsed) != TYPE_DICTIONARY:
			push_warning("Augur: línea %d de %s cortada o corrupta; se descarta" % [n, path.get_file()])
			continue
		out.append({"data": parsed, "raw": line})
	return out


# Borra el .jsonl de una sesión (y su acked). `path` por defecto es <session_id>.jsonl. Nunca
# la abierta: devuelve false.
func delete_session(session_id: String, path: String = "") -> bool:
	if session_id == _session_id:
		return false
	erase_acked(session_id)
	if path == "":
		path = session_file(session_id)
	return not FileAccess.file_exists(path) or DirAccess.remove_absolute(path) == OK


func _started_at(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var parsed = _parse(f.get_line())
	if typeof(parsed) != TYPE_DICTIONARY:
		return ""
	return str(parsed.get("started_at", ""))


# JSON.new().parse() en vez de JSON.parse_string(): la línea cortada es un caso esperado y no
# debe ensuciar la salida con un ERROR del motor.
func _parse(text: String) -> Variant:
	var json := JSON.new()
	return json.data if json.parse(text) == OK else null


func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_length() if f != null else 0
