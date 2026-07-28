class_name SettlementView
extends Node2D

## La vista del nodo enfocado: terreno, edificios y habitantes.
##
## Solo **lee** del estado. No escribe una sola propiedad de `WorldState`, y no podría aunque
## quisiera: los agentes son funciones puras del ciclo de simulación (ver [Agent]).
##
## Todo va por `MultiMeshInstance2D` —un nodo de escena por *tipo*, no por habitante—, que es
## lo que hace que cientos de personas quepan en el presupuesto de un móvil de gama baja.

## Píxeles de mundo por celda de terreno.
const TILE := 16.0

var terrain: TerrainGen.Terrain
var layout: Layout.Result

var _crowd: AgentMaterializer.Crowd
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
		_crowd = null
	refresh(node)


## Reconstruye lo que haya cambiado. Barato de llamar cada tick: si las firmas coinciden, no
## hace nada.
func refresh(node: SimNode) -> void:
	if node == null or terrain == null:
		return
	if layout == null or layout.signature != node.buildings:
		layout = Layout.build(node, terrain)
		_rebuild_buildings()
		_crowd = null
	if _crowd == null or not _crowd.matches(node):
		_crowd = AgentMaterializer.materialize(node, layout, terrain.center())
		_agent_mesh.multimesh.instance_count = _crowd.agents.size()


func agent_count() -> int:
	return _crowd.agents.size() if _crowd != null else 0


func represents() -> float:
	return _crowd.represents if _crowd != null else 1.0


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


## Coloca a los habitantes en el instante `cycle`. Se llama por fotograma, pero cada agente
## cuesta una evaluación aritmética y un `set_instance_transform_2d`: sin física, sin árbol
## de escena y sin estado que mantener.
func update_agents(cycle: float) -> void:
	if _crowd == null:
		return
	var mm := _agent_mesh.multimesh
	# Un pelo mayor que media celda de edificio: con el pueblo denso, la gente tiene que
	# leerse por encima de los tejados o el hito no cumple su función.
	var dot := Vector2.ONE * TILE * 0.36
	for i in _crowd.agents.size():
		var agent: Agent = _crowd.agents[i]
		var sample := agent.sample(cycle)
		var pos: Vector2 = sample[0] * TILE
		mm.set_instance_transform_2d(i, Transform2D(0.0, dot, 0.0, pos))
		mm.set_instance_color(i, _agent_color(agent, sample[1]))


## El color dice el oficio; el brillo dice qué está haciendo. Quien vaguea se ve apagado, y
## eso es información: significa que sobran brazos para los puestos que hay.
static func _agent_color(agent: Agent, state: int) -> Color:
	var base := Color(0.80, 0.80, 0.78)
	if agent.job >= 0:
		base = Content.building(agent.job).color
	match state:
		Agent.State.WORKING:
			return base.lightened(0.45)
		Agent.State.COMMUTE_OUT, Agent.State.COMMUTE_HOME:
			return base.lightened(0.2)
		Agent.State.IDLE:
			return base.darkened(0.3).lerp(Color(0.45, 0.45, 0.45), 0.6)
		_:
			return base.darkened(0.5)
