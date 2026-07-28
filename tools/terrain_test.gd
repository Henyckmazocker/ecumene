extends SceneTree
## El mundo está anclado. Ejecutar con:
##   godot-4 --headless --path . -s res://tools/terrain_test.gd
##
## El invariante que hace posible que promocionar **abra el mundo** en vez de rehacerlo:
##
##   **El mismo punto del mundo da siempre el mismo bioma, sea cual sea el tamaño de la
##   ventana que se pida.**
##
## La versión anterior dividía la frecuencia del ruido por el tamaño del mapa y centraba el
## domo en la mitad de la ventana. Con eso, pedir 96 celdas en vez de 64 no daba el mismo
## mundo con más alrededores: daba otro mundo, y promocionar habría rehecho el terreno bajo
## los pies del jugador.

const TestUtil := preload("res://tools/TestUtil.gd")


func _init() -> void:
	var failures := 0
	failures += _window_size_does_not_change_the_world()
	failures += _promotion_keeps_buildings_in_place()
	failures += _every_seed_is_habitable()
	failures += _buildings_all_find_a_spot()
	TestUtil.finish(self, failures)


## Ampliar la ventana no puede cambiar ni una celda de lo que ya se veía.
func _window_size_does_not_change_the_world() -> int:
	var failures := 0
	for seed_value in [1, 4242, 99999]:
		var small := TerrainGen.generate(seed_value, Content.SETTLEMENT)
		var big := TerrainGen.generate(seed_value, Content.CITY)
		var mismatches := 0
		var compared := 0
		for wy in range(-small.extent(), small.extent()):
			for wx in range(-small.extent(), small.extent()):
				var world := Vector2i(wx, wy)
				compared += 1
				if small.at(world) != big.at(world):
					mismatches += 1
		failures += TestUtil.check(
			mismatches == 0,
			"seed %d: las %d celdas comunes entre una ventana de %d y otra de %d son idénticas" % [
				seed_value, compared, small.size, big.size,
			],
			"seed %d: %d de %d celdas cambian al ampliar la ventana" % [
				seed_value, mismatches, compared,
			]
		)
	return failures


## Al promocionar crece la ventana. Los edificios y la gente están en coordenadas de mundo,
## así que no se pueden mover ni un píxel.
func _promotion_keeps_buildings_in_place() -> int:
	var engine := TestUtil.make_engine(31337)
	var node := engine.state.root()
	node.governor = Governor.balanced()
	for _i in 60:
		engine.tick(25.0)

	var before_terrain := TerrainGen.generate(node.seed, node.tier)
	var before := Layout.build(node, before_terrain)
	var positions := {}
	for p in before.placements:
		positions[p.cell] = p.building

	# Promocionar sin tocar nada más: solo cambia el tier, y con él el tamaño de la ventana.
	node.tier = Content.TOWN
	var after_terrain := TerrainGen.generate(node.seed, node.tier)
	var after := Layout.build(node, after_terrain)

	var moved := 0
	for p in after.placements:
		if not positions.has(p.cell) or positions[p.cell] != p.building:
			moved += 1

	var failures := TestUtil.check(
		after_terrain.size > before_terrain.size,
		"promocionar amplía la ventana de %d a %d celdas" % [
			before_terrain.size, after_terrain.size,
		],
		"la ventana no crece al promocionar (%d)" % after_terrain.size
	)
	failures += TestUtil.check(
		moved == 0 and after.placements.size() == before.placements.size(),
		"y los %d edificios se quedan exactamente donde estaban" % before.placements.size(),
		"%d de %d edificios se han movido al promocionar" % [moved, after.placements.size()]
	)
	return failures


## Sin el domo grande, hay que asegurarse de que ninguna semilla nace en mitad del océano.
func _every_seed_is_habitable() -> int:
	var worst_ratio := 1.0
	var worst_seed := 0
	var drowned := 0
	for i in 60:
		var seed_value := 1000 + i * 7919
		var terrain := TerrainGen.generate(seed_value, Content.SETTLEMENT)
		if not terrain.is_buildable(Vector2i.ZERO):
			drowned += 1
			continue
		var hist := terrain.histogram()
		var buildable := 0
		for b in range(Biomes.COUNT):
			if Biomes.is_buildable(b):
				buildable += hist[b]
		var ratio := float(buildable) / float(terrain.cells.size())
		if ratio < worst_ratio:
			worst_ratio = ratio
			worst_seed = seed_value

	var failures := TestUtil.check(
		drowned == 0,
		"60 semillas nacen en tierra firme",
		"%d de 60 semillas ponen el asentamiento en agua" % drowned
	)
	failures += TestUtil.check(
		worst_ratio > 0.35,
		"la peor semilla (%d) deja un %.0f %% de suelo edificable" % [
			worst_seed, worst_ratio * 100.0,
		],
		"la semilla %d solo deja un %.0f %% de suelo edificable" % [
			worst_seed, worst_ratio * 100.0,
		]
	)
	return failures


## Todos los edificios construidos tienen que aparecer en el mapa.
##
## Esto lo destapó el cambio a coordenadas con signo: `Layout` usaba `(-1, -1)` como centinela
## de «no hay sitio», y con coordenadas de mundo eso pasó a ser una celda válida pegada al
## centro. La colocación se rendía tras el tercer edificio creyendo que el mapa estaba lleno,
## y el pueblo se dibujaba casi vacío.
func _buildings_all_find_a_spot() -> int:
	var engine := TestUtil.make_engine(555)
	var node := engine.state.root()
	node.governor = Governor.balanced()
	for _i in 80:
		engine.tick(25.0)

	var terrain := TerrainGen.generate(node.seed, node.tier)
	var layout := Layout.build(node, terrain)
	return TestUtil.check(
		layout.placements.size() == node.building_total(),
		"los %d edificios construidos están todos colocados" % node.building_total(),
		"solo %d de %d edificios encuentran sitio" % [
			layout.placements.size(), node.building_total(),
		]
	)
