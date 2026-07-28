extends SceneTree
## El test que protege el pacto central del proyecto. Ejecutar con:
##   godot-4 --headless --path . -s res://tools/agents_test.gd
##
## «El agregado es la verdad; los agentes son una dramatización determinista de él.» Si esto
## se rompe, la vista habrá empezado a ser fuente de verdad y el juego dejará de poder
## calcular el progreso offline, guardar partidas pequeñas y correr en un móvil.

const TestUtil := preload("res://tools/TestUtil.gd")


func _init() -> void:
	var failures := 0
	failures += _terrain_deterministic()
	failures += _terrain_habitable()
	failures += _layout_stable()
	failures += _agents_do_not_touch_state()
	failures += _agents_mirror_the_aggregate()
	failures += _agents_are_pure_functions_of_time()
	TestUtil.finish(self, failures)


## El terreno no se guarda: se regenera. Más vale que salga igual siempre.
func _terrain_deterministic() -> int:
	var a := TerrainGen.generate(12345, Content.SETTLEMENT)
	var b := TerrainGen.generate(12345, Content.SETTLEMENT)
	var c := TerrainGen.generate(54321, Content.SETTLEMENT)
	var failures := TestUtil.check(
		a.cells == b.cells,
		"terreno determinista: misma semilla, mismas %d celdas" % a.cells.size(),
		"la misma semilla genera terrenos distintos"
	)
	failures += TestUtil.check(
		a.cells != c.cells,
		"semillas distintas generan terrenos distintos",
		"dos semillas distintas generan el mismo terreno"
	)
	return failures


## Un asentamiento no puede nacer en mitad del océano ni en un pedregal.
func _terrain_habitable() -> int:
	var failures := 0
	var worst_buildable := 1.0
	var worst_seed := 0
	for i in 40:
		var seed_value := 1000 + i * 7919
		var terrain := TerrainGen.generate(seed_value, Content.SETTLEMENT)
		if not terrain.is_buildable(terrain.center()):
			failures += TestUtil.check(false, "",
				"la semilla %d pone el centro del asentamiento en agua" % seed_value)
			break
		var hist := terrain.histogram()
		var buildable := 0
		for b in range(Biomes.COUNT):
			if Biomes.is_buildable(b):
				buildable += hist[b]
		var ratio := float(buildable) / float(terrain.cells.size())
		if ratio < worst_buildable:
			worst_buildable = ratio
			worst_seed = seed_value
	failures += TestUtil.check(
		worst_buildable > 0.35,
		"40 semillas habitables: la peor (%d) deja un %.0f %% de suelo edificable" % [
			worst_seed, worst_buildable * 100.0,
		],
		"la semilla %d solo deja un %.0f %% de suelo edificable" % [
			worst_seed, worst_buildable * 100.0,
		]
	)
	return failures


## Añadir edificios tiene que **ampliar** el mapa, no rebarajarlo: si al construir la granja
## nº 7 se movieran las seis anteriores, el asentamiento parpadearía entero en pantalla.
func _layout_stable() -> int:
	var engine := TestUtil.make_engine(777)
	var node := engine.state.root()
	var terrain := TerrainGen.generate(node.seed, node.tier)

	var before := Layout.build(node, terrain)
	var positions := {}
	for p in before.placements:
		positions[[p.building, p.cell]] = true

	node.stocks[Goods.WOOD] = 5000.0
	for _i in 6:
		Construction.build(node, Content.building_index("farm"), 0.0, null)
	var after := Layout.build(node, terrain)

	var kept := 0
	for p in after.placements:
		if positions.has([p.building, p.cell]):
			kept += 1
	return TestUtil.check(
		kept == before.placements.size(),
		"layout estable: los %d edificios previos siguen donde estaban tras construir 6 más" % kept,
		"construir movió edificios ya colocados (%d de %d conservados)" % [
			kept, before.placements.size(),
		]
	)


