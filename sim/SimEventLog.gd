class_name SimEventLog
extends RefCounted

## Ring buffer de eventos + volcado JSONL a `user://logs/`. Alimenta el feed de la UI y deja
## rastro analizable de una partida. Los tests lo crean con `enabled = false`.

signal event_pushed(entry: Dictionary)

const CAPACITY := 256

var enabled: bool = true
var write_files: bool = false
var entries: Array[Dictionary] = []

var _files: Dictionary = {}


func push(category: String, cycle: float, node_id: int, text: String, data: Dictionary = {}) -> void:
	if not enabled:
		return
	var entry := {
		"category": category,
		"cycle": cycle,
		"node": node_id,
		"text": text,
		"data": data,
	}
	entries.append(entry)
	if entries.size() > CAPACITY:
		entries = entries.slice(entries.size() - CAPACITY)
	event_pushed.emit(entry)
	if write_files:
		_write(category, entry)


func recent(count: int) -> Array[Dictionary]:
	if entries.size() <= count:
		return entries.duplicate()
	return entries.slice(entries.size() - count)


func clear() -> void:
	entries.clear()


func _write(category: String, entry: Dictionary) -> void:
	if not _files.has(category):
		DirAccess.make_dir_recursive_absolute("user://logs")
		var f := FileAccess.open("user://logs/%s.jsonl" % category, FileAccess.WRITE_READ)
		if f == null:
			write_files = false
			return
		f.seek_end()
		_files[category] = f
	var file: FileAccess = _files[category]
	file.store_line(JSON.stringify(entry))


func flush() -> void:
	for f in _files.values():
		(f as FileAccess).flush()
