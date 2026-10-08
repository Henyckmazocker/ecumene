class_name SettlementView
extends Node2D

## La vista del nodo enfocado: terreno, edificios y habitantes.
##
## Solo **lee** del estado. No escribe una sola propiedad de `WorldState`.
##
## Aquí conviven las dos simulaciones del proyecto. Los **edificios** son un reflejo directo
## del agregado —se construye uno y aparece en el mismo fotograma—. La **multitud** no: tiene
## su propio reloj y su propia inercia, y se acerca a lo que dictan los números poco a poco
## (ver [Crowd] y [CrowdReconciler]). Esa asimetría es deliberada: lo que el jugador *decide*
## tiene que responder al instante, y lo que el pueblo *es* tiene que verse vivir.
##
## Todo va por `MultiMeshInstance2D` —un nodo de escena por *tipo*, no por habitante—, que es
## lo que hace que cientos de personas quepan en el presupuesto de un móvil de gama baja.
##
## **Cambiar de foco es un fundido, no un corte** (M3 del plan «Vista agregada y zoom continuo»).
## La vista no es un nodo sino una pila de **capas** ([Layer]), una por nodo: la del foco y las
## que se están yendo. Cada capa tiene su terreno, sus edificios y su multitud, y está colocada
## donde su nodo está en el mundo, relativa al foco: como el terreno es compartido, la colonia
## cae justo encima de su sitio en el terreno del padre. Al cambiar de foco:
##
## 1. **Se prepara el destino sin enseñarlo.** Terreno, textura y `Layout` salen de la caché de
##    los últimos nodos ([Prepared]) o se calculan **troceados** entre fotogramas ([PrepJob]),
##    y la multitud nueva hace su `warm_up` también por trozos, invisible. Mientras tanto el
##    origen sigue a la vista y vivo: el fundido **espera** al destino, no lo exige.
## 2. **Se funde.** El destino sube de opacidad y el origen baja, los dos por `modulate.a`
##    (nunca por tema). La multitud saliente sigue andando mientras se desvanece y no se
##    reconcilia con nada: es una muestra congelada de un nodo que ya no se mira. Al llegar a 0
##    se libera.
##
## Nadie se teletransporta porque nadie cambia de sitio: cada capa se queda donde estaba en el
## mundo y lo único que cambia es su opacidad. Volver al nodo que se está yendo **revive** su
## capa, con su gente, desde la opacidad que tuviera.

## Píxeles de mundo por celda de terreno.
const TILE := 16.0

## Fotogramas de la tira del habitante (`art/villager.png`), en el orden que escribe
## `tools/gen_sprites.gd`.
const VILLAGER_FRAMES := 4
const FRAME_IDLE := 0
const FRAME_WALK_A := 1
const FRAME_WALK_B := 2
const FRAME_SLEEP := 3

## Celdas por segundo a partir de las cuales se considera que alguien **anda** y no solo se
## remueve en el sitio. Por debajo, el micromovimiento de estar trabajando dispararía el ciclo
## de paso y la gente parecería andar sin moverse.
const WALK_THRESHOLD := 0.35
## Pasos por segundo del ciclo de andar.
const STEP_CADENCE := 3.5

## Segundos reales que dura el fundido entre dos focos, una vez el destino está listo. Lo
## bastante corto para que el gesto de zoom no se sienta frenado, y lo bastante largo para que se
## lea como un fundido y no como un parpadeo.
const FADE_SECONDS := 0.4
## Microsegundos por fotograma que se dedican a preparar un foco (terreno, `Layout`, `warm_up`).
## El resto del fotograma es de la simulación, la multitud y el dibujo: con el pueblo grande un
## fotograma normal cuesta ~1 ms, así que el cruce queda holgado por debajo de 16 ms.
const PREP_BUDGET_USEC := 5000
## Paso del `warm_up`, en segundos de vida del pueblo: el mismo de siempre.
const WARM_STEP := 0.05
## Nodos cuyo terreno, textura y `Layout` se guardan. Entrar y salir del mismo hijo —lo más
## habitual— no regenera nada. El número definitivo se mide con el APK.
const CACHE_SIZE := 4
## Capas saliendo a la vez como mucho. Solo se llega con cambios de foco más rápidos que el
## fundido; pasado el tope se suelta la más transparente, que es la que menos se nota.
const MAX_OUTGOING := 3

## Qué hizo el último `show_node`. `Main` lo mira para saber si encuadrar ya o esperar al fundido.
enum Shown {
	SAME,   ## el mismo nodo: solo se ha refrescado
	FIRST,  ## no había nada antes: preparado en el acto, sin fundido (al arrancar)
	FADE,   ## otro nodo: empieza un fundido, y el destino se está preparando
}

## La capa del foco ya está lista (preparada y con su multitud caliente) y empieza a verse.
## `Main` encuadra aquí cuando el cambio de foco no venía del zoom.
signal focus_shown

var crowd_params := CrowdParams.new()
## Segundos de vida que se le dan a la multitud de un foco nuevo antes de enseñarla. Lo fija
## `Main` (su `WARM_UP_SECONDS`).
var warm_up_seconds: float = 12.0
## Qué hizo el último `show_node`.
var shown: Shown = Shown.SAME
## Los hijos del nodo enfocado, como manchas sobre su terreno (`ChildMapRenderer`).
var child_map: ChildMapRenderer

## El terreno y el `Layout` **del foco**. De solo lectura: los pone la capa.
var terrain: TerrainGen.Terrain:
	get:
		return _current.prepared.terrain if _current != null and _current.prepared != null else null
var layout: Layout.Result:
	get:
		return _current.prepared.layout if _current != null and _current.prepared != null else null

## El estado del que sale el terreno (semilla del mundo y posición del nodo). Solo se lee; lo
## pone `show_node`, que es por donde pasa también el cambio de era al ascender.
var _state: WorldState = null
## La capa del foco y las que se están yendo, de la más antigua a la más reciente.
var _current: Layer = null
var _outgoing: Array[Layer] = []
## La posición en el mundo del foco, en celdas: el `(0, 0)` local de la vista.
var _origin := Vector2i.ZERO
## Caché LRU de lo preparado, el más reciente al final.
var _cache: Array[Prepared] = []
## Preparación adelantada de un nodo al que se va a cruzar (`prefetch`), o `null`.
var _prefetch: PrepJob = null
## Fundido congelado en una fracción, para las capturas; -1 si corre solo.
var _fade_hold: float = -1.0

