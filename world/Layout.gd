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

	## El terreno sobre el que se colocó y lo que se le ha preguntado, memorizado. Se pasa de un
	## resultado al siguiente para que [method Layout.extend] no vuelva a preguntárselo, y le
	## dice si `prev` es del mismo terreno.
	var _ground: Ground = null

	func cells_of(building_index: int) -> Array:
		return by_building.get(building_index, [])


## Lo que la búsqueda pregunta al terreno, memorizado. No depende de qué hay construido, así
## que vale para todos los layouts de un mismo terreno.
class Ground:
	extends RefCounted
	var terrain: TerrainGen.Terrain
	## Radio del núcleo ([method Layout.core_radius]): fuera de este disco no se coloca nada. Va
	## aquí y no en la ocupación porque, como el terreno, decide qué celdas son candidatas, y
	## [method Layout.extend] solo puede continuar un layout con el mismo.
	var core: float = INF
	## Anillo → celdas edificables (y dentro del núcleo), en el orden de `_ring_cells`.
	var rings := {}
	## id de edificio → (celda → ¿es edificable la huella entera con el ancla ahí?).
	var fit := {}

	func _init(on: TerrainGen.Terrain, radius: float = INF) -> void:
		terrain = on
		core = radius

	## El último anillo que puede tener alguna celda del núcleo.
	func last_ring() -> int:
		return Layout.MAX_RING - 1 if core >= float(Layout.MAX_RING) \
				else mini(int(floor(core)), Layout.MAX_RING - 1)

	func buildable_in(ring: int) -> Array:
		var cells = rings.get(ring)
		if cells == null:
			cells = []
			# Disco y no cuadrado: el anillo de búsqueda es de Chebyshev, pero una ciudad con
			# esquinas se lee como una cuadrícula, y el anillo de las colonias (`WorldState`)
			# es redondo; con el disco, la distancia del borde de la ciudad a ellas es la misma
			# en todas direcciones.
			var core_sq := core * core
			for cell in Layout._ring_cells(Vector2i.ZERO, ring):
				if float(cell.x * cell.x + cell.y * cell.y) <= core_sq \
						and terrain.is_buildable(cell):
					cells.append(cell)
			rings[ring] = cells
		return cells

	## ¿Cabe `def` con el ancla en esta celda, por el terreno solo? Sí si **toda** la huella es
	## edificable. Toda la huella y no solo el ancla: mirar solo el ancla era exactamente el bug
	## del solapamiento.
	func fits(def: BuildingDef, cell: Vector2i) -> bool:
		var of_def = fit.get(def.id)
		if of_def == null:
			of_def = {}
			fit[def.id] = of_def
		var known = of_def.get(cell)
		if known != null:
			return known
		var value := true
		var bleed := Layout.bleed_of(def)
		for dy in range(-bleed.y, bleed.y + 1):
			for dx in range(-bleed.x, bleed.x + 1):
				if not terrain.is_buildable(cell + Vector2i(dx, dy)):
					value = false
		of_def[cell] = value
		return value


