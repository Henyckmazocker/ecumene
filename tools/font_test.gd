extends SceneTree
## Ningún emoji sale como una caja con su código. Ejecutar con:
##   godot-4 --headless --path . -s res://tools/font_test.gd
##
## En escritorio, Godot tira de las fuentes del sistema para lo que la suya no tiene; en el
## navegador no hay fuentes del sistema, y la build web enseñaba cajas (`01F4CA`…) en pestañas,
## recursos, botones y oficios (Plan «Builds Públicas», M0b). La cura es Noto Color Emoji como
## reserva de la fuente del tema de proyecto (`gui/theme/custom`). Este test recorre los `.gd`
## que pintan texto, saca todo lo que no es ASCII de sus **literales** —los comentarios no se
## dibujan— y comprueba que la fuente del tema lo tiene (`Font.has_char`, que mira la fuente y
## sus fallbacks, pero **no** las del sistema: por eso en escritorio pasaría sin el fallback y
## aquí no).
##
## Se mira **por codepoint, no por grafema**: `has_char` es de un carácter, y un emoji con
## selector de variación (`⚙️` = U+2699 U+FE0F) o una secuencia ZWJ (`🧑‍🌾`) son varios. Los de
## control —U+FE0F y U+200D— no tienen glifo propio en ninguna fuente y se descartan; lo que se
## exige es que esté cada pieza visible. Que la secuencia ZWJ se componga en un solo glifo ya es
## cosa del shaping de la fuente, y Noto Color Emoji las trae.

const TestUtil := preload("res://tools/TestUtil.gd")

## Carpetas con texto que llega a pantalla. `sim/` va también porque de ahí salen los textos del
## diario y del informe de la vuelta, que la UI enseña tal cual.
const DIRS := ["res://ui", "res://data", "res://main", "res://sim"]

## Sin glifo propio: el selector de variación emoji y el «zero width joiner».
const CONTROL := [0xFE0F, 0x200D]

## Se barre todo lo que no es ASCII; luego se separa lo que es emoji (rojo si falta) de lo que no
## (solo aviso, ver abajo).
const MIN_CP := 0x80

const EMOJI_FONT := "res://assets/fonts/NotoColorEmoji.ttf"


func _init() -> void:
	var failures := 0
	var theme: Theme = load(ProjectSettings.get_setting("gui/theme/custom", ""))
	failures += TestUtil.check(theme != null and theme.default_font != null,
		"el tema de proyecto existe y tiene fuente por defecto",
		"no hay tema de proyecto (gui/theme/custom) o no tiene default_font")
	if failures > 0:
		TestUtil.finish(self, failures)
		return
	var font: Font = theme.default_font

	# codepoint → primer sitio donde aparece, para que el fallo diga dónde mirar.
	var found := {}
	var files := 0
	for dir in DIRS:
		for path in _scripts(dir):
			files += 1
			_scan(path, found)

	# Qué es emoji lo dice Noto Color Emoji cargada **a pelo**, no a través del tema: así, si se
	# quita el fallback, los emoji siguen contando como emoji y el test se pone en rojo. Lo de
	# U+1F000 en adelante es emoji aunque la fuente desapareciera del repo.
	var noto: Font = load(EMOJI_FONT) if ResourceLoader.exists(EMOJI_FONT) else null
	var emoji := 0
	var missing := PackedStringArray()
	var other_missing := PackedStringArray()
	for cp in found:
		var is_emoji: bool = cp >= 0x1F000 or (noto != null and noto.has_char(cp))
		if is_emoji:
			emoji += 1
		if font.has_char(cp):
			continue
		var where := "U+%04X «%s» (%s)" % [cp, String.chr(cp), found[cp]]
		if is_emoji:
			missing.append(where)
		else:
			other_missing.append(where)

	failures += TestUtil.check(emoji >= 20,
		"%d ficheros, %d símbolos no ASCII en literales, %d de ellos emoji" % [
			files, found.size(), emoji],
		"solo %d emoji en %d ficheros: el barrido no está leyendo los literales" % [emoji, files])
	failures += TestUtil.check(missing.is_empty(),
		"la fuente del tema tiene los %d emoji" % emoji,
		"a la fuente del tema le faltan %d emoji (en web saldrán como cajas):\n    %s" % [
			missing.size(), "\n    ".join(missing)])
	# Los símbolos que no son emoji (✓, →, ●…) y no tiene ni la fuente de Godot ni Noto Color
	# Emoji también salen como cajas en web, pero arreglarlos es otra fuente (o cambiar el
	# carácter), fuera del M0b: se avisan sin poner el test en rojo.
	for where in other_missing:
		print("AVISO: no es emoji y tampoco está en la fuente del tema: " + where)
	TestUtil.finish(self, failures)


static func _scripts(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		out.append_array(_scripts(dir.path_join(d)))
	return out


## Recorre el fuente carácter a carácter con lo justo de léxico de GDScript: dentro o fuera de
## una cadena (comillas simples, dobles o triples, con escapes), y `#` fuera de cadena como
## comentario hasta fin de línea. Solo se apunta lo que cae dentro de una cadena.
static func _scan(path: String, found: Dictionary) -> void:
	var src := FileAccess.get_file_as_string(path)
	var n := src.length()
	var i := 0
	var line := 1
	var quote := ""  # "" fuera de cadena; si no, el delimitador que la abrió
	while i < n:
		var c := src[i]
		if c == "\n":
			line += 1
		if quote == "":
			if c == "#":
				while i < n and src[i] != "\n":
					i += 1
				continue
			if c == "\"" or c == "'":
				quote = c.repeat(3) if src.substr(i, 3) == c.repeat(3) else c
				i += quote.length()
				continue
		else:
			if c == "\\":
				i += 2
				continue
			if src.substr(i, quote.length()) == quote:
				i += quote.length()
				quote = ""
				continue
			var cp := src.unicode_at(i)
			if cp >= MIN_CP and not CONTROL.has(cp) and not found.has(cp):
				found[cp] = "%s:%d" % [path.get_file(), line]
		i += 1