## El tinte día/noche. Tiñe todo el canvas de la vista —terreno, edificios y gente— y nada
## más: el HUD es un `CanvasLayer` y vive en otro canvas, así que no le llega.
var _light: CanvasModulate
## Los terrenos de todas las capas van debajo de todos sus contenidos: así dos pueblos que se
## funden se dibujan sobre un suelo continuo, y no un pueblo bajo el terreno del otro.
var _ground_root: Node2D
var _content_root: Node2D
var _quad: ArrayMesh
var _building_textures: Array[Texture2D] = []
var _villager_texture: Texture2D
var _villager_mat: ShaderMaterial


## Lo que cuesta preparar un nodo, ya hecho: terreno, su textura y su `Layout`. Es lo que guarda
## la caché, y lo que usa la capa mientras se mira. La multitud **no** va aquí: no es estado, y se
## regenera desde la semilla del nodo (`node.seed ^ 0x9e3779b9`).
class Prepared:
	extends RefCounted
	var node_id: int = -1
	var world_seed: int = 0
	var center := Vector2i.ZERO
	var tier: int = -1
	## Profundidad del nodo en el árbol: de ella salen el núcleo del `Layout` y el lado de la
	## ventana de terreno (`SettlementView.window_size`).
	var depth: int = 0
	var terrain: TerrainGen.Terrain
	var texture: Texture2D
	var layout: Layout.Result

	## Sirve para este nodo si es del mismo mundo, en el mismo sitio, de la misma escala y a la
	## misma profundidad: lo que define la ventana de terreno y el núcleo. El `Layout` puede
	## estar atrasado; eso se extiende.
	func fits(node: SimNode, seed_value: int, at: Vector2i, at_depth: int) -> bool:
		return node_id == node.id and world_seed == seed_value and center == at \
				and tier == node.tier and depth == at_depth

	## El radio del núcleo con el que se coloca su `Layout` (`Layout.core_radius`).
	func core() -> float:
		return Layout.core_radius(depth)

	func window() -> int:
		return SettlementView.window_size(tier, depth)


## Preparar un nodo **por trozos**, con un plazo por fotograma: primero el terreno fila a fila
## (con su imagen), luego la textura, y luego el `Layout` por tandas de unos pocos edificios.
##
## El terreno sale **idéntico** al de `TerrainGen.generate` (mismo ruido, mismo orden, mismo
## `relief_at`) y el `Layout`, al de `Layout.build`: cada tanda es un `Layout.extend` sobre la
## anterior, y `extend` da lo mismo que `build` con los mismos edificios (M0b). Lo comprueba
## `terrain_test` (`_sliced_prep_matches`).
class PrepJob:
	extends RefCounted
	## Edificios que se colocan por tanda: un ejemplar en un pueblo lleno cuesta ~0,2 ms de media.
	const CHUNK := 4

	var prepared := Prepared.new()
	var node: SimNode
	var _height: FastNoiseLite
	var _row: int = -1
	var _pixels := PackedByteArray()
	## El terreno a medio rellenar: no pasa a `prepared` hasta tener todas sus filas.
	var _partial: TerrainGen.Terrain = null
	var _layout_from: Layout.Result = null
	var _target := PackedInt32Array()
	var _proxy: SimNode = null
	var _next_type: int = 0
	var _done := false

	func _init(for_node: SimNode, seed_value: int, at: Vector2i, cached: Prepared,
			at_depth: int = 0) -> void:
		node = for_node
		prepared.node_id = for_node.id
		prepared.world_seed = seed_value
		prepared.center = at
		prepared.tier = for_node.tier
		prepared.depth = at_depth
		if cached != null and cached.fits(for_node, seed_value, at, at_depth):
			# El terreno ya está: solo falta poner el `Layout` al día.
			prepared.terrain = cached.terrain
			prepared.texture = cached.texture
			_layout_from = cached.layout

	func matches(for_node: SimNode, seed_value: int, at: Vector2i, at_depth: int) -> bool:
		return prepared.fits(for_node, seed_value, at, at_depth)

	func is_done() -> bool:
		return _done

	## Trabaja hasta el plazo (en `Time.get_ticks_usec`). Devuelve `true` al acabar.
	func step(deadline_usec: int) -> bool:
		while not _done:
			if prepared.terrain == null:
				_terrain_rows(deadline_usec)
			elif prepared.texture == null:
				var image := Image.create_from_data(prepared.terrain.size, prepared.terrain.size,
						false, Image.FORMAT_RGBA8, _pixels)
				prepared.texture = ImageTexture.create_from_image(image)
				_pixels = PackedByteArray()
			else:
				_layout_chunks(deadline_usec)
			if not _done and Time.get_ticks_usec() >= deadline_usec:
				return false
		return true

	## Copia de `TerrainGen.generate`, fila a fila. Si cambia aquel, `_sliced_prep_matches` falla.
	func _terrain_rows(deadline_usec: int) -> void:
		var size := prepared.window()
		if _row < 0:
			_height = TerrainGen._make_noise(prepared.world_seed, 3.0 / TerrainGen.NOISE_SCALE, 4)
			_pixels.resize(size * size * 4)
			_row = 0
			_partial = TerrainGen.Terrain.new()
			_partial.size = size
			_partial.seed = prepared.world_seed
			_partial.center = prepared.center
			_partial.cells.resize(size * size)
		var palette := SettlementView._relief_bytes()
		var origin := _partial.origin()
		var center := prepared.center
		while _row < size:
			var y := _row
			for x in size:
				var wx := float(x - origin + center.x)
				var wy := float(y - origin + center.y)
				var kind := TerrainGen.relief_at(_height, wx, wy)
				var i := y * size + x
				_partial.cells[i] = kind
				var rgba: PackedByteArray = palette[kind]
				_pixels[i * 4] = rgba[0]
				_pixels[i * 4 + 1] = rgba[1]
				_pixels[i * 4 + 2] = rgba[2]
				_pixels[i * 4 + 3] = rgba[3]
			_row += 1
			if Time.get_ticks_usec() >= deadline_usec:
				return
		prepared.terrain = _partial
		_partial = null

	## `Layout` por tandas. Se parte de lo que hubiera en caché sobre este mismo terreno: lo que
	## coincide hasta el primer tipo que cambia se copia, y desde ahí se coloca en orden de tipo
	## y de ejemplar, `CHUNK` cada vez. Cada resultado intermedio es el `build` de un pueblo con
	## solo esos edificios, así que el último es el `build` de este.
	func _layout_chunks(deadline_usec: int) -> void:
		if _proxy == null:
			_target = node.buildings.duplicate()
			var prev := _layout_from
			if prev != null and (prev._ground == null or prev._ground.terrain != prepared.terrain
					or prev._ground.core != prepared.core()
					or prev.signature.size() != _target.size()):
				prev = null
			if prev != null and prev.signature == _target:
				prepared.layout = prev
				_done = true
				return
			var first := 0
			if prev != null:
				while first < _target.size() and prev.signature[first] == _target[first]:
					first += 1
			_proxy = SimNode.new()
			_proxy.tier = node.tier
			var counts := _target.duplicate()
			for i in range(first, counts.size()):
				counts[i] = 0
			_proxy.buildings = counts
			prepared.layout = Layout.extend(prev, _proxy, prepared.terrain, prepared.core()) \
					if prev != null else Layout.build(_proxy, prepared.terrain, prepared.core())
			_next_type = first
		while _next_type < _target.size():
			var have := _proxy.buildings[_next_type]
			var want := _target[_next_type]
			if have >= want:
				_next_type += 1
				continue
			_proxy.buildings[_next_type] = mini(want, have + CHUNK)
			prepared.layout = Layout.extend(prepared.layout, _proxy, prepared.terrain,
					prepared.core())
			if Time.get_ticks_usec() >= deadline_usec:
				return
		_done = true


