extends SceneTree
## Genera el pixelart del juego. Ejecutar con:
##   godot-4 --headless --path . -s res://tools/gen_sprites.gd
##
## Escribe los PNG **una vez** en `art/`; a partir de ahí son ficheros normales del repo que se
## pueden retocar o sustituir a mano sin volver a pasar por aquí. Esto no corre en el juego.
##
## Las siluetas están **dibujadas a mano**, en rejillas de caracteres. No hay ruido procedural:
## a 16 px de lado lo que decide si una cabaña se distingue de un almacén es dónde va cada
## píxel, y eso no lo acierta un algoritmo de ruido.
##
## La **paleta sale de `BuildingDef.color`**, no de constantes escritas aquí. Es lo que impide
## que el sprite se desincronice del color que ya usan el botón del HUD y el tinte de oficio de
## los habitantes — los tres salen del mismo sitio (`data/Content.gd`).
##
##   `.` transparente · `a` color base · `b` sombra · `c` luz · `d` hueco oscuro (puertas,
##   ventanas, bocas de mina)

const OUT_DIR := "res://art"
const BUILDINGS_DIR := "res://art/buildings"

## Píxeles de sprite por celda de terreno. A 32, un edificio de huella 1.0 mide 32×32 y se ve
## nítido hasta `ScaleCamera.ZOOM_MAX`, que es donde hay que juzgar el pixelart.
const PIXELS_PER_CELL := 32

