extends SceneTree
## ¿Dónde se estrella la economía contra su propio techo? Ejecutar con:
##   godot-4 --headless --path . -s res://tools/ceiling_dump.gd
##
## El coste de un edificio crece en **progresión geométrica** (`BuildingDef.cost_for`, factor
## `cost_growth`) y el almacenamiento crece **linealmente** con los almacenes construidos
## (`SimNode.storage_caps`). Dos curvas así se cruzan siempre: llega un ejemplar cuyo coste no
## cabe en el almacén, y a partir de ahí no se puede construir por mucho que se produzca.
##
## Este volcado dice en qué ejemplar pasa, para cada edificio y cada recurso.
##
## Y lo dice además **en habitantes**, que es la unidad en la que el muro se nota jugando: el
## muro de la cabaña nº 59 no se lee como «el pueblo se queda en 525 almas» hasta que alguien
## lo traduce, y sin traducirlo nadie lo cruza con el umbral de promoción de la escala. Eso es
## exactamente lo que dejó pasar un techo de 525 con un umbral de 1.000.

const TestUtil := preload("res://tools/TestUtil.gd")

func _init() -> void:
	var params := SimParams.new()
	var storehouse := Content.building_index("storehouse")

	for tier in [Content.SETTLEMENT, Content.TOWN, Content.CITY]:
		var reachable := max_storehouses(storehouse, tier, params)
		print("")
		print("=== %s — el almacén se bloquea a sí mismo en el nº %d ===" % [
			Content.tier(tier).name, reachable + 1,
		])
		for bi in Content.buildings_for_tier(tier):
			_report(Content.building(bi), storehouse, reachable, tier, params)
		_report_pop_ceiling(tier, params)
	quit(0)


## El techo de la escala **en habitantes**, al lado de lo que pide para promocionar.
##
## Se calcula con todo lo que el tope deja construir y todos los oficios cubiertos: es una cota
## superior, no una partida. Si ni así se llega al umbral, el umbral es inalcanzable.
func _report_pop_ceiling(tier: int, params: SimParams) -> void:
	var promote := Content.tier(tier).promote_pop
	for with_upgrades in [false, true]:
		var node := _maxed_node(tier, params, with_upgrades)
		var snap := Integrator.snapshot(node, params)
		var ceiling := snap.cap
		var verdict := "llega" if promote <= 0.0 or ceiling >= promote else "NO LLEGA"
		print("  techo %-12s %7.0f hab (aloja %.0f, come %.0f) — ascender pide %.0f: %s" % [
			"con mejoras" if with_upgrades else "sin mejoras",
			ceiling, snap.housing, snap.food_capacity, promote, verdict,
		])


## Un nodo con todo lo que el tope de almacén permite construir y todos los puestos cubiertos.
##
## Los almacenes primero y en rondas: cada uno sube el tope, y el tope es lo que decide si cabe
## el siguiente —el de cualquier tipo—. Con el resto ya no hay realimentación, así que basta
## con preguntarle a `wall_of` contra el tope final.
static func _maxed_node(tier: int, params: SimParams, with_upgrades: bool) -> SimNode:
	var node := SimNode.new()
	node.tier = tier
	node.buildings.resize(Content.building_count())
	node.jobs.resize(Content.building_count())
	if with_upgrades:
		for def in Upgrades.all():
			var d: Upgrades.Def = def
			if d.tier_min <= tier:
				node.upgrades.append(d.id)
		node.invalidate_effects()

	var storages := PackedInt32Array()
	for bi in Content.buildings_for_tier(tier):
		if _storage_total(Content.building(bi)) > 0.0:
			storages.append(bi)
	for _round in range(0, 600):
		var caps := node.storage_caps(params)
		var grew := false
		for bi in storages:
			if _fits(Construction.cost_of(node, bi), caps):
				node.buildings[bi] += 1
				grew = true
		if not grew:
			break

	var final_caps := node.storage_caps(params)
	for bi in Content.buildings_for_tier(tier):
		if not storages.has(bi):
			node.buildings[bi] = wall_of(bi, tier, final_caps)
		node.jobs[bi] = node.capacity_of(bi)
		node.pop += node.jobs[bi]
	return node


static func _storage_total(def: BuildingDef) -> float:
	var total := 0.0
	for i in Goods.COUNT:
		total += def.storage[i]
	return total


static func _fits(cost: PackedFloat64Array, caps: PackedFloat64Array) -> bool:
	for i in Goods.COUNT:
		if cost[i] > 0.0 and caps[i] != INF and cost[i] > caps[i]:
			return false
	return true


## Cuántos almacenes se pueden encadenar de verdad en una escala.
##
## El almacén es el edificio que sube el tope, así que se limita a sí mismo: el ejemplar nº n+1
## solo se puede pagar si cabe en el tope que dan los n anteriores.
static func max_storehouses(storehouse: int, tier: int, params: SimParams) -> int:
	var node := SimNode.new()
	node.tier = tier
	node.buildings.resize(Content.building_count())
	for owned in range(0, 400):
		node.buildings[storehouse] = owned
		var caps := node.storage_caps(params)
		var cost := Construction.cost_of(node, storehouse)
		for i in Goods.COUNT:
			if cost[i] > 0.0 and caps[i] != INF and cost[i] > caps[i]:
				return owned
	return 400


## En qué ejemplar se estrella un edificio contra el tope, dado un techo de almacenes.
##
## Recibe la escala y no solo el edificio: el precio sale de `Construction.cost_of`, que es el que
## aplica `TierDef.cost_scale`. Con `cost_for` suelto, el muro de una ciudad cara saldría en
## verde mientras el juego se atasca.
static func wall_of(building_index: int, tier: int, caps: PackedFloat64Array) -> int:
	for owned in range(0, 400):
		var cost := cost_at(building_index, tier, owned)
		for i in Goods.COUNT:
			if cost[i] > 0.0 and caps[i] != INF and cost[i] > caps[i]:
				return owned
	return 400


## Lo que pagaría un nodo de esa escala por el ejemplar `owned + 1`, por la puerta única.
static func cost_at(building_index: int, tier: int, owned: int) -> PackedFloat64Array:
	var probe := SimNode.new()
	probe.tier = tier
	probe.buildings.resize(Content.building_count())
	probe.buildings[building_index] = owned
	return Construction.cost_of(probe, building_index)


func _report(def: BuildingDef, storehouse: int, storehouses: int, tier: int,
		params: SimParams) -> void:
	var node := SimNode.new()
	node.tier = tier
	node.buildings.resize(Content.building_count())
	node.buildings[storehouse] = storehouses
	var caps := node.storage_caps(params)

	var bi := Content.building_index(def.id)
	var wall := wall_of(bi, tier, caps)
	if wall >= 400:
		print("  %-12s sin muro en 400 ejemplares" % def.name)
		return
	var cost := cost_at(bi, tier, wall)
	for i in Goods.COUNT:
		if cost[i] > 0.0 and caps[i] != INF and cost[i] > caps[i]:
			print("  %-12s MURO en el nº %d — cuesta %.0f %s y el tope es %.0f" % [
				def.name, wall + 1, cost[i], Goods.NAMES[i], caps[i],
			])
			return
