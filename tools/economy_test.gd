extends SceneTree
## Balance de la economía. Ejecutar con:
##   godot-4 --headless --path . -s res://tools/economy_test.gd
##
## La lección de Worlding: el primer bug de balance fue la extinción mundial por hambruna,
## porque la extracción superaba a la regeneración. Aquí el equivalente es que un nodo bien
## gestionado tiene que sobrevivir indefinidamente, y uno mal gestionado tiene que morirse
## — las dos direcciones importan. Una economía que no puede colapsar tampoco tiene tensión.

const TestUtil := preload("res://tools/TestUtil.gd")


func _init() -> void:
	var failures := 0
	failures += _starting_margin()
	failures += _nothing_happens_by_itself()
	failures += _upgrades_work()
	failures += _first_promotion_pacing()
	failures += _managed_survives()
	failures += _mismanaged_starves()
	failures += _promotion_reachable()
	failures += _nesting_ceiling()
	TestUtil.finish(self, failures)


## El techo alimentario tiene que ser un **número legible**, no un acantilado.
##
## Con el reparto de oficios por pesos había un acantilado inherente: mientras una granja
## tenía puestos libres, su producción crecía con la población igual que el consumo, así que
## por debajo de cierto reparto **ninguna población era sostenible** y el techo era 0 en vez
## de un número pequeño. Un retoque mínimo en la granja extinguía asentamientos enteros.
##
## Con trabajadores asignados a mano eso desaparece en el régimen normal: la producción es una
## constante (seis granjeros producen lo que producen seis granjeros), así que el techo es
## siempre `producción / consumo por habitante` — finito, positivo y explicable en la UI.
func _starting_margin() -> int:
	var engine := TestUtil.make_engine(1)
	var node := engine.state.root()
	var snap := Integrator.snapshot(node, engine.params)

	var farm := Content.building_index("farm")
	var expected := node.jobs[farm] * Content.building(farm).produces[Goods.FOOD] \
		/ engine.params.food_per_pop

	var failures := TestUtil.check(
		snap.food_capacity > 0.0 and snap.food_capacity != INF,
		"techo alimentario legible: %.1f habitantes con %.0f granjeros" % [
			snap.food_capacity, node.jobs[farm],
		],
		"el techo alimentario no es un número usable: %.2f" % snap.food_capacity
	)
	failures += TestUtil.check(
		TestUtil.rel_error(snap.food_capacity, expected) < 0.001,
		"y sale exactamente de la cuenta: producción ÷ consumo = %.1f" % expected,
		"el techo (%.2f) no cuadra con producción ÷ consumo (%.2f)" % [
			snap.food_capacity, expected,
		]
	)

	# Y con el peaje de delegación sigue siendo sostenible, no cae a cero.
	var delegated := Integrator.snapshot(node, engine.params,
		Integrator.Modifiers.none().scaled(engine.params.governor_efficiency))
	failures += TestUtil.check(
		delegated.food_capacity > engine.params.initial_pop,
		"delegado sigue dando de comer a %.1f (población inicial %.0f)" % [
			delegated.food_capacity, engine.params.initial_pop,
		],
		"delegado el techo cae a %.1f, por debajo de la población inicial" % \
			delegated.food_capacity
	)
	return failures


## **Sin delegar, el juego no toca nada por su cuenta.** Ni destina trabajadores al construir,
## ni compra edificios. La gestión es del jugador hasta que la cede.
func _nothing_happens_by_itself() -> int:
	var engine := TestUtil.make_engine(4242)
	var node := engine.state.root()
	var farm := Content.building_index("farm")

	# Construir una granja no pone a nadie dentro.
	node.stocks[Goods.WOOD] = 5000.0
	var before := node.jobs[farm]
	Construction.build(node, farm, 0.0, null)
	var failures := TestUtil.check(
		node.jobs[farm] == before,
		"construir no destina a nadie: la granja nueva nace vacía (%.0f granjeros)" % before,
		"construir ha destinado gente solo: %.0f → %.0f" % [before, node.jobs[farm]]
	)

	# Y 3.000 ciclos después no se ha comprado nada ni se ha movido un trabajador.
	var buildings_before := node.building_total()
	var jobs_before := node.jobs.duplicate()
	for _i in 120:
		engine.tick(25.0)
	failures += TestUtil.check(
		node.building_total() == buildings_before,
		"3.000 ciclos sin delegar: sigue habiendo %d edificios, no se compra nada solo" % \
			buildings_before,
		"se han comprado %d edificios sin permiso" % (node.building_total() - buildings_before)
	)
	failures += TestUtil.check(
		node.jobs == jobs_before,
		"y el reparto de oficios no lo ha tocado nadie",
		"el reparto de oficios ha cambiado solo"
	)

	# Los topes: no se puede mandar a más gente de la que hay ni de la que cabe.
	Construction.set_workers(node, farm, 9999.0)
	var capacity := Construction.capacity_of(node, farm)
	failures += TestUtil.check(
		node.jobs[farm] <= minf(capacity, node.pop) + 0.001,
		"topes respetados: pedir 9.999 granjeros deja %.0f (puestos %.0f, población %.1f)" % [
			node.jobs[farm], capacity, node.pop,
		],
		"se han destinado %.0f granjeros con %.0f puestos y %.1f habitantes" % [
			node.jobs[farm], capacity, node.pop,
		]
	)

	var woodcutter := Content.building_index("woodcutter")
	Construction.set_workers(node, woodcutter, 9999.0)
	var total := node.jobs[farm] + node.jobs[woodcutter]
	failures += TestUtil.check(
		total <= node.pop + 0.001,
		"nadie trabaja en dos sitios: %.0f destinados de %.1f habitantes" % [total, node.pop],
		"hay %.0f trabajadores destinados con solo %.1f habitantes" % [total, node.pop]
	)
	return failures