## La ocupación mientras se coloca, con las celdas libres de cada anillo a mano.
##
## Lo caro de colocar no era reservar sino **buscar**: el primer ejemplar de cada tipo empieza
## en el anillo 1 y cruza todo el núcleo, que en un pueblo lleno no tiene una sola celda libre.
## Llevando la lista de libres por anillo, cruzar un anillo lleno no cuesta nada, y la búsqueda
## da lo mismo que antes porque recorre las candidatas en el mismo orden.
class Occupancy:
	extends RefCounted
	var ground: Ground
	var center := Vector2i.ZERO
	var occupied := {}
	## Anillo → celdas edificables y aún libres, en ese mismo orden. Se calcula al primer
	## paso por el anillo y desde ahí lo mantiene `reserve`.
	var _free := {}

	func _init(on: Ground) -> void:
		ground = on

	func free_in(ring: int) -> Array:
		var free = _free.get(ring)
		if free != null:
			return free
		free = []
		for cell in ground.buildable_in(ring):
			if not occupied.has(cell):
				free.append(cell)
		_free[ring] = free
		return free

	## Marca como ocupadas la huella del edificio **y su hueco**.
	func reserve(cell: Vector2i, def: BuildingDef) -> void:
		var reach := Layout.bleed_of(def) + Vector2i(Layout.GAP, Layout.GAP)
		for dy in range(-reach.y, reach.y + 1):
			for dx in range(-reach.x, reach.x + 1):
				var c := cell + Vector2i(dx, dy)
				if occupied.has(c):
					continue
				occupied[c] = true
				var free = _free.get(Layout._ring_of(center, c))
				if free != null:
					free.erase(c)

	## ¿Está libre toda la huella? Lo que el terreno permite lo dice `Ground.fits`; esto mira
	## solo los otros edificios. El hueco no se exige edificable: un edificio puede asomarse a
	## la orilla o al pie de un monte, solo no puede haber otro edificio ahí.
	func footprint_free(cell: Vector2i, bleed: Vector2i) -> bool:
		for dy in range(-bleed.y, bleed.y + 1):
			for dx in range(-bleed.x, bleed.x + 1):
				if occupied.has(cell + Vector2i(dx, dy)):
					return false
		return true


## Radio máximo de búsqueda en anillos alrededor del centro. Con hueco entre edificios el
## pueblo ocupa el doble de radio, así que el tope de 64 se quedaba corto en los tiers altos.
const MAX_RING := 96

## Celdas libres que se dejan alrededor de cada edificio.
##
## Es el mando de «cuánto aire» tiene el asentamiento. A 0 el pueblo vuelve a salir apiñado,
## con los edificios pared con pared; a 1 cada uno tiene su parcela.
const GAP := 1

## Centinela de «no hay sitio». **No puede ser una coordenada plausible**: al pasar el layout a
## coordenadas de mundo con signo, el `(-1, -1)` que se usaba antes se convirtió en una celda
## perfectamente válida pegada al centro, y la colocación se rendía tras el tercer edificio
## creyendo que el mapa estaba lleno.
const NO_SPOT := Vector2i(0x7fffffff, 0x7fffffff)


## Radio del núcleo por profundidad del nodo en el árbol: raíz, hijos, nietos y de ahí abajo.
## Lo elige la medición de M3b («Vista agregada y zoom continuo»): ver [method core_radius].
const CORE_BY_DEPTH := [40.0, 28.0, 20.0]


## Radio, en celdas, del disco donde caen los edificios de un nodo a esta profundidad.
##
## **Por profundidad y no por tier**, por lo mismo que el anillo de las colonias: la profundidad
## no cambia nunca, así que promocionar no mueve un solo edificio, y el anillo de los hijos
## (`WorldState._place_child`, justo fuera de este disco) tampoco salta. Sin núcleo, una ciudad
## llenaba su ventana entera y sus colonias caían encima de sus edificios. Lo que no quepa se
## queda sin dibujar (`NO_SPOT`), como al llenarse el mapa: existe en la simulación igual.
static func core_radius(depth: int) -> float:
	return CORE_BY_DEPTH[clampi(depth, 0, CORE_BY_DEPTH.size() - 1)]


## `core`: el de [method core_radius] para la profundidad del nodo. Sin él (`INF`), sin
## núcleo: solo lo limita la ventana de terreno; es lo que usan los tests que no tienen árbol.
static func build(node: SimNode, terrain: TerrainGen.Terrain, core: float = INF) -> Result:
	return _place(null, node, terrain, core)


