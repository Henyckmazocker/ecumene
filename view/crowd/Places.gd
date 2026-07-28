class_name Places
extends RefCounted

## Los sitios a los que la gente va: casas, puestos de trabajo por oficio, destinos de recado
## (almacenes y mercados), la plaza y las salidas del pueblo.
##
## Se deriva del `Layout`, que es el mismo que dibuja los edificios. La gente no anda sobre un
## mapa inventado: va a los edificios que hay.

var homes: PackedVector2Array = PackedVector2Array()
## Índice de edificio -> puntos de trabajo.
var by_job: Dictionary = {}
## Almacenes y mercados: adonde se lleva y se recoge lo que se produce.
var errands: PackedVector2Array = PackedVector2Array()
## Centro del pueblo, donde se hacen los corrillos.
var plaza := Vector2.ZERO
## Puntos por fuera de la mancha construida: por ahí se llega y por ahí se va uno.
var outskirts: PackedVector2Array = PackedVector2Array()

const ERRAND_BUILDINGS := ["storehouse", "market"]


static func from_layout(layout: Layout.Result) -> Places:
	var places := Places.new()
	# El asentamiento vive en el origen del mundo: la plaza es el `(0, 0)`, mida lo que mida
	# la ventana de terreno que se esté dibujando.
	places.plaza = Vector2(0.5, 0.5)
	if layout == null:
		places.homes.append(places.plaza)
		places.outskirts.append(places.plaza + Vector2(10.0, 0.0))
		return places

	var errand_indices := []
	for id in ERRAND_BUILDINGS:
		var index := Content.building_index(id)
		if index >= 0:
			errand_indices.append(index)

	var bounds := Rect2(places.plaza, Vector2.ZERO)
	var hut := Content.building_index("hut")
	for p in layout.placements:
		var point := Vector2(p.cell) + Vector2(0.5, 0.5)
		bounds = bounds.expand(point)
		if p.building == hut:
			places.homes.append(point)
		if p.building in errand_indices:
			places.errands.append(point)
		if Content.building(p.building).is_workplace():
			if not places.by_job.has(p.building):
				places.by_job[p.building] = PackedVector2Array()
			places.by_job[p.building].append(point)

	# Sin cabañas todavía, la gente vive apiñada alrededor de la plaza.
	if places.homes.is_empty():
		places.homes.append(places.plaza)

	# Ocho salidas repartidas por fuera del pueblo. Que las altas y las bajas entren y salgan
	# andando por el borde es lo que hace que crecer se lea como gente que llega.
	var margin := maxf(bounds.size.length() * 0.25, 6.0)
	var ring := bounds.grow(margin)
	for i in 8:
		var angle := TAU * float(i) / 8.0
		places.outskirts.append(ring.get_center()
			+ Vector2(cos(angle), sin(angle)) * ring.size.length() * 0.5)
	return places


func has_job(job: int) -> bool:
	return by_job.has(job) and not (by_job[job] as PackedVector2Array).is_empty()


func work_point(job: int, rng: RandomNumberGenerator) -> Vector2:
	if not has_job(job):
		return plaza
	var points: PackedVector2Array = by_job[job]
	return points[rng.randi() % points.size()]


func home_point(rng: RandomNumberGenerator) -> Vector2:
	return homes[rng.randi() % homes.size()]


func errand_point(rng: RandomNumberGenerator) -> Vector2:
	if errands.is_empty():
		return plaza
	return errands[rng.randi() % errands.size()]


func outskirt_point(rng: RandomNumberGenerator) -> Vector2:
	if outskirts.is_empty():
		return plaza
	return outskirts[rng.randi() % outskirts.size()]


func nearest_outskirt(from: Vector2) -> Vector2:
	var best := plaza
	var best_distance := INF
	for point in outskirts:
		var d := from.distance_squared_to(point)
		if d < best_distance:
			best_distance = d
			best = point
	return best