## Una capa: un nodo dibujado, con su terreno, sus edificios y su multitud, colocado donde está
## en el mundo respecto al foco. Su opacidad es la del fundido.
class Layer:
	extends RefCounted
	var node: SimNode
	var node_id: int = -1
	var world_seed: int = 0
	## Posición del nodo en el mundo, en celdas, cuando se montó la capa.
	var center := Vector2i.ZERO
	## Profundidad del nodo en el árbol (núcleo y ventana).
	var depth: int = 0
	var prepared: Prepared = null
	var job: PrepJob = null
	var crowd: Crowd = null
	var reconciler: CrowdReconciler = null
	var ground: Sprite2D
	var content: Node2D
	var buildings: Array[MultiMeshInstance2D] = []
	var agents: MultiMeshInstance2D
	## Opacidad del contenido, de 0 a 1. El terreno va al doble (ver `_apply_alpha`).
	var alpha: float = 0.0
	## Preparada y con la multitud caliente: ya se puede ver.
	var ready: bool = false
	## Segundos de vida que le faltan a la multitud antes de poder enseñarse.
	var warm_debt: float = 0.0


## En `_init` y no en `_ready`: la vista se puede usar antes de entrar en el árbol (los tests y
## las sondas la montan y le enseñan un nodo en el mismo fotograma).
func _init() -> void:
	_quad = _make_quad()

	_light = CanvasModulate.new()
	add_child(_light)

	_ground_root = Node2D.new()
	_ground_root.name = "Ground"
	add_child(_ground_root)
	_content_root = Node2D.new()
	_content_root.name = "Content"
	add_child(_content_root)

	for i in Content.building_count():
		var def := Content.building(i)
		_building_textures.append(_load_texture("res://art/buildings/%s.png" % def.id, def.color))
	_villager_texture = _load_texture("res://art/villager.png", Color.WHITE)
	_villager_mat = _villager_material()

	# La vista agregada, encima de todo lo del nodo: sus hijos como manchas sobre este mismo
	# terreno. La refresca `Main` (necesita los parámetros del motor) y decide cuándo se ve.
	child_map = ChildMapRenderer.new()
	child_map.name = "ChildMap"
	child_map.cell_size = TILE
	child_map.visible = false
	add_child(child_map)


## El quad de 1×1 centrado que comparten todos los `MultiMesh`.
##
## Se construye a mano en vez de usar `QuadMesh` **porque `QuadMesh` trae las UV en convención
## 3D**: pone `uv.y = 0` en el vértice `y = +0.5`, que en 3D es arriba pero en 2D es abajo. El
## resultado es que todo el pixelart sale boca abajo. Aquí `uv.y` crece con `y`, como en
## cualquier `Sprite2D`, y el sprite se ve como se dibujó.
static func _make_quad() -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector2Array([
		Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(0.5, 0.5), Vector2(-0.5, 0.5),
	])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(1.0, 1.0), Vector2(0.0, 1.0),
	])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _make_multimesh(modulate_color: Color) -> MultiMeshInstance2D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	# Fotograma por instancia. Los edificios no lo usan, pero cuesta lo mismo declararlo aquí
	# que tener dos constructores.
	mm.use_custom_data = true
	mm.mesh = _quad
	var inst := MultiMeshInstance2D.new()
	inst.multimesh = mm
	inst.modulate = modulate_color
	# Nearest, igual que el terreno: filtrar el pixelart lo emborrona en cuanto se acerca el
	# zoom, que es justo donde se supone que hay que mirarlo.
	inst.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	return inst


