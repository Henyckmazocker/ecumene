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

## Píxeles de mundo por celda de terreno.
const TILE := 16.0

var terrain: TerrainGen.Terrain
var layout: Layout.Result
var crowd_params := CrowdParams.new()

var _crowd: Crowd
var _reconciler := CrowdReconciler.new()
var _node: SimNode = null
var _terrain_sprite: Sprite2D
var _building_meshes: Array[MultiMeshInstance2D] = []
var _agent_mesh: MultiMeshInstance2D
var _node_id: int = -1
var _quad: QuadMesh


func _ready() -> void:
	_quad = QuadMesh.new()
	_quad.size = Vector2.ONE

	_terrain_sprite = Sprite2D.new()
	_terrain_sprite.centered = false
	# Nearest: los biomas son color plano, y filtrarlos los emborronaría al acercar el zoom.
	_terrain_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(_terrain_sprite)

	for i in Content.building_count():
		var mm := _make_multimesh(Content.building(i).color)
		add_child(mm)
		_building_meshes.append(mm)

	_agent_mesh = _make_multimesh(Color.WHITE)
	add_child(_agent_mesh)


func _make_multimesh(modulate_color: Color) -> MultiMeshInstance2D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.mesh = _quad
	var inst := MultiMeshInstance2D.new()
	inst.multimesh = mm
	inst.modulate = modulate_color
	return inst


## Tamaño del mapa en píxeles de mundo, para acotar el paneo de la cámara.
func world_size() -> float:
	return float(terrain.size) * TILE if terrain != null else 0.0


func center_world() -> Vector2:
	return Vector2.ONE * world_size() * 0.5


## Lo que hay que tener en pantalla: la mancha construida, no el mapa entero.
##
## Encuadrar el mapa completo era el defecto obvio y estaba mal: a esa distancia los
## habitantes son un píxel y desaparece justamente lo que este juego tiene que enseñar. El
## encuadre por defecto es el asentamiento, y alejarse hasta ver la isla es cosa del jugador.
func settlement_extent() -> Rect2:
	var center := center_world()
	# Mínimo de 22 celdas de lado: un asentamiento recién fundado no puede llenar la pantalla
	# con dos edificios, pero tampoco tiene que verse desde el espacio.
	var rect := Rect2(center - Vector2.ONE * TILE * 11.0, Vector2.ONE * TILE * 22.0)
	if layout != null:
		for p in layout.placements:
			rect = rect.expand((Vector2(p.cell) + Vector2(0.5, 0.5)) * TILE)
	return rect.grow(TILE * 3.0)


## Muestra un nodo. Regenera el terreno solo si ha cambiado de nodo — es lo caro.
func show_node(node: SimNode) -> void:
	if node == null:
		return
	if node.id != _node_id:
		_node_id = node.id
		terrain = TerrainGen.generate(node.seed, node.tier)
		var tex := ImageTexture.create_from_image(TerrainGen.to_image(terrain))
		_terrain_sprite.texture = tex
		_terrain_sprite.scale = Vector2.ONE * TILE
		layout = null
		# Cambiar de nodo sí tira la multitud: es otro pueblo, otra gente.
		_crowd = Crowd.new(node.seed ^ 0x9e3779b9)
		_reconciler = CrowdReconciler.new()
	_node = node
	refresh(node)


## Reconstruye los **edificios** si han cambiado. La multitud no se toca aquí: converge sola
## en `advance()`, que es lo que impide que el pueblo se rebaraje cada vez que sube la
## población.
func refresh(node: SimNode) -> void:
	if node == null or terrain == null:
		return
	_node = node
	if layout == null or layout.signature != node.buildings:
		layout = Layout.build(node, terrain)
		_rebuild_buildings()


func agent_count() -> int:
	return _crowd.size() if _crowd != null else 0


func represents() -> float:
	return _crowd.represents if _crowd != null else 1.0


func crowd() -> Crowd:
	return _crowd


func hour() -> float:
	return _crowd.clock.hour() if _crowd != null else 0.0


## Adelanta el reloj del pueblo hasta una hora concreta. Es para las capturas: poder
## fotografiar el amanecer, el mediodía y la noche sin esperar dos minutos por cada una.
func set_hour(target_hour: float) -> void:
	if _crowd == null:
		return
	var day := float(_crowd.clock.day())
	_crowd.clock.elapsed = (day + target_hour / 24.0) * crowd_params.seconds_per_day


func _rebuild_buildings() -> void:
	var counts := PackedInt32Array()
	counts.resize(Content.building_count())
	for p in layout.placements:
		counts[p.building] += 1
	for i in _building_meshes.size():
		_building_meshes[i].multimesh.instance_count = counts[i]
	var cursor := PackedInt32Array()
	cursor.resize(Content.building_count())
	for p in layout.placements:
		var def := Content.building(p.building)
		var mm := _building_meshes[p.building].multimesh
		var size := def.footprint * TILE
		var pos := (Vector2(p.cell) + Vector2(0.5, 0.5)) * TILE
		var xform := Transform2D(0.0, size, 0.0, pos)
		mm.set_instance_transform_2d(cursor[p.building], xform)
		mm.set_instance_color(cursor[p.building], Color.WHITE)
		cursor[p.building] += 1


## Avanza la vida del pueblo `delta` **segundos reales** y la dibuja.
##
## Se llama cada fotograma, y le da igual la velocidad de simulación y la pausa: el pueblo
## sigue vivo mientras lo estés mirando. La convergencia hacia los números también se hace
## aquí, por tiempo real, para que a ×8 no converja ocho veces más rápido.
func advance(delta: float) -> void:
	if _crowd == null or terrain == null:
		return
	_reconciler.sync(_crowd, _node, layout, terrain.center(), crowd_params, delta)
	_crowd.advance(delta, crowd_params)
	_draw_crowd()


## Rellena la multitud de golpe y le da `seconds` de vida antes de dibujarla. Sirve para
## cargar una partida sin que el pueblo se vea vacío, y para el modo de captura.
func warm_up(seconds: float, step: float = 0.05) -> void:
	if _crowd == null or terrain == null:
		return
	_reconciler.sync(_crowd, _node, layout, terrain.center(), crowd_params, step)
	var steps := int(seconds / step)
	for _i in steps:
		_crowd.advance(step, crowd_params)
	_draw_crowd()


func _draw_crowd() -> void:
	var mm := _agent_mesh.multimesh
	if mm.instance_count != _crowd.size():
		mm.instance_count = _crowd.size()
	# Un pelo mayor que media celda de edificio: con el pueblo denso, la gente tiene que
	# leerse por encima de los tejados.
	var dot := Vector2.ONE * TILE * 0.36
	for i in _crowd.villagers.size():
		var villager: Villager = _crowd.villagers[i]
		mm.set_instance_transform_2d(i,
			Transform2D(0.0, dot, 0.0, villager.position * TILE))
		mm.set_instance_color(i, _villager_color(villager))


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
