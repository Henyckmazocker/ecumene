class_name AgentMaterializer
extends RefCounted

## Convierte un nodo agregado en habitantes visibles.
##
## Es el puente del pacto central del proyecto: **el agregado es la verdad, los agentes son
## una dramatización determinista de él**. Aquí no se inventa nada — el reparto de oficios que
## se ve en pantalla es exactamente el que `Integrator` está usando para calcular la
## producción, y las casas y los puestos salen del `Layout`.
##
## Solo se materializa el nodo enfocado. Los otros miles siguen siendo vectores de stats.

## Tope de puntos en pantalla. Por encima, cada habitante visible **representa a varios**:
## es lo que permite mirar una ciudad de 10.000 sin que el móvil se caiga.
const MAX_AGENTS := 400


class Crowd:
	extends RefCounted
	var agents: Array[Agent] = []
	## Cuántos habitantes reales representa cada punto en pantalla.
	var represents: float = 1.0
	## Huella del estado que generó esta multitud: si no cambia, no hay que rehacerla.
	var signature: PackedInt32Array = PackedInt32Array()
	var signature_pop: int = 0

	func matches(node: SimNode) -> bool:
		return signature == node.buildings and signature_pop == _bucket(node.pop)

	static func _bucket(pop: float) -> int:
		# Rematerializar con cada decimal de población sería absurdo: se hace por escalones.
		return int(round(pop))


## Materializa los habitantes de un nodo. `null` en `layout` (aún sin terreno) devuelve una
## multitud vacía en vez de fallar.
static func materialize(node: SimNode, layout: Layout.Result, center: Vector2i) -> Crowd:
	var crowd := Crowd.new()
	crowd.signature = node.buildings.duplicate()
	crowd.signature_pop = Crowd._bucket(node.pop)
	if layout == null or node.pop <= 0.0:
		return crowd

	var visible := mini(int(ceil(node.pop)), MAX_AGENTS)
	if visible <= 0:
		return crowd
	crowd.represents = node.pop / float(visible)

	# Un RNG propio sembrado por el nodo: la misma partida dibuja siempre la misma gente en
	# los mismos sitios, en cualquier plataforma.
	var rng := RandomNumberGenerator.new()
	rng.seed = node.seed ^ 0x9e3779b9

	var homes := _home_cells(node, layout, center)
	var workers := Integrator.effective_workers(node)

	# Cuántos puntos se van a cada oficio, en proporción a los trabajadores efectivos que el
	# agregado está usando de verdad.
	var assignments := PackedInt32Array()
	assignments.resize(node.buildings.size())
	var assigned := 0
	for bi in node.buildings.size():
		if workers[bi] <= 0.0:
			continue
		var want := int(round(workers[bi] / crowd.represents))
		want = mini(want, visible - assigned)
		assignments[bi] = want
		assigned += want
		if assigned >= visible:
			break

	for bi in node.buildings.size():
		var cells: Array = layout.cells_of(bi)
		for _i in assignments[bi]:
			crowd.agents.append(_make_agent(rng, homes, cells, bi, center))

	# El resto no tiene puesto: deambula. En pantalla se ve como gente ociosa, que es
	# información real — significa que sobran brazos para los puestos que hay.
	for _i in (visible - assigned):
		crowd.agents.append(_make_agent(rng, homes, [], -1, center))

	return crowd


static func _make_agent(
	rng: RandomNumberGenerator, homes: Array, work_cells: Array, job: int, center: Vector2i
) -> Agent:
	var a := Agent.new()
	a.job = job
	a.phase = rng.randf()
	a.speed = 5.0 + rng.randf() * 3.0
	a.wander = 1.0 + rng.randf() * 1.2
	var home_cell: Vector2i = homes[rng.randi() % homes.size()] if not homes.is_empty() else center
	a.home = Vector2(home_cell) + Vector2(rng.randf(), rng.randf()) * 0.6 + Vector2(0.2, 0.2)
	if not work_cells.is_empty():
		var work_cell: Vector2i = work_cells[rng.randi() % work_cells.size()]
		a.work = Vector2(work_cell) + Vector2(rng.randf(), rng.randf()) * 0.6 + Vector2(0.2, 0.2)
		a.has_work = true
	else:
		a.work = a.home
		a.has_work = false
	return a


## Dónde vive la gente: en las cabañas si las hay, y si no, apiñada en el centro.
static func _home_cells(node: SimNode, layout: Layout.Result, center: Vector2i) -> Array:
	var hut := Content.building_index("hut")
	var homes: Array = layout.cells_of(hut).duplicate() if hut >= 0 else []
	if homes.is_empty():
		homes = [center]
	return homes