## El material que elige el fotograma de cada habitante.
##
## Toda la multitud va en **un solo `MultiMesh`** —esa es la razón de que quepan cientos en un
## móvil— así que las cuatro poses comparten una tira de textura y cada instancia dice cuál le
## toca por `INSTANCE_CUSTOM`. El shader solo desplaza la UV: no toca `COLOR`, y por eso el
## tinte por oficio y actividad de [method _villager_color] sigue funcionando igual.
static func _villager_material() -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """
shader_type canvas_item;

// Fotogramas de la tira: parado, andando A, andando B, durmiendo.
uniform float frames = 4.0;

void vertex() {
	UV.x = (UV.x + INSTANCE_CUSTOM.x) / frames;
}
"""
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("frames", float(VILLAGER_FRAMES))
	return material


## Carga un sprite, y si falta se cae a un cuadrado del color del edificio.
##
## Los PNG los escribe `tools/gen_sprites.gd` y viven en el repo, así que faltar no deberían;
## pero quedarse sin arte no puede dejar el pueblo invisible, que es lo que pasaría con una
## textura nula. Sin sprite, el juego vuelve a verse como antes de tenerlos.
static func _load_texture(path: String, fallback: Color) -> Texture2D:
	if ResourceLoader.exists(path):
		return load(path)
	push_warning("falta el sprite %s: se dibuja un cuadrado plano" % path)
	var image := Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	image.set_pixel(0, 0, fallback)
	return ImageTexture.create_from_image(image)


static var _relief_rgba: Array = []

## Los cuatro bytes de cada tipo de terreno, convertidos **por la misma `Image.set_pixel`** que usa
## `TerrainGen.to_image`: así la textura troceada sale idéntica byte a byte.
static func _relief_bytes() -> Array:
	if _relief_rgba.is_empty():
		var one := Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
		for color in Relief.COLORS:
			one.set_pixel(0, 0, color)
			_relief_rgba.append(one.get_data().duplicate())
	return _relief_rgba


## Margen, en celdas, que la ventana de terreno deja más allá del anillo de las colonias: lo que
## mide la mancha más grande de la vista agregada (7) y algo de campo alrededor.
const CONTEXT_MARGIN := 16.0


## Lado de la ventana de terreno de un nodo: la de su escala, o la que hace falta para que la
## **vista agregada** enseñe sus colonias en campo abierto, la que sea mayor. Las colonias caen
## en un anillo fuera del núcleo (`WorldState.child_ring`, hasta `núcleo + 22`), y con la ventana
## de la escala (±64 en una ciudad) caían en el borde o fuera del terreno dibujado.
##
## **Por profundidad, como el núcleo y el anillo**, y no según tenga hijos o no: así la ventana
## no cambia al fundar la primera colonia (cambiarla obliga a regenerar el terreno en el acto).
## Es el mismo mundo con más alrededores; lo que cuesta es generarlo, y eso va troceado
## ([PrepJob]) y a la caché. Raíz 160, hijos 144, nietos 128 (múltiplos de 16).
static func window_size(tier: int, depth: int) -> int:
	var by_tier: int = TerrainGen.SIZE_BY_TIER[clampi(tier, 0, TerrainGen.SIZE_BY_TIER.size() - 1)]
	var reach := Layout.core_radius(depth) + WorldState.PLACE_RING_OUTER + CONTEXT_MARGIN
	return maxi(by_tier, int(ceil(reach * 2.0 / 16.0)) * 16)


## La ventana de terreno visible, en píxeles y **centrada en el origen del mundo**. Acota el
## paneo de la cámara, y crece al promocionar. Sale de la escala y la profundidad del foco
## (`window_size`) y no del terreno, para que exista ya mientras el terreno se está preparando.
## Desde M3c es la ventana de verdad y no la de la escala: con la de la escala (±64 en una ciudad)
## no se podía panear hasta las colonias, que caen a 46-62 celdas del centro.
func terrain_bounds() -> Rect2:
	if _current == null or _current.node == null:
		return Rect2()
	var half := float(window_size(_current.node.tier, _current.depth)) * 0.5 * TILE
	return Rect2(-Vector2.ONE * half, Vector2.ONE * half * 2.0)


## Lo que hay que tener en pantalla: la mancha construida, no el mapa entero.
##
## Encuadrar el mapa completo era el defecto obvio y estaba mal: a esa distancia los
## habitantes son un píxel y desaparece justamente lo que este juego tiene que enseñar. El
## encuadre por defecto es el asentamiento, y alejarse hasta ver el mundo es cosa del jugador.
func settlement_extent() -> Rect2:
	# Mínimo de 22 celdas de lado: un asentamiento recién fundado no puede llenar la pantalla
	# con dos edificios, pero tampoco tiene que verse desde el espacio.
	var rect := Rect2(-Vector2.ONE * TILE * 11.0, Vector2.ONE * TILE * 22.0)
	if layout != null:
		for p in layout.placements:
			rect = rect.expand((Vector2(p.cell) + Vector2(0.5, 0.5)) * TILE)
	return rect.grow(TILE * 3.0)


