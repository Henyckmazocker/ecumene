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
	failures += _managed_survives()
	failures += _mismanaged_starves()
	failures += _promotion_reachable()
	failures += _nesting_ceiling()
	TestUtil.finish(self, failures)


## El reparto de partida tiene que sostenerse **incluso con el peaje de delegación**.
##
## Hay un acantilado inherente al modelo: mientras una granja tiene puestos libres, su
## producción es proporcional a la población igual que el consumo, así que si la producción
## por trabajador queda por debajo del consumo por habitante, **ninguna población es
## sostenible** y el techo alimentario es 0, no un número pequeño. Con los valores actuales
## el margen del reparto inicial bajo un gobernador es de apenas el 2 %: cualquier retoque a
## la baja en la granja, o a la baja en `governor_efficiency`, extingue asentamientos recién
## fundados. Este test es el que avisa.
func _starting_margin() -> int:
	var engine := TestUtil.make_engine(1)
	var node := engine.state.root()
	var mods := Integrator.Modifiers.none().scaled(engine.params.governor_efficiency)
	var seg := Integrator.build_segment(node, engine.params, mods)

	var shares := Integrator.job_shares(node)
	var farm := Content.building_index("farm")
	var per_worker := shares[farm] * Content.building(farm).produces[Goods.FOOD] \
		* engine.params.governor_efficiency
	var margin := per_worker / engine.params.food_per_pop - 1.0

	return TestUtil.check(
		seg.housing > 0.0,
		"el reparto inicial se sostiene delegado: margen alimentario %+.1f %%" % (margin * 100.0),
		"el reparto inicial NO se sostiene delegado (techo %0.2f, margen %+.1f %%): un " % [
			seg.housing, margin * 100.0,
		] + "asentamiento recién fundado y delegado se extingue solo"
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
	root.jobs[Content.building_index("farm")] = 0.0
	root.jobs[Content.building_index("woodcutter")] = 1.0
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
