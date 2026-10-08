extends RefCounted

# Sello de versión del SDK de Augur: qué versión del juego y qué build exacto generó cada sesión.
# Sin class_name a propósito: augur.gd lo carga con preload, así que copiar addons/augur/ a un
# juego no mete nombres globales en su proyecto.

const DEV_VERSION := "0.0.0-dev"
const HASHED_EXTENSIONS := ["gd", "tscn", "json", "cfg"]
# Rutas relativas a la raíz que NO entran en el hash. addons/augur/ se excluye para que
# actualizar el SDK no cambie el build_id del juego (el SDK ya viaja en el campo "sdk").
const EXCLUDED_PREFIXES := [".godot/", "addons/augur/"]
const BUILD_ID_LENGTH := 16


# "application/config/version" del proyecto; vacío o ausente → "0.0.0-dev" (se graba igual y el
# build_id sigue distinguiendo builds).
static func client_version() -> String:
	var v := str(ProjectSettings.get_setting("application/config/version", "")).strip_edges()
	return v if v != "" else DEV_VERSION


# SHA-256 de ruta relativa + contenido de cada .gd/.tscn/.json/.cfg bajo `root`, en orden
# alfabético, sin .godot/ ni addons/augur/ → primeros 16 hex. `root` solo cambia en la suite.
static func build_id(root: String = "res://") -> String:
	if not root.ends_with("/"):
		root += "/"
	var files: PackedStringArray = []
	_collect(root, "", files)
	files.sort()
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for rel in files:
		ctx.update(rel.to_utf8_buffer())
		ctx.update(PackedByteArray([0]))
		ctx.update(FileAccess.get_file_as_bytes(root + rel))
		ctx.update(PackedByteArray([0]))
	return ctx.finish().hex_encode().substr(0, BUILD_ID_LENGTH)


static func _collect(root: String, rel_dir: String, out: PackedStringArray) -> void:
	var abs_dir := root + rel_dir
	for f in DirAccess.get_files_at(abs_dir):
		var rel: String = rel_dir + f
		if f.get_extension().to_lower() in HASHED_EXTENSIONS and not _excluded(rel):
			out.append(rel)
	for d in DirAccess.get_directories_at(abs_dir):
		var rel_sub: String = rel_dir + d + "/"
		if not _excluded(rel_sub):
			_collect(root, rel_sub, out)


static func _excluded(rel: String) -> bool:
	for p in EXCLUDED_PREFIXES:
		if rel.begins_with(p):
			return true
	return false