## Cada rejilla se dibuja tal cual y luego se escala a la huella del edificio. Todas son
## cuadradas de 16 para que las siluetas se puedan comparar de un vistazo mientras se editan.
const GRIDS := {
	"hut": [
		"................",
		"................",
		".......cc.......",
		"......cccc......",
		".....cccccc.....",
		"....cccccccc....",
		"...cccccccccc...",
		"..cccccccccccc..",
		".bbbbbbbbbbbbbb.",
		".aaaaaaaaaaaaaa.",
		".aaaaaaaaaaaaaa.",
		".aaaaaddddaaaaa.",
		".aaaaaddddaaaaa.",
		".aaaaaddddaaaaa.",
		".bbbbbddddbbbbb.",
		"................",
	],
	"farm": [
		"................",
		"..cc..cc..cc..c.",
		".cccc.cccc.cccc.",
		".cccc.cccc.cccc.",
		".aaaa.aaaa.aaaa.",
		".aaaa.aaaa.aaaa.",
		".bbbb.bbbb.bbbb.",
		"................",
		"..cc..cc..cc..c.",
		".cccc.cccc.cccc.",
		".cccc.cccc.cccc.",
		".aaaa.aaaa.aaaa.",
		".aaaa.aaaa.aaaa.",
		".bbbb.bbbb.bbbb.",
		"................",
		"................",
	],
	"woodcutter": [
		"................",
		"......cc........",
		".....cccc.......",
		"....cccccc......",
		"...cccccccc.....",
		"..cccccccccc....",
		"..bbbbbbbbbb....",
		"..aaaaaaaaaa....",
		"..aaaaddaaaa....",
		"..aaaaddaaaa....",
		"..bbbbddbbbb....",
		"................",
		"...........cc...",
		"..........cbbc..",
		"...........bb...",
		"...........bb...",
	],
	"storehouse": [
		"................",
		"................",
		"..cccccccccccc..",
		".cccccccccccccc.",
		"cccccccccccccccc",
		"bbbbbbbbbbbbbbbb",
		"aaaaaaaaaaaaaaaa",
		"aaaaaaaaaaaaaaaa",
		"aaddaaaaaaaaddaa",
		"aaddaaaaaaaaddaa",
		"aaaaaaaaaaaaaaaa",
		"aaaaaddddaaaaaaa",
		"aaaaaddddaaaaaaa",
		"bbbbbddddbbbbbbb",
		"................",
		"................",
	],
	"quarry": [
		"................",
		"................",
		"....cccc........",
		"...cccccc.......",
		"..cccccccccc....",
		"..bbbccccccccc..",
		".bbbbbbbcccccc..",
		".aaabbbbbbbcccc.",
		".aaaaaabbbbbbbb.",
		"aaddddaaaabbbbbb",
		"aaddddaaaaaaaabb",
		"aaddddaaaaaaaaaa",
		"bbddddbbbbaaaaaa",
		"bbbbbbbbbbbbbbbb",
		"................",
		"................",
	],
	"workshop": [
		"................",
		"................",
		"..cc........cc..",
		"..cc........cc..",
		".cccccccccccccc.",
		".bbbbbbbbbbbbbb.",
		".aaaaaaaaaaaaaa.",
		".aaddaaaaaaddaa.",
		".aaddaaaaaaddaa.",
		".aaaaaaaaaaaaaa.",
		".aaaaaaddaaaaaa.",
		".aaaaaaddaaaaaa.",
		".bbbbbbddbbbbbb.",
		"................",
		"................",
		"................",
	],
	# Dos pisos de puertas: es lo que la distingue de la cabaña de un vistazo, y lo que dice sin
	# texto que aquí no vive una familia.
	"commons": [
		"................",
		"................",
		"...cccccccccc...",
		"..cccccccccccc..",
		".cccccccccccccc.",
		"bbbbbbbbbbbbbbbb",
		"aaaaaaaaaaaaaaaa",
		"aaddaaddaaddaaaa",
		"aaddaaddaaddaaaa",
		"aaaaaaaaaaaaaaaa",
		"aaddaaddaaddaaaa",
		"aaddaaddaaddaaaa",
		"bbbbbbbbbbbbbbbb",
		"................",
		"................",
		"................",
	],
	# Contrafuertes y un portón: masa de piedra, no tablas. El almacén tiene tejado a dos aguas
	# y este no, que es lo que evita confundirlos cuando están uno al lado del otro.
	"depot": [
		"................",
		"cccccccccccccccc",
		"cccccccccccccccc",
		"bbbbbbbbbbbbbbbb",
		"aabbaaaaaaaabbaa",
		"aabbaaaaaaaabbaa",
		"aabbaaddddaabbaa",
		"aabbaaddddaabbaa",
		"aabbaaddddaabbaa",
		"aabbaaddddaabbaa",
		"aabbaaaaaaaabbaa",
		"aabbaaaaaaaabbaa",
		"bbbbbbbbbbbbbbbb",
		"................",
		"................",
		"................",
	],
	"market": [
		"................",
		"...c..c..c..c...",
		"..cccccccccccc..",
		".cccccccccccccc.",
		"cccccccccccccccc",
		"bbbbbbbbbbbbbbbb",
		"..a..a....a..a..",
		"..a..a....a..a..",
		"..a..a....a..a..",
		"..a..a....a..a..",
		".aaaaaaaaaaaaaa.",
		".addaaaddaaadda.",
		".addaaaddaaadda.",
		".bbbbbbbbbbbbbb.",
		"................",
		"................",
	],
	"temple": [
		".......cc.......",
		"......cccc......",
		".......cc.......",
		"................",
		"......cccc......",
		".....cccccc.....",
		"....cccccccc....",
		"...cccccccccc...",
		"..bbbbbbbbbbbb..",
		"..aaaaaaaaaaaa..",
		"..aaaaaaaaaaaa..",
		"..aaaaddddaaaa..",
		"..aaaaddddaaaa..",
		"..aaaaddddaaaa..",
		"..bbbbddddbbbb..",
		"................",
	],
	# Una cuadra alargada con tres portones de cuadra y el heno asomando por el pajar.
	"stables": [
		"................",
		"................",
		"......cccc......",
		"....cccccccc....",
		"..cccccccccccc..",
		".cccccccccccccc.",
		"bbbbbbbbbbbbbbbb",
		".aaaaaaaaaaaaaa.",
		".aaaaaaddaaaaaa.",
		".aaaaaaaaaaaaaa.",
		".addaaddddaadda.",
		".addaaddddaadda.",
		".addaaddddaadda.",
		".addaaddddaadda.",
		".bbbbbbbbbbbbbb.",
		"................",
	],
}