## Muestra un nodo. Devuelve cuánto hay que **mover la cámara** (en píxeles) para que siga
## mirando el mismo punto del mundo: el origen de la vista pasa a ser el nodo nuevo.
##
## El estado hace falta para el terreno: un nodo es una ventana del mundo de la partida
## (`state.terrain_seed()`) centrada en su posición (`state.world_pos_of(node)`). Solo se lee.
##
## - El mismo nodo: se refresca, como siempre (`shown = SAME`).
## - Sin nada antes: se prepara en el acto, sin fundido (`FIRST`). El `warm_up` es de quien llama.
## - Otro nodo: empieza un fundido (`FADE`). El destino se prepara por trozos en `advance` y no
##   se ve hasta tener la multitud caliente; el origen sigue vivo mientras tanto.
func show_node(node: SimNode, state: WorldState) -> Vector2:
	if node == null:
		return Vector2.ZERO
	_state = state
	var seed_value := state.terrain_seed()
	var at := state.world_pos_of(node)
	var depth := state.depth_of(node)
	if _current != null and _current.node_id == node.id and _current.world_seed == seed_value:
		shown = Shown.SAME
		refresh(node)
		return Vector2.ZERO
	_prune_cache(state)
	var shift := Vector2(_origin - at) * TILE
	_origin = at

	if _current == null and _outgoing.is_empty():
		shown = Shown.FIRST
		_current = _make_layer(node, seed_value, at, depth)
		_finish_prep(_current)
		_start_crowd(_current, 0.0)
		_current.ready = true
		_current.alpha = 1.0
		_apply_alpha(_current)
		_place_layers()
		return Vector2.ZERO

	shown = Shown.FADE
	if _current != null:
		if _current.ready and _current.alpha > 0.0:
			_outgoing.append(_current)
		else:
			# Aún no se veía: no hay nada que fundir. Lo hecho se queda como preparación
			# adelantada, por si se vuelve.
			if _current.job != null and _prefetch == null:
				_prefetch = _current.job
			_drop(_current)
	_current = null
	for layer in _outgoing:
		if layer.node_id == node.id and layer.world_seed == seed_value and layer.center == at:
			# Volver al nodo que se estaba yendo: se revive su capa, con su gente, desde la
			# opacidad que tuviera. Rehacerla sería tirar una multitud que está a la vista.
			_current = layer
			_outgoing.erase(layer)
			_current.node = node
			break
	if _current == null:
		_current = _make_layer(node, seed_value, at, depth)
		var cached := _cache_find(node, seed_value, at, depth)
		if _prefetch != null and _prefetch.matches(node, seed_value, at, depth):
			_current.job = _prefetch
			_prefetch = null
		elif cached != null and cached.layout != null and cached.layout.signature == node.buildings:
			_current.prepared = cached
			_apply_prepared(_current)
		else:
			_current.job = PrepJob.new(node, seed_value, at, cached, depth)
	while _outgoing.size() > MAX_OUTGOING:
		var faintest := _outgoing[0]
		for layer in _outgoing:
			if layer.alpha < faintest.alpha:
				faintest = layer
		_outgoing.erase(faintest)
		_drop(faintest)
	_place_layers()
	return shift


## Prepara un nodo **antes** de cruzar a él: la cámara avisa (`ScaleCamera.crossing_target`)
## mientras el jugador se aleja o se acerca, y aquí se va adelantando por trozos en `advance`.
## Cuando llegue el cruce, terreno, textura y `Layout` ya estarán en la caché.
func prefetch(node: SimNode, state: WorldState) -> void:
	if node == null or state == null:
		return
	var seed_value := state.terrain_seed()
	var at := state.world_pos_of(node)
	var depth := state.depth_of(node)
	if _current != null and _current.node_id == node.id and _current.world_seed == seed_value:
		return
	if _prefetch != null and _prefetch.matches(node, seed_value, at, depth):
		return
	var cached := _cache_find(node, seed_value, at, depth, false)
	if cached != null and cached.layout != null and cached.layout.signature == node.buildings:
		return
	_prefetch = PrepJob.new(node, seed_value, at, cached, depth)


## Termina **en el acto** el cambio de foco en curso: prepara, calienta y funde. Para las
## capturas y los tests, que no esperan fotogramas.
func finish_transition() -> void:
	finish_preparation()
	if _current == null:
		return
	_current.alpha = 1.0
	_apply_alpha(_current)
	for layer in _outgoing:
		_drop(layer)
	_outgoing.clear()
	_fade_hold = -1.0


## Prepara y calienta el destino en el acto, pero sin fundir: el origen sigue entero.
func finish_preparation() -> void:
	if _current == null or _current.ready:
		return
	_finish_prep(_current)
	_prepare_step(_current, 0.0, 0x7fffffffffffffff)


## Congela el fundido en la fracción `t` (0 = solo el origen, 1 = solo el destino). Para
## fotografiar el cruce a medias (`--shot-fade`).
func hold_fade(t: float) -> void:
	finish_preparation()
	_fade_hold = clampf(t, 0.0, 1.0)
	if _current != null:
		_current.alpha = _fade_hold
		_apply_alpha(_current)
	for layer in _outgoing:
		layer.alpha = 1.0 - _fade_hold
		_apply_alpha(layer)


## La capa del foco está lista (aunque aún se esté fundiendo).
func focus_ready() -> bool:
	return _current != null and _current.ready


## Opacidad del foco: la del fundido. La vista agregada (`ChildMapRenderer`) va con ella.
func focus_alpha() -> float:
	return _current.alpha if _current != null else 0.0


## Hay un cambio de foco a medias: preparándose o fundiéndose.
func is_transitioning() -> bool:
	return _current != null and (not _current.ready or not _outgoing.is_empty()
			or _current.alpha < 1.0)


func cache_size() -> int:
	return _cache.size()


## Vacía la caché de preparados: para medir el cruce en frío.
func clear_cache() -> void:
	_cache.clear()
	_prefetch = null


## Los puntos que se ven ahora mismo, de todas las capas: `[Villager, posición en el mundo en
## celdas, opacidad]`. Para comprobar que nadie salta durante un fundido (`crowd_test`). La
## opacidad es la que se **dibuja** —la del `modulate` de la capa—, no la que la capa cree tener.
func drawn_dots() -> Array:
	var out := []
	for layer in _layers():
		if layer.crowd == null or layer.content == null or not layer.content.visible:
			continue
		var layer_alpha := layer.content.modulate.a
		for villager in layer.crowd.villagers:
			var a := layer_alpha * villager.fade
			if a > 0.0:
				out.append([villager, Vector2(layer.center) + villager.position, a])
	return out


## Genera (o **amplía**) la ventana de terreno. Al promocionar solo cambia el tamaño de la
## ventana: como la generación está anclada en coordenadas de mundo, todo lo que ya se veía
## sale idéntico y alrededor aparece mundo nuevo. Los edificios y la gente ni se enteran,
## porque sus posiciones también son coordenadas de mundo.
##
## También se rehace si cambia la posición del nodo o el mundo. Si muere un hermano de id menor, una
## colonia puede recolocarse (la posición es derivada, ver `WorldState.world_pos_of`).
func _ensure_terrain(layer: Layer, state: WorldState) -> void:
	var node := layer.node
	var at := state.world_pos_of(node)
	var seed_value := state.terrain_seed()
	var depth := state.depth_of(node)
	# La semilla también: tras ascender la raíz conserva id y escala, pero es otro mundo.
	if layer.prepared != null and layer.prepared.fits(node, seed_value, at, depth):
		return
	# Promocionar es una acción del jugador y pasa una vez: se genera en el acto, como siempre.
	var job := PrepJob.new(node, seed_value, at, null, depth)
	job.step(0x7fffffffffffffff)
	layer.prepared = job.prepared
	layer.center = at
	layer.depth = depth
	if layer == _current:
		_origin = at
	_cache_put(layer.prepared)
	_apply_prepared(layer)
	_place_layers()