## Lo mismo que [method build], pero aprovechando un resultado anterior del **mismo nodo sobre
## el mismo terreno**: devuelve exactamente lo que daría `build` con los edificios de ahora.
## Es lo que usa la vista cada vez que se construye algo, para no recolocar el pueblo entero.
##
## No es un atajo aproximado. `build` coloca por tipo y por ejemplar, y cada colocación solo
## depende de la ocupación que dejaron las anteriores, así que mientras un tipo tenga los
## mismos ejemplares que en `prev` y todo lo de delante esté igual, sus celdas son las mismas
## y basta con reservarlas, sin buscar. Del primer tipo que crece en adelante sí hay que buscar:
## su ejemplar nuevo ocupa sitio que los tipos siguientes podían haber elegido, y para que un
## `build` en frío —al recargar, al volver a entrar— dé el mismo pueblo, se recolocan igual que
## lo haría él. Que eso salga barato lo pone [class Occupancy], no este atajo.
##
## Si `prev` es de otro terreno, de otro núcleo o de otro catálogo de edificios, se hace un
## `build` entero.
static func extend(prev: Result, node: SimNode, terrain: TerrainGen.Terrain,
		core: float = INF) -> Result:
	if prev == null or prev._ground.terrain != terrain or prev._ground.core != core \
			or prev.signature.size() != node.buildings.size():
		return build(node, terrain, core)
	return _place(prev, node, terrain, core)


## La colocación de verdad, compartida por [method build] y [method extend]: con `prev` nulo
## es un `build`; con `prev`, copia lo que no ha cambiado y busca solo desde el primer cambio.
static func _place(prev: Result, node: SimNode, terrain: TerrainGen.Terrain,
		core: float) -> Result:
	var result := Result.new()
	result.signature = node.buildings.duplicate()
	# Lo que solo depende del terreno (y del núcleo) se hereda de `prev`: no se vuelve a
	# preguntar al terreno por cada celda.
	result._ground = prev._ground if prev != null else Ground.new(terrain, core)
	var space := Occupancy.new(result._ground)
	space.occupied[space.center] = true  # el centro del asentamiento queda libre de edificios
	## ¿La ocupación ya difiere de la que tenía `prev` en este punto? Desde que difiere, ya no
	## se puede copiar nada de `prev`: todo se busca de nuevo, como en `build`. Sin `prev`,
	## difiere desde el principio.
	var diverged := prev == null

	# Orden fijo por índice de edificio y por ejemplar: es lo que hace que ampliar sea
	# estable. Cambiar este orden re-dibujaría asentamientos ya existentes.
	for building_index in node.buildings.size():
		var count := node.buildings[building_index]
		if count <= 0:
			if not diverged and prev.signature[building_index] > 0:
				diverged = true  # se ha ido un tipo entero: deja sitio libre
			continue
		var def := Content.building(building_index)
		var cells: Array = []
		# Desde dónde empieza a buscar el siguiente ejemplar. Se arrastra del anterior en vez
		# de estimarse: los ejemplares de un tipo se colocan en orden, así que el siguiente
		# está más o menos donde cayó el anterior, y no hay que rebarrer el núcleo lleno para
		# poner el edificio número 100.
		#
		# Empezar en el anillo del anterior y no antes da lo mismo que empezar en el 1: los
		# anillos de dentro no tenían sitio para esta huella, y la ocupación solo crece.
		var from_ring := 1
		var first := 0
		if not diverged:
			# Lo que ya estaba en `prev` con la misma ocupación delante cae en el mismo sitio:
			# se reserva tal cual, sin buscar.
			var old_cells: Array = prev.cells_of(building_index)
			var kept := mini(count, old_cells.size())
			for k in kept:
				var cell: Vector2i = old_cells[k]
				space.reserve(cell, def)
				_append(result, cells, building_index, cell)
			if kept > 0:
				from_ring = maxi(1, _ring_of(space.center, old_cells[kept - 1]))
			first = kept
			if kept < old_cells.size():
				diverged = true  # hay menos que antes: queda hueco que `prev` no tenía
			elif old_cells.size() < prev.signature[building_index]:
				# En `prev` este tipo ya no cabía. Con la misma ocupación tampoco cabe ahora,
				# así que `build` habría parado aquí igual y lo de detrás no cambia.
				first = count
		for instance in range(first, count):
			var cell := _find_spot(space, def, from_ring)
			if cell == NO_SPOT:
				break  # no cabe más: el núcleo (o el mapa) se ha llenado
			from_ring = maxi(1, _ring_of(space.center, cell))
			space.reserve(cell, def)
			_append(result, cells, building_index, cell)
			diverged = true
		result.by_building[building_index] = cells
	return result