## Las mejoras aplican, respetan requisitos y cobran.
func _upgrades_work() -> int:
	var engine := TestUtil.make_engine(606)
	var node := engine.state.root()
	var farm := Content.building_index("farm")

	# Una mejora de pueblo no está a la vista en un asentamiento.
	var failures := TestUtil.check(
		not Upgrading.is_available(node, "stone_tools"),
		"las mejoras de pueblo no se ven en un asentamiento",
		"una mejora de pueblo está disponible en un asentamiento"
	)
	# Ni una cuyo requisito no está comprado.
	failures += TestUtil.check(
		not Upgrading.is_available(node, "granary"),
		"«Granero» está oculta sin su requisito «Rotación de cultivos»",
		"«Granero» aparece sin cumplir su requisito"
	)

	# Por debajo del tope de almacén a propósito: un stock lleno está fijado y su tasa se
	# enseña como 0, así que no se podría medir el efecto de la mejora.
	node.stocks[Goods.FOOD] = 195.0
	node.stocks[Goods.WOOD] = 195.0
	var before_rate := Integrator.snapshot(node, engine.params).rates[Goods.FOOD]
	var food_before := node.stocks[Goods.FOOD]

	failures += TestUtil.check(
		Upgrading.buy(node, "crop_rotation", 0.0, null),
		"se compra «Rotación de cultivos»",
		"no se puede comprar una mejora disponible y pagable"
	)
	failures += TestUtil.check(
		node.stocks[Goods.FOOD] == food_before - 150.0,
		"y cuesta sus 150 de comida",
		"el coste no se ha cobrado: %.0f → %.0f" % [food_before, node.stocks[Goods.FOOD]]
	)

	var after_rate := Integrator.snapshot(node, engine.params).rates[Goods.FOOD]
	var farm_boost := Content.building(farm).produces[Goods.FOOD] * node.jobs[farm] * 0.30
	failures += TestUtil.check(
		TestUtil.rel_error(after_rate - before_rate, farm_boost) < 0.01,
		"+30 %% en granjas se nota en la tasa: %+.2f → %+.2f por ciclo" % [
			before_rate, after_rate,
		],
		"la mejora no cambia la producción: %+.3f → %+.3f" % [before_rate, after_rate]
	)

	# Y ahora sí se ve la que dependía de ella.
	failures += TestUtil.check(
		Upgrading.is_available(node, "granary"),
		"comprarla desbloquea «Granero»",
		"«Granero» sigue oculta tras comprar su requisito"
	)

	# Los puestos también son multiplicadores: nada de sumar +1 por fuera.
	node.buildings[farm] = 4
	var slots_before := node.capacity_of(farm)
	node.upgrades.append("wide_paths")
	node.invalidate_effects()
	failures += TestUtil.check(
		TestUtil.rel_error(node.capacity_of(farm), slots_before * 1.34) < 0.001,
		"«Sendas anchas» multiplica los puestos: %.1f → %.1f" % [
			slots_before, node.capacity_of(farm),
		],
		"el multiplicador de puestos no se aplica: %.1f → %.1f" % [
			slots_before, node.capacity_of(farm),
		]
	)
	return failures


## **El ritmo de onboarding.** La primera promoción es donde el juego enseña su gancho —el eje
## de escalas—, así que no se deja al ojo: si algún ajuste de balance la aleja, esto avisa.
##
## Con un gobernador equilibrado tiene que caer entre los ciclos 600 y 1400 (10-23 min a ×1).
## A mano será algo más lento, que es lo correcto.
func _first_promotion_pacing() -> int:
	var reached := PackedFloat64Array()
	for seed_value in [11, 222, 3333, 44444]:
		var engine := TestUtil.make_engine(seed_value)
		var root := engine.state.root()
		root.governor = Governor.balanced()
		var at := -1.0
		for _i in 120:
			engine.tick(25.0)
			if Promotion.can_promote(engine.state, root):
				at = engine.state.cycle
				break
		reached.append(at)

	var worst := 0.0
	var best := INF
	for at in reached:
		if at < 0.0:
			return TestUtil.check(false, "",
				"alguna semilla no llega a Pueblo en 3.000 ciclos: %s" % [Array(reached)])
		worst = maxf(worst, at)
		best = minf(best, at)

	return TestUtil.check(
		best >= 600.0 and worst <= 1400.0,
		"primera promoción entre los ciclos %0.f y %0.f (objetivo 600-1400, ~10-23 min)" % [
			best, worst,
		],
		"el ritmo se ha desviado: primera promoción entre %0.f y %0.f, fuera de 600-1400" % [
			best, worst,
		]
	)