## Reconstruye los **edificios** del foco si han cambiado. La multitud no se toca aquí: converge
## sola en `advance()`, que es lo que impide que el pueblo se rebaraje cada vez que sube la
## población.
func refresh(node: SimNode) -> void:
	if node == null or _current == null:
		return
	_current.node = node
	# Sin estado no hay mundo del que sacar la ventana: `show_node` va siempre antes. Y mientras
	# se prepara, lo hace la preparación: al acabar se refresca.
	if _state == null or not _current.ready:
		return
	_refresh_layer(_current)


func _refresh_layer(layer: Layer) -> void:
	_ensure_terrain(layer, _state)
	var prepared := layer.prepared
	if prepared.layout == null:
		prepared.layout = Layout.build(layer.node, prepared.terrain, prepared.core())
		_rebuild_buildings(layer)
	elif prepared.layout.signature != layer.node.buildings:
		# Un `layout` vivo es de este nodo y de este terreno: cambiar de nodo o de ventana lo
		# anula. Si solo se ha construido, se continúa desde él en vez de recolocar el pueblo
		# entero —eran ~150 ms por edificio en un pueblo grande—, y sale lo mismo que con
		# `build`. Si algo ha bajado, se rehace: no es el caso que hay que hacer barato.
		prepared.layout = Layout.extend(prepared.layout, layer.node, prepared.terrain,
				prepared.core()) if _only_grew(prepared.layout.signature, layer.node.buildings) \
				else Layout.build(layer.node, prepared.terrain, prepared.core())
		_rebuild_buildings(layer)


static func _only_grew(before: PackedInt32Array, now: PackedInt32Array) -> bool:
	if before.size() != now.size():
		return false
	for i in now.size():
		if now[i] < before[i]:
			return false
	return true


func agent_count() -> int:
	if _current != null and _current.crowd != null and _current.ready:
		return _current.crowd.size()
	# Mientras se calienta, la cifra a la que va a llegar: el HUD no puede decir «0 puntos» medio
	# segundo cada vez que se cambia de foco.
	return crowd_params.dots_for(_current.node.pop) if _current != null and _current.node != null \
			else 0


func represents() -> float:
	if _current != null and _current.crowd != null and _current.ready:
		return _current.crowd.represents
	var dots := agent_count()
	return _current.node.pop / float(dots) if dots > 0 else 1.0


func crowd() -> Crowd:
	return _current.crowd if _current != null else null


func hour() -> float:
	var c := _light_crowd()
	return c.clock.hour() if c != null else 0.0


## Adelanta el reloj del pueblo hasta una hora concreta. Es para las capturas: poder
## fotografiar el amanecer, el mediodía y la noche sin esperar dos minutos por cada una.
## Mueve los relojes de todas las capas a la vez: se ven juntas y comparten la hora.
func set_hour(target_hour: float) -> void:
	var c := _light_crowd()
	if c == null:
		return
	var day := float(c.clock.day())
	var elapsed := (day + target_hour / 24.0) * crowd_params.seconds_per_day
	for layer in _layers():
		if layer.crowd != null:
			layer.crowd.clock.elapsed = elapsed
	# La luz se pone ya: si esperase al siguiente `advance`, la captura saldría con la del
	# fotograma anterior a mover el reloj.
	_update_light()


## Avanza la vida del pueblo `delta` **segundos reales** y la dibuja.
##
## Se llama cada fotograma, y le da igual la velocidad de simulación y la pausa: el pueblo
## sigue vivo mientras lo estés mirando. La convergencia hacia los números también se hace
## aquí, por tiempo real, para que a ×8 no converja ocho veces más rápido.
##
## Aquí avanza también el cambio de foco: la preparación del destino, con su plazo por
## fotograma, y el fundido.
func advance(delta: float) -> void:
	if _current == null:
		return
	if _current.ready and _current.crowd != null and _current.prepared != null:
		_current.reconciler.sync(_current.crowd, _current.node, _current.prepared.layout,
				crowd_params, delta)
		_current.crowd.advance(delta, crowd_params)
	# Las que se van siguen andando mientras se desvanecen, pero no se reconcilian con nada: su
	# nodo ya no se mira, y puede que ni exista.
	for layer in _outgoing:
		if layer.crowd != null:
			layer.crowd.advance(delta, crowd_params)

	var deadline := Time.get_ticks_usec() + PREP_BUDGET_USEC
	if not _current.ready:
		_prepare_step(_current, delta, deadline)
	elif _prefetch != null and _prefetch.step(deadline):
		_cache_put(_prefetch.prepared)
		_prefetch = null

	_advance_fade(delta)
	for layer in _layers():
		if layer.crowd != null and layer.alpha > 0.0:
			_draw_crowd(layer)
	_update_light()


## Rellena la multitud del foco de golpe y le da `seconds` de vida antes de dibujarla. Sirve
## para cargar una partida sin que el pueblo se vea vacío, y para el modo de captura.
func warm_up(seconds: float, step: float = WARM_STEP) -> void:
	if _current == null or not _current.ready or _current.crowd == null:
		return
	_current.reconciler.sync(_current.crowd, _current.node, _current.prepared.layout,
			crowd_params, step)
	var steps := int(seconds / step)
	for _i in steps:
		_current.crowd.advance(step, crowd_params)
	_update_light()
	_draw_crowd(_current)


# ---------------------------------------------------------------------------
# Capas, preparación y fundido
# ---------------------------------------------------------------------------

func _layers() -> Array[Layer]:
	var out: Array[Layer] = []
	out.append_array(_outgoing)
	if _current != null:
		out.append(_current)
	return out


