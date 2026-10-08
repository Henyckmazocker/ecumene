class_name TerrainGen
extends RefCounted

## Generación del terreno 2D de un nodo.
##
## **El terreno no se guarda: se recuerda.** Todo sale de una semilla de terreno y de la
## posición de la ventana (`center`), así que un imperio con miles de nodos no ocupa nada en el
## save y el mapa de una ciudad es siempre el mismo entre sesiones y entre plataformas.
##
## **Un mundo por partida.** La semilla de terreno es la del mundo (la de la raíz), no la de
## cada nodo: un nodo es una ventana de ese mundo común centrada en su posición. Así el tipo de
## terreno de un punto es el mismo visto desde la raíz, desde un hijo o desde un nieto.
##
## Un solo campo de ruido, la altura: separa la tierra del agua y da el tono de la tierra
## (`Relief`). La humedad se fue con los biomas, que no significaban nada en el juego.
##
## **Anclado en coordenadas de mundo.** El mapa es una *ventana* sobre un mundo infinito
## centrada en `center`: la celda `(x, y)` de un mapa de lado `S` se muestrea en el punto
## `(x − S/2 + center.x, y − S/2 + center.y)`, y las frecuencias de ruido son constantes.
## El terreno sigue en coordenadas **locales** (el nodo en `(0, 0)`); lo único que se desplaza
## es el muestreo, y por eso `Layout`, la multitud y la vista no se enteran. De ahí sale el
## invariante que hace posible que el mundo se abra al promocionar:
##
##   **El mismo punto del mundo da siempre el mismo tipo de terreno, sea cual sea el tamaño de
##   la ventana.**
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

## Radio, en celdas, del bulto de habitabilidad del centro **del mundo** (la raíz).
##
## Antes esto era un domo del tamaño del mapa que dibujaba «la isla», y por eso el terreno
## cambiaba al crecer la ventana. Ahora es solo un empujón local: **los fundadores eligieron
## buen sitio**. Las costas, los lagos y las montañas de más allá los pone el ruido, así que
## ampliar la ventana no toca ni una celda de lo que ya se veía.
##
## Solo existe alrededor del `(0, 0)` del mundo, no del centro de cada ventana: si cada nodo
## llevara el suyo, el mismo punto daría un tipo de terreno desde el hijo y otro desde el padre.
##
## Decide qué es agua, pero no el tono de la tierra: con el realce, la raíz quedaría en mitad de
## un disco de cumbre que es un artefacto del generador y no relieve.
const HOMESTEAD_RADIUS := 9.0
const HOMESTEAD_LIFT := 0.30

## Sesgo de altura por nodo, para que ninguna semilla nazca en mitad del océano.
const LAND_BIAS := 0.06


class Terrain:
	extends RefCounted
	var size: int = 0
	var cells: PackedByteArray = PackedByteArray()
	## Semilla del terreno, la del mundo: solo sirve para el ruido. Lo que es por nodo (la
	## multitud, el orden de `Layout`) sale de `node.seed`, no de aquí.
	var seed: int = 0
	## Posición de la ventana en el mundo, en celdas. Solo desplaza el muestreo: las
	## coordenadas de abajo (`to_world`, `at`…) siguen siendo **locales**, con el nodo en `(0, 0)`.
	var center: Vector2i = Vector2i.ZERO

	## Desplazamiento entre índice de celda y coordenada local. El asentamiento está
	## siempre en el `(0, 0)` local, mida lo que mida la ventana.
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

	## Tipo de terreno (`Relief`) en un punto **del mundo**.
	func at(world: Vector2i) -> int:
		if not in_bounds(world):
			return Relief.WATER
		var cell := to_cell(world)
		return cells[cell.y * size + cell.x]

	func is_buildable(world: Vector2i) -> bool:
		return in_bounds(world) and Relief.is_buildable(at(world))

	## Reparto de tipos de terreno, para inspección y tests.
	func histogram() -> PackedInt32Array:
		var out := PackedInt32Array()
		out.resize(Relief.COUNT)
		for c in cells:
			out[c] += 1
		return out


