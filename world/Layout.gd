class_name Layout
extends RefCounted

## Dónde cae cada edificio sobre el terreno.
##
## El jugador **no coloca casilla a casilla**: dice cuántos edificios de cada tipo quiere y
## esto los sitúa. Determinista desde la semilla del nodo y el número de edificios, así que
## el mismo asentamiento se dibuja igual siempre, y añadir la granja nº 7 no mueve las seis
## anteriores — el mapa crece, no se baraja.
##
## Es puramente visual: el agregado no sabe ni le importa dónde está nada.
##
## Trabaja en **coordenadas de mundo** (el asentamiento está en el `(0, 0)`), no en índices de
## celda. Es lo que permite que al promocionar crezca la ventana sin que se mueva nada: el
## índice del centro pasa de 32 a 48, pero el mundo `(0, 0)` sigue siendo el mismo sitio.

class Placement:
	extends RefCounted
	var building: int = -1
	## Coordenada **de mundo**, no índice de celda.
	var cell: Vector2i = Vector2i.ZERO


class Result:
	extends RefCounted
	var placements: Array[Placement] = []
	## Celdas ocupadas por tipo de edificio, para que los agentes elijan destino.
	var by_building: Dictionary = {}
	## Huella de los edificios que la generaron: si no cambia, no hace falta recalcular.
	var signature: PackedInt32Array = PackedInt32Array()

	func cells_of(building_index: int) -> Array:
		return by_building.get(building_index, [])


## Radio máximo de búsqueda en anillos alrededor del centro.
const MAX_RING := 64

## Centinela de «no hay sitio». **No puede ser una coordenada plausible**: al pasar el layout a
## coordenadas de mundo con signo, el `(-1, -1)` que se usaba antes se convirtió en una celda
## perfectamente válida pegada al centro, y la colocación se rendía tras el tercer edificio
## creyendo que el mapa estaba lleno.
const NO_SPOT := Vector2i(0x7fffffff, 0x7fffffff)


static func build(node: SimNode, terrain: TerrainGen.Terrain) -> Result:
	var result := Result.new()
	result.signature = node.buildings.duplicate()

	var occupied := {}
	# El asentamiento está en el origen del mundo, mida lo que mida la ventana.
	var center := Vector2i.ZERO
	occupied[center] = true  # el centro del asentamiento queda libre de edificios

	# Orden fijo por índice de edificio y por ejemplar: es lo que hace que ampliar sea
	# estable. Cambiar este orden re-dibujaría asentamientos ya existentes.
	for building_index in node.buildings.size():
		var count := node.buildings[building_index]
		if count <= 0:
			continue
		var def := Content.building(building_index)
		var cells: Array = []
		for instance in count:
			var cell := _find_spot(terrain, occupied, center, def.id, instance)
			if cell == NO_SPOT:
				break  # no cabe más: el mapa se ha llenado
			occupied[cell] = true
			var p := Placement.new()
			p.building = building_index
			p.cell = cell
			result.placements.append(p)
			cells.append(cell)
		result.by_building[building_index] = cells
	return result


## Busca la mejor celda libre recorriendo anillos desde el centro.
##
## Crecimiento por anillos: el núcleo queda denso y la periferia dispersa, así el tamaño del
## asentamiento se lee de un vistazo sin mirar un solo número.
static func _find_spot(
	terrain: TerrainGen.Terrain, occupied: Dictionary, center: Vector2i,
	building_id: String, instance: int
) -> Vector2i:
	var best := NO_SPOT
	var best_score := -1.0
	# Empezar el anillo donde toca por número de ejemplar: no hace falta rebarrer el núcleo
	# ya lleno para colocar el edificio número 100.
	var start_ring := maxi(1, int(sqrt(float(instance) * 0.6)))
	for ring in range(start_ring, MAX_RING):
		for cell in _ring_cells(center, ring):
			if not terrain.is_buildable(cell) or occupied.has(cell):
				continue
			var score := Biomes.affinity(terrain.at(cell), building_id)
			if score <= 0.0:
				continue
			# Penalización suave por distancia: entre dos biomas igual de buenos, gana el
			# más cercano al núcleo.
			score -= float(ring) * 0.004
			if score > best_score:
				best_score = score
				best = cell
		# Un anillo con un sitio decente basta: seguir buscando dispersaría el pueblo.
		if best_score >= 0.85:
			return best
	return best


static func _ring_cells(center: Vector2i, radius: int) -> Array:
	var cells: Array = []
	if radius <= 0:
		return [center]
	for dx in range(-radius, radius + 1):
		cells.append(center + Vector2i(dx, -radius))
		cells.append(center + Vector2i(dx, radius))
	for dy in range(-radius + 1, radius):
		cells.append(center + Vector2i(-radius, dy))
		cells.append(center + Vector2i(radius, dy))
	return cells