func _make_layer(node: SimNode, seed_value: int, at: Vector2i, depth: int) -> Layer:
	var layer := Layer.new()
	layer.node = node
	layer.node_id = node.id
	layer.world_seed = seed_value
	layer.center = at
	layer.depth = depth
	layer.ground = Sprite2D.new()
	layer.ground.centered = false
	# Nearest: el terreno es color plano, y filtrarlo lo emborronaría al acercar el zoom.
	layer.ground.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	layer.ground.scale = Vector2.ONE * TILE
	_ground_root.add_child(layer.ground)
	layer.content = Node2D.new()
	_content_root.add_child(layer.content)
	for i in _building_textures.size():
		# Sin `modulate`: el sprite ya trae sus tres tonos, y son los del propio
		# `BuildingDef.color` porque el generador los deriva de ahí.
		var mm := _make_multimesh(Color.WHITE)
		mm.texture = _building_textures[i]
		layer.content.add_child(mm)
		layer.buildings.append(mm)
	layer.agents = _make_multimesh(Color.WHITE)
	layer.agents.texture = _villager_texture
	layer.agents.material = _villager_mat
	layer.content.add_child(layer.agents)
	_apply_alpha(layer)
	return layer


func _drop(layer: Layer) -> void:
	if layer.ground != null:
		layer.ground.queue_free()
	if layer.content != null:
		layer.content.queue_free()
	layer.ground = null
	layer.content = null
	layer.crowd = null
	layer.reconciler = null


## Cada capa donde está su nodo en el mundo, respecto al foco; y el foco, encima de todo.
func _place_layers() -> void:
	for layer in _layers():
		var offset := Vector2(layer.center - _origin) * TILE
		layer.content.position = offset
		var extent := float(layer.prepared.terrain.extent()) if layer.prepared != null \
				and layer.prepared.terrain != null else 0.0
		layer.ground.position = offset - Vector2.ONE * extent * TILE
	if _current != null:
		_ground_root.move_child(_current.ground, -1)
		_content_root.move_child(_current.content, -1)


func _apply_prepared(layer: Layer) -> void:
	layer.ground.texture = layer.prepared.texture
	_place_layers()
	if layer.prepared.layout != null:
		_rebuild_buildings(layer)


## Toda la preparación de una capa en el acto (al arrancar, y en capturas y tests).
func _finish_prep(layer: Layer) -> void:
	if layer.prepared == null and layer.job == null:
		layer.job = PrepJob.new(layer.node, layer.world_seed, layer.center,
				_cache_find(layer.node, layer.world_seed, layer.center, layer.depth), layer.depth)
	if layer.job != null:
		layer.job.step(0x7fffffffffffffff)
		layer.prepared = layer.job.prepared
		layer.job = null
		_cache_put(layer.prepared)
		_apply_prepared(layer)


## La multitud de una capa, desde la semilla de su nodo. `elapsed` es la hora de su reloj.
func _start_crowd(layer: Layer, elapsed: float) -> void:
	layer.crowd = Crowd.new(layer.node.seed ^ 0x9e3779b9)
	layer.crowd.clock.elapsed = elapsed
	layer.reconciler = CrowdReconciler.new()


## Un trozo de la preparación del foco: lo que quede del terreno y el `Layout`, y luego el
## `warm_up` de su multitud, hasta el plazo. Al acabar, la capa está lista y empieza el fundido.
func _prepare_step(layer: Layer, delta: float, deadline_usec: int) -> void:
	if layer.job != null:
		if not layer.job.step(deadline_usec):
			return
		layer.prepared = layer.job.prepared
		layer.job = null
		_cache_put(layer.prepared)
		_apply_prepared(layer)
	if layer.crowd == null:
		# El reloj nuevo arranca `warm_up_seconds` por detrás del que se ve, y el `warm_up` lo
		# pone a su altura: las dos multitudes comparten la hora y la luz no salta al cruzar.
		var light := _light_crowd()
		var now := light.clock.elapsed if light != null else warm_up_seconds
		_start_crowd(layer, maxf(now - warm_up_seconds, 0.0))
		layer.warm_debt = warm_up_seconds
		layer.reconciler.sync(layer.crowd, layer.node, layer.prepared.layout, crowd_params,
				WARM_STEP)
	# Lo que pasa de tiempo real mientras se calienta también se le debe: al enseñarse, va a la
	# misma hora que el resto.
	layer.warm_debt += delta
	while layer.warm_debt >= WARM_STEP:
		layer.crowd.advance(WARM_STEP, crowd_params)
		layer.warm_debt -= WARM_STEP
		if Time.get_ticks_usec() >= deadline_usec:
			return
	layer.ready = true
	_refresh_layer(layer)
	focus_shown.emit()


## El destino sube y lo que se va baja, al mismo ritmo, y solo cuando el destino está listo: un
## fundido hacia algo que aún no está es un hueco. Lo que llega a 0 se libera.
func _advance_fade(delta: float) -> void:
	if _fade_hold >= 0.0 or not _current.ready:
		return
	var rate := delta / FADE_SECONDS
	if _current.alpha < 1.0:
		_current.alpha = minf(_current.alpha + rate, 1.0)
		_apply_alpha(_current)
	var gone: Array[Layer] = []
	for layer in _outgoing:
		layer.alpha = maxf(layer.alpha - rate, 0.0)
		_apply_alpha(layer)
		if layer.alpha <= 0.0:
			gone.append(layer)
	for layer in gone:
		_outgoing.erase(layer)
		_drop(layer)


## El contenido (edificios y gente) va a la opacidad del fundido. El terreno, al doble: el del
## destino es opaco a mitad de camino y el del origen no empieza a irse hasta entonces. Donde
## se solapan son el mismo suelo (el terreno es compartido), y así nunca se ve el fondo a través
## de dos terrenos medio transparentes.
func _apply_alpha(layer: Layer) -> void:
	if layer.ground == null:
		return
	layer.ground.modulate.a = minf(layer.alpha * 2.0, 1.0)
	layer.content.modulate.a = layer.alpha
	layer.ground.visible = layer.alpha > 0.0
	layer.content.visible = layer.alpha > 0.0