static func _append(result: Result, cells: Array, building_index: int, cell: Vector2i) -> void:
	var p := Placement.new()
	p.building = building_index
	p.cell = cell
	result.placements.append(p)
	cells.append(cell)


## Cuánto se sale el dibujo de un edificio de su propia celda, en celdas.
##
## El quad se centra en el **centro** de la celda y mide `footprint`, así que una granja de 1.5
## de ancho se derrama un cuarto de celda por cada lado. Hasta `BLEED_TOLERANCE` se le deja
## asomarse al hueco sin contar la celda de al lado como suya; pasado eso, la cuenta. Los que
## miden 1,5 o menos devuelven 0.
## Lo que un edificio puede asomarse al hueco sin reservar la celda de al lado, en celdas.
##
## Con 0 —lo de antes— una huella de 1,1 se asomaba 0,05 a la celda vecina y la reservaba
## entera, y con el hueco encima cada edificio de más de una celda ocupaba 5×5. Casi todos los
## tipos miden entre 1 y 1,5, así que la ciudad tenía el doble de radio del que necesitaba: con
## 538 edificios, p95 de 56-58 celdas (M3b). Con 0,25 un edificio de hasta 1,5 celdas se queda
## en la suya y asoma al hueco, y la ciudad baja a 33-35.
##
## Lo que no se negocia sigue en pie: con `GAP` = 1, entre dos huellas **dibujadas** quedan
## siempre al menos `GAP − 2 × BLEED_TOLERANCE` = 0,5 celdas (`terrain_test`,
## `_buildings_never_overlap`, lo mide sobre la geometría de verdad).
const BLEED_TOLERANCE := 0.25

static func bleed_of(def: BuildingDef) -> Vector2i:
	return Vector2i(
		maxi(0, int(ceil((def.footprint.x - 1.0) * 0.5 - BLEED_TOLERANCE))),
		maxi(0, int(ceil((def.footprint.y - 1.0) * 0.5 - BLEED_TOLERANCE))))


## Busca la primera celda libre recorriendo anillos desde el centro.
##
## Crecimiento por anillos: el núcleo queda denso y la periferia dispersa, así el tamaño del
## asentamiento se lee de un vistazo sin mirar un solo número. Todas las celdas de tierra valen
## lo mismo, así que no hay nada que comparar: gana la primera donde cabe la huella, en el orden
## de los anillos.
##
## Solo mira las celdas **libres y edificables** de cada anillo ([method Occupancy.free_in]),
## en el mismo orden que [method _ring_cells]. Las demás no podían ganar —el ancla forma parte
## de la huella, que tiene que ser edificable y estar libre—, así que el resultado es el de
## recorrer el anillo entero; pero con el núcleo lleno, el primer ejemplar de cada tipo ya no
## paga ~15 ms por cruzarlo, y lo que pregunta al terreno se pregunta una sola vez.
static func _find_spot(space: Occupancy, def: BuildingDef, from_ring: int) -> Vector2i:
	var bleed := bleed_of(def)
	for ring in range(maxi(1, from_ring), space.ground.last_ring() + 1):
		for cell in space.free_in(ring):
			# «¿Cabe aquí?» partido en lo que dice el terreno (memorizado) y lo que dice la
			# ocupación: son filtros puros, su orden no cambia qué celda gana.
			if space.ground.fits(def, cell) and space.footprint_free(cell, bleed):
				return cell
	return NO_SPOT


## Distancia de anillo (Chebyshev) al centro — la misma métrica que usa [method _ring_cells].
static func _ring_of(center: Vector2i, cell: Vector2i) -> int:
	var d := (cell - center).abs()
	return maxi(d.x, d.y)


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
