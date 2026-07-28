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
##
## **Anclado en coordenadas de mundo.** El mapa es una *ventana* sobre un mundo infinito
## centrada en el asentamiento: la celda `(x, y)` de un mapa de lado `S` se muestrea en el
## punto `(x − S/2, y − S/2)`, y las frecuencias de ruido son constantes. De ahí sale el
## invariante que hace posible que el mundo se abra al promocionar:
##
##   **El mismo punto del mundo da siempre el mismo bioma, sea cual sea el tamaño de la
##   ventana.**
##
## La versión anterior dividía la frecuencia por `size` y centraba el domo en la mitad del
## mapa. Con eso, pedir 96 celdas en vez de 64 no daba el mismo mundo con más alrededores:
## daba **otro mundo**, y promocionar habría rehecho el terreno bajo los pies del jugador.

## Lado de la ventana en celdas, por escala. Crece con el tier: promocionar **revela más
## mundo**, no genera uno nuevo.
const SIZE_BY_TIER := [64, 96, 128, 160, 192, 224, 256]

## Escala de referencia del ruido. Constante a propósito: es lo que hace que el relieve tenga
## el mismo tamaño aparente en todas las escalas.
const NOISE_SCALE := 64.0

## Radio, en celdas, del bulto de habitabilidad del centro.
##
## Antes esto era un domo del tamaño del mapa que dibujaba «la isla», y por eso el terreno
## cambiaba al crecer la ventana. Ahora es solo un empujón local: **los fundadores eligieron
## buen sitio**. Las costas, los lagos y las montañas de más allá los pone el ruido, así que
## ampliar la ventana no toca ni una celda de lo que ya se veía.
const HOMESTEAD_RADIUS := 9.0
const HOMESTEAD_LIFT := 0.30

## Sesgo de altura por nodo, para que ninguna semilla nazca en mitad del océano.
const LAND_BIAS := 0.06


class Terrain:
	extends RefCounted
	var size: int = 0
	var cells: PackedByteArray = PackedByteArray()
	var seed: int = 0

	## Desplazamiento entre índice de celda y coordenada de mundo. El asentamiento está
	## siempre en el mundo `(0, 0)`, mida lo que mida la ventana.
	func origin() -> int:
		return size / 2

	func to_world(cell: Vector2i) -> Vector2i:
		return cell - Vector2i(origin(), origin())

	func to_cell(world: Vector2i) -> Vector2i:
		return world + Vector2i(origin(), origin())

	## Mitad del lado, en coordenadas de mundo: la ventana va de `−extent` a `+extent`.
	func extent() -> int:
		return size / 2

	func in_bounds(world: Vector2i) -> bool:
		var cell := to_cell(world)
		return cell.x >= 0 and cell.y >= 0 and cell.x < size and cell.y < size

	## Bioma en un punto **del mundo**.
	func at(world: Vector2i) -> int:
		if not in_bounds(world):
			return Biomes.WATER
		var cell := to_cell(world)
		return cells[cell.y * size + cell.x]

	func is_buildable(world: Vector2i) -> bool:
		return in_bounds(world) and Biomes.is_buildable(at(world))

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

	var height := _make_noise(node_seed, 3.0 / NOISE_SCALE, 4)
	# Desplazar la semilla, no reusarla: con la misma, humedad y altura quedan correlacionadas
	# y el mapa se vuelve monótono otra vez.
	var moisture := _make_noise(node_seed ^ 0x5bf03635, 4.5 / NOISE_SCALE, 3)

	var origin := terrain.origin()
	for y in size:
		for x in size:
			var wx := float(x - origin)
			var wy := float(y - origin)
			terrain.cells[y * size + x] = biome_at(height, moisture, wx, wy)
	return terrain


static func _make_noise(noise_seed: int, frequency: float, octaves: int) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = noise_seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = octaves
	noise.frequency = frequency
	return noise


## Bioma en un punto del mundo. **No depende del tamaño de la ventana** — es el invariante que
## permite que promocionar revele más mundo sin cambiar el que ya había.
static func biome_at(
	height: FastNoiseLite, moisture: FastNoiseLite, wx: float, wy: float
) -> int:
	var distance := sqrt(wx * wx + wy * wy)
	var homestead := HOMESTEAD_LIFT * maxf(1.0 - distance / HOMESTEAD_RADIUS, 0.0)
	var h := (height.get_noise_2d(wx, wy) * 0.5 + 0.5) * 0.72 + homestead + LAND_BIAS
	var m := moisture.get_noise_2d(wx, wy) * 0.5 + 0.5
	return _classify(h, m)


## Utilidad para tests e inspección: el bioma de un punto sin construir el mapa entero.
static func biome_at_world(node_seed: int, wx: float, wy: float) -> int:
	return biome_at(
		_make_noise(node_seed, 3.0 / NOISE_SCALE, 4),
		_make_noise(node_seed ^ 0x5bf03635, 4.5 / NOISE_SCALE, 3),
		wx, wy)


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
			img.set_pixel(x, y, Biomes.COLORS[terrain.cells[y * terrain.size + x]])
	return img