## **El invariante que importa.** Materializar y colapsar no puede cambiar un solo bit.
func _agents_do_not_touch_state() -> int:
	var engine := TestUtil.make_engine(4321)
	var node := engine.state.root()
	node.governor = Governor.balanced()
	for _i in 40:
		engine.tick(25.0)

	var terrain := TerrainGen.generate(node.seed, node.tier)
	var layout := Layout.build(node, terrain)
	var before := engine.state.state_hash()

	# Materializar, mirar mucho rato, y colapsar.
	var crowd := AgentMaterializer.materialize(node, layout, terrain.center())
	for step in 200:
		var cycle := engine.state.cycle + float(step) * 0.37
		for agent in crowd.agents:
			agent.sample(cycle)
	crowd = null

	var failures := TestUtil.check(
		engine.state.state_hash() == before,
		"materializar y colapsar deja el estado intacto (hash %d)" % before,
		"la vista ha modificado el estado: %d != %d" % [engine.state.state_hash(), before]
	)

	# Y rematerializar tiene que dar exactamente la misma gente en los mismos sitios.
	var again := AgentMaterializer.materialize(node, layout, terrain.center())
	var second := AgentMaterializer.materialize(node, layout, terrain.center())
	var identical := again.agents.size() == second.agents.size()
	if identical:
		for i in again.agents.size():
			if again.agents[i].home != second.agents[i].home \
					or again.agents[i].job != second.agents[i].job:
				identical = false
				break
	failures += TestUtil.check(
		identical,
		"rematerializar reproduce los mismos %d habitantes" % again.agents.size(),
		"al volver a acercar el zoom sale gente distinta"
	)
	return failures


## Lo que se ve trabajando tiene que ser lo que el integrador está usando para producir.
func _agents_mirror_the_aggregate() -> int:
	var engine := TestUtil.make_engine(2468)
	var node := engine.state.root()
	node.governor = Governor.balanced()
	for _i in 40:
		engine.tick(25.0)

	var terrain := TerrainGen.generate(node.seed, node.tier)
	var layout := Layout.build(node, terrain)
	var crowd := AgentMaterializer.materialize(node, layout, terrain.center())

	var workers := Integrator.effective_workers(node)
	var expected_total := 0.0
	for w in workers:
		expected_total += w

	var employed := 0
	var per_job := {}
	for agent in crowd.agents:
		if agent.has_work:
			employed += 1
			per_job[agent.job] = int(per_job.get(agent.job, 0)) + 1

	var shown := float(employed) * crowd.represents
	var failures := TestUtil.check(
		TestUtil.rel_error(shown, expected_total) < 0.05,
		"los agentes reflejan el agregado: %.1f trabajadores en pantalla vs %.1f simulados" % [
			shown, expected_total,
		],
		"lo que se ve no cuadra con lo simulado: %.1f vs %.1f trabajadores" % [
			shown, expected_total,
		]
	)

	# Y quien no tiene puesto tiene que verse ocioso, no fingir que trabaja.
	var idle := crowd.agents.size() - employed
	var expected_idle := maxf(node.pop - expected_total, 0.0)
	failures += TestUtil.check(
		absf(float(idle) * crowd.represents - expected_idle) < maxf(expected_idle * 0.1, 2.0),
		"%d puntos ociosos para %.1f habitantes sin puesto" % [idle, expected_idle],
		"los ociosos no cuadran: %d puntos para %.1f habitantes sin puesto" % [
			idle, expected_idle,
		]
	)
	return failures


## Los agentes no tienen estado: preguntar dos veces por el mismo instante da lo mismo, y
## preguntar por instantes en desorden no los descoloca. De ahí sale gratis que la pausa
## funcione y que el zoom se pueda alejar y volver sin que nadie se teletransporte.
func _agents_are_pure_functions_of_time() -> int:
	var engine := TestUtil.make_engine(1357)
	var node := engine.state.root()
	engine.tick(300.0)
	var terrain := TerrainGen.generate(node.seed, node.tier)
	var layout := Layout.build(node, terrain)
	var crowd := AgentMaterializer.materialize(node, layout, terrain.center())
	if crowd.agents.is_empty():
		return TestUtil.check(false, "", "no se ha materializado ningún habitante")

	var agent: Agent = crowd.agents[0]
	var t := 137.42
	var first: Array = agent.sample(t)

	# Pasear por el tiempo hacia delante y hacia atrás.
	for step in 50:
		agent.sample(t + float(step) * 3.1)
	for step in 50:
		agent.sample(t - float(step) * 7.7)

	var again: Array = agent.sample(t)
	var failures := TestUtil.check(
		first[0] == again[0] and first[1] == again[1],
		"los agentes no tienen estado: el mismo ciclo da siempre la misma posición",
		"consultar otros instantes descoloca al agente: %s vs %s" % [first[0], again[0]]
	)

	# Y con el tiempo parado, nadie se mueve.
	var frozen: Array = agent.sample(t)
	failures += TestUtil.check(
		frozen[0] == first[0],
		"con la simulación en pausa los habitantes se quedan quietos",
		"los habitantes se mueven con el tiempo real en vez de con el de simulación"
	)
	return failures
