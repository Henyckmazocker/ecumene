class_name TerrainGen
extends RefCounted

## Generación del terreno 2D de un nodo.
##
## **El terreno no se guarda: se recuerda.** Todo sale de `hash(world_seed, node_id)`, así que
## un imperio con miles de nodos no ocupa nada en el save y el mapa de una ciudad es siempre
## el mismo entre sesiones y entre plataformas.
##
## Dos campos de ruido cruzados —altura y humedad— en vez de uno: con un solo campo todos los
## mundos salen iguales; con dos ya hay bosque húmedo, sabana seca y montaña pelada.

## Lado del mapa en celdas, por escala. Crece con el tier porque una ciudad tiene que
## verse mayor que un asentamiento aunque el render sea el mismo.
const SIZE_BY_TIER := [64, 96, 128, 160, 192, 224, 256]


class Terrain:
	extends RefCounted
	var size: int = 0
	var cells: PackedByteArray = PackedByteArray()
	var seed: int = 0

	func center() -> Vector2i:
		return Vector2i(size / 2, size / 2)

	func in_bounds(x: int, y: int) -> bool:
		return x >= 0 and y >= 0 and x < size and y < size

	func at(x: int, y: int) -> int:
		if not in_bounds(x, y):
			return Biomes.WATER
		return cells[y * size + x]

	func at_cell(cell: Vector2i) -> int:
		return at(cell.x, cell.y)

	func is_buildable(cell: Vector2i) -> bool:
		return in_bounds(cell.x, cell.y) and Biomes.is_buildable(at_cell(cell))

	## Reparto de biomas, para inspección y tests.
	func histogram() -> PackedInt32Array:
		var out := PackedInt32Array()
		out.resize(Biomes.COUNT)
		for c in cells:
			out[c] += 1
		return out


static func generate(node_seed: int, tier: int) -> Terrain:
	var size: int = SIZE_BY_TIER[clampi(tier, 0, SIZE_BY_TIER.size() - 1)]
	var terrain := Terrain.new()
	terrain.size = size
	terrain.seed = node_seed
	terrain.cells.resize(size * size)

	var height := FastNoiseLite.new()
	height.seed = node_seed
	height.noise_type = FastNoiseLite.TYPE_SIMPLEX
	height.fractal_type = FastNoiseLite.FRACTAL_FBM
	height.fractal_octaves = 4
	height.frequency = 3.0 / float(size)

	var moisture := FastNoiseLite.new()
	# Desplazar la semilla, no reusarla: con la misma, humedad y altura quedan correlacionadas
	# y el mapa se vuelve monótono otra vez.
	moisture.seed = node_seed ^ 0x5bf03635
	moisture.noise_type = FastNoiseLite.TYPE_SIMPLEX
	moisture.fractal_type = FastNoiseLite.FRACTAL_FBM
	moisture.fractal_octaves = 3
	moisture.frequency = 4.5 / float(size)

	var half := float(size) * 0.5
	for y in size:
		for x in size:
			# Domo suave hacia el centro: garantiza que el asentamiento nace en tierra firme
			# y deja el agua en los bordes, que es donde se ve bien y no estorba.
			var dx := (float(x) - half) / half
			var dy := (float(y) - half) / half
			var dome := 1.0 - minf(sqrt(dx * dx + dy * dy), 1.0)
			var h := (height.get_noise_2d(x, y) * 0.5 + 0.5) * 0.6 + dome * 0.45
			var m := moisture.get_noise_2d(x, y) * 0.5 + 0.5
			terrain.cells[y * size + x] = _classify(h, m)
	return terrain


static func _classify(h: float, m: float) -> int:
	if h < 0.34:
		return Biomes.WATER
	if h < 0.40:
		return Biomes.COAST
	if h > 0.78:
		return Biomes.MOUNTAIN
	if m > 0.60:
		return Biomes.FOREST
	if m < 0.36:
		return Biomes.ARID
	return Biomes.PLAIN


## Imagen del terreno, un téxel por celda. Se escala con filtro nearest en el render: para
## biomas de color plano es idéntico a un TileMap y cuesta una textura en vez de miles de
## celdas de TileMapLayer — que es lo que lo hace viable en móvil y navegador.
static func to_image(terrain: Terrain) -> Image:
	var img := Image.create_empty(terrain.size, terrain.size, false, Image.FORMAT_RGBA8)
	for y in terrain.size:
		for x in terrain.size:
			img.set_pixel(x, y, Biomes.COLORS[terrain.at(x, y)])
	return img