## La multitud cuyo reloj manda la luz: la del foco si ya se ve, y si no, la más visible de las
## que se van.
func _light_crowd() -> Crowd:
	if _current != null and _current.ready and _current.crowd != null:
		return _current.crowd
	var best: Layer = null
	for layer in _outgoing:
		if layer.crowd != null and (best == null or layer.alpha > best.alpha):
			best = layer
	if best != null:
		return best.crowd
	return _current.crowd if _current != null else null


# ---------------------------------------------------------------------------
# Caché
# ---------------------------------------------------------------------------

func _cache_find(node: SimNode, seed_value: int, at: Vector2i, depth: int,
		touch := true) -> Prepared:
	for i in _cache.size():
		var p := _cache[i]
		if p.fits(node, seed_value, at, depth):
			if touch:
				_cache.remove_at(i)
				_cache.append(p)
			return p
	return null


func _cache_put(p: Prepared) -> void:
	for i in range(_cache.size() - 1, -1, -1):
		var q := _cache[i]
		if q == p or (q.node_id == p.node_id and q.world_seed == p.world_seed):
			_cache.remove_at(i)
	_cache.append(p)
	while _cache.size() > CACHE_SIZE:
		_cache.remove_at(0)


## Fuera lo que ya no puede servir: nodos muertos y mundos de otra era.
func _prune_cache(state: WorldState) -> void:
	var seed_value := state.terrain_seed()
	for i in range(_cache.size() - 1, -1, -1):
		var p := _cache[i]
		if p.world_seed != seed_value or state.get_node_by_id(p.node_id) == null:
			_cache.remove_at(i)
	if _prefetch != null and (_prefetch.prepared.world_seed != seed_value
			or state.get_node_by_id(_prefetch.prepared.node_id) == null):
		_prefetch = null


# ---------------------------------------------------------------------------
# Dibujo
# ---------------------------------------------------------------------------

## Tiñe la vista según la hora del **reloj del pueblo**, nunca según `state.cycle`: la noche
## llega igual con el juego en pausa o a ×8, como la rutina de la gente que la duerme.
func _update_light() -> void:
	var c := _light_crowd()
	if c == null:
		return
	_light.color = crowd_params.light_tint(c.clock.daylight())


func _rebuild_buildings(layer: Layer) -> void:
	var counts := PackedInt32Array()
	counts.resize(Content.building_count())
	var placed := layer.prepared.layout
	for p in placed.placements:
		counts[p.building] += 1
	for i in layer.buildings.size():
		layer.buildings[i].multimesh.instance_count = counts[i]
	var cursor := PackedInt32Array()
	cursor.resize(Content.building_count())
	for p in placed.placements:
		var def := Content.building(p.building)
		var mm := layer.buildings[p.building].multimesh
		var size := def.footprint * TILE
		var pos := (Vector2(p.cell) + Vector2(0.5, 0.5)) * TILE
		var xform := Transform2D(0.0, size, 0.0, pos)
		mm.set_instance_transform_2d(cursor[p.building], xform)
		mm.set_instance_color(cursor[p.building], Color.WHITE)
		cursor[p.building] += 1


func _draw_crowd(layer: Layer) -> void:
	var c := layer.crowd
	var mm := layer.agents.multimesh
	if mm.instance_count != c.size():
		mm.instance_count = c.size()
	# Un pelo mayor que media celda de edificio: con el pueblo denso, la gente tiene que
	# leerse por encima de los tejados.
	var dot := Vector2.ONE * TILE * 0.36
	var elapsed := c.clock.elapsed
	for i in c.villagers.size():
		var villager: Villager = c.villagers[i]
		# Volteo por el sentido de la marcha, con una escala X negativa. No hace falta shader
		# para esto, y que la gente mire hacia donde anda es la mitad de lo que hace que un
		# punto parezca alguien.
		var scale := dot
		if villager.velocity.x < -0.01:
			scale.x = -scale.x
		mm.set_instance_transform_2d(i,
			Transform2D(0.0, scale, 0.0, villager.position * TILE))
		mm.set_instance_color(i, _villager_color(villager))
		mm.set_instance_custom_data(i, Color(float(_villager_frame(villager, elapsed)), 0, 0, 0))


## Qué pose le toca. Cuatro no dan para un ciclo de andar de verdad, y no hacen falta: la vida
## la da la inercia del movimiento, no el número de fotogramas.
static func _villager_frame(villager: Villager, elapsed: float) -> int:
	if villager.activity == Villager.Activity.SLEEPING:
		return FRAME_SLEEP
	if villager.velocity.length() < WALK_THRESHOLD:
		return FRAME_IDLE
	# La fase propia de cada uno evita que el pueblo entero pise con el mismo pie.
	var phase := elapsed * STEP_CADENCE + villager.wobble_phase
	return FRAME_WALK_A if int(phase) % 2 == 0 else FRAME_WALK_B


## El color dice el oficio; el brillo dice qué está haciendo. Quien no tiene puesto se ve
## apagado, y eso es información de juego: significa que sobran brazos para los puestos que
## hay. La opacidad hace de desvanecimiento al llegar y al marcharse.
static func _villager_color(villager: Villager) -> Color:
	var base := Color(0.80, 0.80, 0.78)
	if villager.job >= 0:
		base = Content.building(villager.job).color
	var color := base
	match villager.activity:
		Villager.Activity.WORKING:
			color = base.lightened(0.45)
		Villager.Activity.COMMUTING, Villager.Activity.ERRAND:
			color = base.lightened(0.2)
		Villager.Activity.CHATTING:
			color = base.lightened(0.3)
		Villager.Activity.SLEEPING:
			color = base.darkened(0.62)
		Villager.Activity.WANDERING, Villager.Activity.LINGERING, Villager.Activity.BREAK:
			color = base.darkened(0.3).lerp(Color(0.45, 0.45, 0.45), 0.45)
		_:
			color = base.darkened(0.35)
	color.a = villager.fade
	return color