## Los cuatro fotogramas del habitante, de 8×8. `a` es el cuerpo —lo tiñe el color de oficio en
## tiempo de ejecución—, `b` la sombra y `c` la cabeza.
##
## La animación es deliberadamente corta: la vida la da el **movimiento** (inercia, frenada,
## desvío lateral), no el número de fotogramas. Estos solo evitan que a zoom máximo un habitante
## sea un cuadrado liso.
const VILLAGER_FRAMES := [
	[  # parado
		"..cccc..",
		"..cccc..",
		"..aaaa..",
		".aaaaaa.",
		".aaaaaa.",
		"..aaaa..",
		"..b..b..",
		"..b..b..",
	],
	[  # andando A
		"..cccc..",
		"..cccc..",
		"..aaaa..",
		".aaaaaa.",
		".aaaaaa.",
		"..aaaa..",
		".bb...b.",
		".b....bb",
	],
	[  # andando B
		"...cccc.",
		"...cccc.",
		"...aaaa.",
		"..aaaaaa",
		"..aaaaaa",
		"...aaaa.",
		"...b.b..",
		"...b.b..",
	],
	[  # durmiendo — tumbado, para que de noche se lea a la primera
		"........",
		"........",
		"........",
		".cc.....",
		"ccaaaaa.",
		".aaaaaa.",
		"..bbbb..",
		"........",
	],
]


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(BUILDINGS_DIR))
	var written := 0
	for i in Content.building_count():
		var def := Content.building(i)
		if not GRIDS.has(def.id):
			push_error("sin rejilla para el edificio '%s'" % def.id)
			continue
		written += _write_building(def)
	written += _write_villager()
	print("%d PNG escritos en %s" % [written, ProjectSettings.globalize_path(OUT_DIR)])
	quit(0)


## Un PNG por tipo de edificio, con el tamaño que le toca por su huella.
##
## El quad ya se dibuja a `footprint * TILE`, así que generar la textura con esa misma
## proporción es lo que evita que una granja de 1.5×1.1 salga estirada.
func _write_building(def: BuildingDef) -> int:
	var grid: Array = GRIDS[def.id]
	var width := int(round(def.footprint.x * float(PIXELS_PER_CELL)))
	var height := int(round(def.footprint.y * float(PIXELS_PER_CELL)))
	var image := _render(grid, _palette_of(def.color))
	# Nearest al escalar: interpolar convertiría el pixelart en un borrón.
	image.resize(width, height, Image.INTERPOLATE_NEAREST)
	var path := "%s/%s.png" % [BUILDINGS_DIR, def.id]
	image.save_png(path)
	print("  %-12s %2dx%-2d  %s" % [def.id, width, height, path])
	return 1


func _write_villager() -> int:
	var frames: Array = VILLAGER_FRAMES
	var side := (frames[0] as Array).size()
	var strip := Image.create_empty(side * frames.size(), side, false, Image.FORMAT_RGBA8)
	# Blanco: el color de verdad se lo pone el tinte por oficio y actividad, instancia a
	# instancia. Pintarlo aquí duplicaría la paleta y se desincronizaría.
	var palette := _palette_of(Color(1, 1, 1))
	for i in frames.size():
		strip.blit_rect(_render(frames[i], palette),
			Rect2i(0, 0, side, side), Vector2i(i * side, 0))
	var path := "%s/villager.png" % OUT_DIR
	strip.save_png(path)
	print("  %-12s %2dx%-2d  %s" % ["villager", strip.get_width(), strip.get_height(), path])
	return 1


## Los tres tonos que pide la dirección de arte, derivados del color del edificio.
static func _palette_of(base: Color) -> Dictionary:
	return {
		"a": base,
		"b": base.darkened(0.35),
		"c": base.lightened(0.25),
		"d": base.darkened(0.65),
	}


static func _render(grid: Array, palette: Dictionary) -> Image:
	var height := grid.size()
	var width := (grid[0] as String).length()
	var image := Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
	for y in height:
		var row: String = grid[y]
		for x in width:
			var key := row.substr(x, 1)
			image.set_pixel(x, y, palette.get(key, Color(0, 0, 0, 0)))
	return image