## Un asentamiento delegado en un gobernador equilibrado tiene que prosperar 5.000 ciclos.
func _managed_survives() -> int:
	var engine := TestUtil.make_engine(2024)
	var root := engine.state.root()
	root.governor = Governor.balanced()

	for _i in 100:
		engine.tick(50.0)

	var failures := TestUtil.check(
		root.pop > engine.params.initial_pop,
		"nodo gobernado a 5.000 ciclos: %0.1f hab, %d edificios, tier %s" % [
			root.pop, root.building_total(), root.def().name,
		],
		"el nodo gobernado se ha estancado o muerto: %0.1f hab" % root.pop
	)
	failures += TestUtil.check(
		not root.starving,
		"sin hambruna crónica al final del test",
		"el nodo gobernado acaba en hambruna permanente"
	)
	return failures


## Todo el mundo al bosque y nadie al campo: la hambruna tiene que llegar y matar.
func _mismanaged_starves() -> int:
	var engine := TestUtil.make_engine(2024)
	var root := engine.state.root()
	Construction.set_workers(root, Content.building_index("farm"), 0.0)
	Construction.set_workers(root, Content.building_index("woodcutter"), root.pop)
	var start_pop := root.pop
	var flagged := false

	for _i in 500:
		engine.tick(1.0)
		# El aviso solo tiene sentido mientras queda gente de más para la comida que hay:
		# ya extinguido, el nodo no está "pasando hambre", está vacío.
		flagged = flagged or root.starving

	var failures := TestUtil.check(
		root.pop < start_pop * 0.01,
		"hambruna reproducible: sin granjeros la población cae de %0.1f a %0.3f" % [
			start_pop, root.pop,
		],
		"sin granjeros la población NO cae (%0.1f → %0.1f): la comida no limita nada" % [
			start_pop, root.pop,
		]
	)
	failures += TestUtil.check(
		flagged,
		"el aviso de hambruna se enciende durante el colapso",
		"la población se muere sin que `starving` llegue a activarse: la UI no podría avisar"
	)
	return failures


## La primera promoción tiene que ser alcanzable en un tiempo razonable con un gobernador.
func _promotion_reachable() -> int:
	var engine := TestUtil.make_engine(5150)
	var root := engine.state.root()
	root.governor = Governor.balanced()

	var promoted_at := -1.0
	for _i in 400:
		engine.tick(25.0)
		if Promotion.can_promote(engine.state, root):
			Promotion.promote(engine.state, root, null)
			promoted_at = engine.state.cycle
			break

	return TestUtil.check(
		promoted_at > 0.0,
		"asentamiento → pueblo alcanzado en el ciclo %0.f (%0.f hab, %d edificios)" % [
			promoted_at, root.total_pop, root.building_total(),
		],
		"no se llega a pueblo en 10.000 ciclos: %0.f hab, %d edificios (umbral %0.f / %d)" % [
			root.total_pop, root.building_total(),
			Content.tier(Content.SETTLEMENT).promote_pop,
			Content.tier(Content.SETTLEMENT).promote_buildings,
		]
	)


## Un hijo nunca puede alcanzar el tier de su padre: es la regla que produce el anidamiento.
func _nesting_ceiling() -> int:
	var engine := TestUtil.make_engine(31)
	var state := engine.state
	var root := state.root()
	root.tier = Content.CITY
	root.pop = 5000.0
	root.stocks[Goods.FOOD] = 500.0

	var child := Promotion.found_child(state, root, engine.params, null)
	if child == null:
		return TestUtil.check(false, "", "una ciudad con población y comida no puede fundar hijos")

	var failures := TestUtil.check(
		child.tier == Content.TOWN,
		"una ciudad funda pueblos (tier %d), no asentamientos" % child.tier,
		"el hijo de una ciudad ha nacido en el tier %d" % child.tier
	)

	# El hijo cumple de sobra el umbral de población, pero su techo es el tier del padre − 1.
	child.pop = 1.0e6
	state.refresh_totals()
	for _i in 60:
		Construction.build(child, Content.building_index("hut"), 0.0, null)
	child.stocks[Goods.WOOD] = 1.0e6
	for _i in 60:
		Construction.build(child, Content.building_index("hut"), 0.0, null)

	failures += TestUtil.check(
		not Promotion.can_promote(state, child),
		"techo de anidamiento: el pueblo hijo no asciende a ciudad estando bajo una ciudad",
		"un hijo ha podido alcanzar el tier de su padre — el anidamiento se rompe"
	)
	return failures