## `terrain_seed`: la semilla del MUNDO. `center`: la posición del nodo en ese mundo. La celda
## local `(x, y)` se muestrea en el punto global `(x − origin + center.x, y − origin + center.y)`.
## Con `center = (0, 0)` sale exactamente el terreno de antes de que hubiera centro.
##
## `size_override`: el lado de la ventana, si no es el de la escala. La vista lo usa para enseñar
## más mundo alrededor de un nodo que tiene colonias (`SettlementView.window_size`); como el
## muestreo está anclado en el mundo, una ventana mayor es el mismo mundo con más alrededores.
static func generate(terrain_seed: int, center: Vector2i, tier: int,
		size_override: int = 0) -> Terrain:
	var size: int = size_override if size_override > 0 \
			else SIZE_BY_TIER[clampi(tier, 0, SIZE_BY_TIER.size() - 1)]
	var terrain := Terrain.new()
	terrain.size = size
	terrain.seed = terrain_seed
	terrain.center = center
	terrain.cells.resize(size * size)

	var height := _make_noise(terrain_seed, 3.0 / NOISE_SCALE, 4)

	var origin := terrain.origin()
	for y in size:
		for x in size:
			# Restar el origen y sumar el centro por separado, en enteros: con center = 0 da el
			# mismo float que antes, y por eso la raíz no cambia ni un téxel.
			var wx := float(x - origin + center.x)
			var wy := float(y - origin + center.y)
			terrain.cells[y * size + x] = relief_at(height, wx, wy)
	return terrain


static func _make_noise(noise_seed: int, frequency: float, octaves: int) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = noise_seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = octaves
	noise.frequency = frequency
	return noise


## Tipo de terreno en un punto **global** del mundo. **No depende del tamaño ni del centro de
## la ventana** (invariante 11 de Programación): es lo que permite que promocionar revele más
## mundo sin cambiar el que ya había, y que un hijo vea el mismo mundo que su padre. Por eso el
## realce se mide desde el origen global y no desde el centro de quien pregunta.
static func relief_at(height: FastNoiseLite, wx: float, wy: float) -> int:
	var distance := sqrt(wx * wx + wy * wy)
	var homestead := HOMESTEAD_LIFT * maxf(1.0 - distance / HOMESTEAD_RADIUS, 0.0)
	var noise_term := (height.get_noise_2d(wx, wy) * 0.5 + 0.5) * 0.72
	# `h` se suma en el mismo orden que cuando había biomas: en coma flotante el orden cuenta, y
	# un bit de diferencia en el umbral movería el agua y con ella las colonias.
	var h := noise_term + homestead + LAND_BIAS
	if h < 0.34:
		return Relief.WATER
	# El tono, SIN el realce del centro.
	return _shade(noise_term + LAND_BIAS)


## Utilidad para tests e inspección: el terreno de un punto sin construir el mapa entero.
static func relief_at_world(terrain_seed: int, wx: float, wy: float) -> int:
	return relief_at(_make_noise(terrain_seed, 3.0 / NOISE_SCALE, 4), wx, wy)


## El tono de la tierra por su altura cruda (sin realce), de ~0,06 a ~0,78. Los cortes van por
## percentiles de la tierra (~35/30/22/13 %): con 0,45/0,55/0,65 la cumbre era un 3 % y casi no
## se veía, y la tierra baja se comía casi la mitad del mapa.
static func _shade(raw: float) -> int:
	if raw < 0.43:
		return Relief.LOW
	if raw < 0.51:
		return Relief.MID
	if raw < 0.58:
		return Relief.HIGH
	return Relief.PEAK


## Imagen del terreno, un téxel por celda. Se escala con filtro nearest en el render: para
## tonos de color plano es idéntico a un TileMap y cuesta una textura en vez de miles de
## celdas de TileMapLayer — que es lo que lo hace viable en móvil y navegador.
static func to_image(terrain: Terrain) -> Image:
	var img := Image.create_empty(terrain.size, terrain.size, false, Image.FORMAT_RGBA8)
	for y in terrain.size:
		for x in terrain.size:
			img.set_pixel(x, y, Relief.COLORS[terrain.cells[y * terrain.size + x]])
	return img
