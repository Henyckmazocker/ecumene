class_name SimEventLog
extends RefCounted

## Ring buffer de eventos. Alimenta el feed de la UI y, con `write_files`, vuelca además un JSONL
## por categoría a `user://logs/` para depurar una partida —qué decidió un gobernador durante una
## ausencia—. El volcado solo se enciende con `--event-log` (`Main._ready`): es para leer, no para
## cargar, y no tiene nada que ver con el save. Los tests lo crean con `enabled = false`.

signal event_pushed(entry: Dictionary)
## Rastro de lo que **no** es un hecho de la partida sino el porqué de uno: hoy, las decisiones
## del gobernador. Va por su propio canal y nunca entra en `entries`, porque el diario del dock
## pinta todo lo que pasa por `push` (`Main._on_event`) y el jugador no tiene por qué leer las
## puntuaciones de la IA.
signal traced(kind: String, cycle: float, node_id: int, data: Dictionary)

const CAPACITY := 256

## Categorías de los objetos (`Shop`, plan «Objetos de tiempo»). Las demás categorías son literales
## en quien las anota; estas tres viven aquí porque las comparten `Shop`, `Analytics` y los tests.
## `item_bought {item, good, price}` · `item_used {item, nodes, all}` · `item_dripped {item}`.
const ITEM_BOUGHT := "item_bought"
const ITEM_USED := "item_used"
const ITEM_DRIPPED := "item_dripped"

var enabled: bool = true
var write_files: bool = false
var entries: Array[Dictionary] = []

## Quién está actuando **ahora**: `player`, `governor` o `system`. Es un actor de ámbito y no un
## parámetro porque así ninguna firma cambia: `Construction.build`, `Upgrading.buy` y
## `Promotion` siguen siendo la ruta única para el jugador y para la IA (regla 3), y quien
## conduce —`GovernorSys.run`, `SimEngine`— pone el actor, llama y lo restaura. Vive en el log,
## no en el modelo: no entra en el save ni en `state_hash`.
var actor: String = "player"

## Si `trace()` emite. Apagado por defecto: solo la analítica lo enciende. Quien arma un registro
## de rastro lo mira **antes** de calcularlo, para que con el rastro apagado no cueste nada.
var tracing: bool = false

var _files: Dictionary = {}
## Categorías cuyo JSONL ya se abrió en esta sesión. La primera apertura trunca —cada sesión
## empieza su rastro—; las siguientes, tras un `flush` que cerró el fichero, añaden al final.
var _started: Dictionary = {}


func push(category: String, cycle: float, node_id: int, text: String, data: Dictionary = {}) -> void:
	if not enabled:
		return
	var entry := {
		"category": category,
		"cycle": cycle,
		"node": node_id,
		"text": text,
		"data": data,
		"actor": actor,
	}
	entries.append(entry)
	if entries.size() > CAPACITY:
		entries = entries.slice(entries.size() - CAPACITY)
	event_pushed.emit(entry)
	if write_files:
		_write(category, entry)


## Emite un registro de rastro. **No** toca `entries` ni el JSONL: es lo que mantiene las
## decisiones del gobernador fuera del diario. `data` lleva solo escalares copiados, nunca
## referencias a objetos de la simulación.
func trace(kind: String, cycle: float, node_id: int, data: Dictionary) -> void:
	if tracing:
		traced.emit(kind, cycle, node_id, data)


func recent(count: int) -> Array[Dictionary]:
	if entries.size() <= count:
		return entries.duplicate()
	return entries.slice(entries.size() - count)


func clear() -> void:
	entries.clear()


func _write(category: String, entry: Dictionary) -> void:
	if not _files.has(category):
		DirAccess.make_dir_recursive_absolute("user://logs")
		var path := "user://logs/%s.jsonl" % category
		# `READ_WRITE` no trunca, pero tampoco crea: solo sirve para reabrir lo de esta sesión.
		var mode := FileAccess.READ_WRITE if _started.has(category) else FileAccess.WRITE
		var f := FileAccess.open(path, mode)
		if f == null:
			write_files = false
			return
		f.seek_end()
		_files[category] = f
		_started[category] = true
	var file: FileAccess = _files[category]
	file.store_line(JSON.stringify(entry))


## Cierra los ficheros, no solo los vacía: en el export web es cerrar lo que vuelca
## `user://` a IndexedDB (lo mismo que `Save.write`). El siguiente `push` los reabre al final.
func flush() -> void:
	for f in _files.values():
		(f as FileAccess).close()
	_files.clear()
