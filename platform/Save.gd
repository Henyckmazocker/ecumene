class_name Save
extends RefCounted

## Guardado y carga. `user://` es la única ruta que funciona igual en Steam, Android y web
## (donde Godot la respalda con IndexedDB), así que no hay una capa de guardado por
## plataforma: hay una, y las diferencias se resuelven al cerrar el archivo.
##
## El terreno **no se guarda**: se regenera desde `seed` del nodo. Un imperio entero cabe en
## unos pocos cientos de KB porque solo se serializan los agregados.
##
## **Formato binario, no JSON.** `JSON.stringify` pierde precisión en los dobles incluso con
## `full_precision`: medido, un stock de 118.64669608691045 volvía como 118.64669608691044.
## En un juego cuyo contrato es "mismo seed ⇒ misma historia", eso significa que cargar una
## partida la desvía de la que se estaba jugando. `store_var` conserva los dobles bit a bit.
## Para inspeccionar un save a mano está `export_json`, que no es el formato de guardado.

const PATH := "user://ecumene.save"
const BACKUP := "user://ecumene.save.bak"
const DEBUG_JSON := "user://ecumene.save.json"


static func exists() -> bool:
	return FileAccess.file_exists(PATH)


static func write(state: WorldState) -> bool:
	var payload := state.to_dict()
	payload["saved_at"] = Time.get_unix_time_from_system()
	payload["engine"] = Engine.get_version_info()["string"]

	# El guardado anterior se conserva: un save corrupto no puede tragarse una partida larga.
	if FileAccess.file_exists(PATH):
		var previous := FileAccess.get_file_as_bytes(PATH)
		if not previous.is_empty():
			var bak := FileAccess.open(BACKUP, FileAccess.WRITE)
			if bak != null:
				bak.store_buffer(previous)
				bak.close()

	var file := FileAccess.open(PATH, FileAccess.WRITE)
	if file == null:
		push_error("Ecumene: no se pudo escribir %s (%d)" % [PATH, FileAccess.get_open_error()])
		return false
	file.store_var(payload)
	# Cerrar explícitamente es lo que dispara el volcado a IndexedDB en el export web.
	file.close()
	return true


## Carga la partida. Devuelve `null` si no hay ninguna o está corrupta (entonces se intenta
## el respaldo). `out_elapsed` recibe los segundos reales transcurridos desde el guardado.
static func read(out_elapsed: Array = []) -> WorldState:
	var state := _read_from(PATH, out_elapsed)
	if state == null:
		state = _read_from(BACKUP, out_elapsed)
		if state != null:
			push_warning("Ecumene: save principal ilegible, se ha cargado el respaldo.")
	return state


static func _read_from(path: String, out_elapsed: Array) -> WorldState:
	if not FileAccess.file_exists(path):
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var parsed = file.get_var()
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return null
	var data: Dictionary = migrate(parsed)
	if data.is_empty():
		return null
	var saved_at := float(data.get("saved_at", 0.0))
	var elapsed := 0.0
	if saved_at > 0.0:
		elapsed = maxf(Time.get_unix_time_from_system() - saved_at, 0.0)
	out_elapsed.append(elapsed)
	return WorldState.from_dict(data)


## Vuelca el estado a JSON legible. Es para depurar y para dar soporte, **no** es el formato
## de guardado: al pasar por JSON los dobles pierden el último bit.
static func export_json(state: WorldState) -> bool:
	var file := FileAccess.open(DEBUG_JSON, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(state.to_dict(), "\t", true, true))
	file.close()
	return true


## Migraciones de esquema. Cada versión antigua se sube un escalón hasta la actual; devolver
## un diccionario vacío significa "este save es irrecuperable".
static func migrate(data: Dictionary) -> Dictionary:
	var version := int(data.get("schema", 0))
	if version > WorldState.SCHEMA_VERSION:
		push_warning("Ecumene: save de una versión más nueva (%d), no se carga." % version)
		return {}
	while version < WorldState.SCHEMA_VERSION:
		match version:
			_:
				push_warning("Ecumene: sin migración desde el esquema %d." % version)
				return {}
	return data


static func erase() -> void:
	for path in [PATH, BACKUP]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
