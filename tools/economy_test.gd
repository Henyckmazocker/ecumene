extends SceneTree
## Balance de la economía. Ejecutar con:
##   godot-4 --headless --path . -s res://tools/economy_test.gd
##
## La lección de Worlding: el primer bug de balance fue la extinción mundial por hambruna,
## porque la extracción superaba a la regeneración. Aquí el equivalente es que un nodo bien
## gestionado tiene que sobrevivir indefinidamente, y uno mal gestionado tiene que morirse
## — las dos direcciones importan. Una economía que no puede colapsar tampoco tiene tensión.

const TestUtil := preload("res://tools/TestUtil.gd")
## Se reutiliza la aritmética del techo en vez de duplicarla: si el volcado y el test
## calcularan el muro cada uno por su cuenta, acabarían discrepando justo cuando importa.
const CeilingDump := preload("res://tools/ceiling_dump.gd")


func _init() -> void:
	var failures := 0
	failures += _starting_margin()
	failures += _nothing_happens_by_itself()
	failures += _the_governor_plays_the_whole_game()
	failures += _the_governor_obeys_its_leash()
	failures += _the_governor_leaves_no_orphans()
	failures += _food_limited_town_keeps_founding()
	failures += _heirs_cap_the_delegated_tree()
	failures += _priorities_change_behaviour()
	failures += _orders_change_behaviour()
	failures += _housing_can_be_bought_in_stone()
	failures += _upgrades_work()
	failures += _the_tree_has_a_shape()
	failures += _first_promotion_pacing()
	failures += _early_curve_pacing()
	failures += _managed_survives()
	failures += _mismanaged_starves()
	failures += _famine_warns_once_per_episode()
	failures += _promotion_reachable()
	failures += _nesting_ceiling()
	failures += _empty_tiers_are_closed()
	failures += _region_is_reachable()
	failures += _influence_is_root_of_subtree_culture()
	failures += _region_needs_influence()
	failures += _routes_run_on_transport()
	failures += _the_parent_pays_transport()
	failures += _the_regional_governor_feeds_the_hungry()
	failures += _cannot_found_in_a_settlement()
	failures += _cannot_found_without_free_slots()
	failures += _cannot_found_without_settlers()
	failures += _cannot_found_without_food()
	failures += _cannot_found_while_travelling()
	failures += _founding_is_an_expedition()
	failures += _roads_shorten_the_next_expedition()
	failures += _a_city_expedition_takes_seven_times()
	failures += _a_pruned_parent_loses_its_expedition()
	failures += _the_expedition_tells_its_story()
	failures += _the_ceiling_rises_with_the_tier()
	failures += _the_ceiling_never_blocks_promotion()
	# ⏩ Acelerar con oro (M3 del sumidero): cada aceleración cuesta más, sin oro no se acelera, y
	# un pueblo no puede.
	failures += _the_second_acceleration_costs_more()
	failures += _no_gold_no_acceleration()
	failures += _a_town_cannot_accelerate()
	TestUtil.finish(self, failures)


## Subir de escala tiene que subir el techo de almacenamiento, para **todos** los edificios.
##
## Aquí vivía un callejón sin salida. Los costes crecen en progresión geométrica (×1.15–1.25
## por ejemplar) y el tope crecía solo linealmente con los almacenes (+200 cada uno): el
## almacén nº 20 costaba 4.163 de madera contra un tope de 4.000 y, como es justo el edificio
## que sube el tope, se bloqueaba a sí mismo. Con él se bloqueaba todo lo demás —cabaña nº 41,
## templo nº 18—, y ascender no servía de nada porque el tope no miraba la escala: las tres
## escalas daban exactamente los mismos números.
##
## El muro sigue existiendo dentro de cada escala, a propósito: es lo que empuja a ascender.
## Lo que no puede volver a pasar es que ascender no lo mueva.
func _the_ceiling_rises_with_the_tier() -> int:
	var params := SimParams.new()
	var storehouse := Content.building_index("storehouse")
	var stuck := PackedStringArray()
	var lowest := 999

	for bi in Content.building_count():
		var def := Content.building(bi)
		var previous := -1
		for tier in [Content.SETTLEMENT, Content.TOWN, Content.CITY]:
			if def.tier_min > tier:
				continue
			var wall := _wall_at(def, storehouse, tier, params)
			lowest = mini(lowest, wall)
			if previous >= 0 and wall <= previous:
				stuck.append("%s no mejora al llegar a %s (nº %d → %d)" % [
					def.name, Content.tier(tier).name, previous, wall,
				])
			previous = wall

	return TestUtil.check(
		stuck.is_empty(),
		"ascender sube el techo de los %d edificios (el más apretado aguanta %d ejemplares)" % [
			Content.building_count(), lowest,
		],
		"el techo no se mueve al ascender: %s" % " · ".join(stuck)
	)


## El muro tiene que ser un empujón, no un callejón: llega **después** de poder ascender.
##
## Se suman los ejemplares que caben de cada tipo, porque el umbral de ascenso cuenta edificios
## totales, no de uno solo.
func _the_ceiling_never_blocks_promotion() -> int:
	var params := SimParams.new()
	var storehouse := Content.building_index("storehouse")
	var failures := 0

	for tier in [Content.SETTLEMENT, Content.TOWN, Content.CITY]:
		var needed := Content.tier(tier).promote_buildings
		if needed <= 0:
			continue
		var room := 0
		for bi in Content.buildings_for_tier(tier):
			room += _wall_at(Content.building(bi), storehouse, tier, params)
		failures += TestUtil.check(
			room >= needed,
			"%s: caben %d edificios bajo el techo y ascender pide %d" % [
				Content.tier(tier).name, room, needed,
			],
			"%s: solo caben %d edificios y ascender pide %d — el muro es un callejón" % [
				Content.tier(tier).name, room, needed,
			]
		)
	return failures


## En qué ejemplar deja de poder pagarse un edificio, con el mejor techo alcanzable. Con el precio
## de esa escala (`TierDef.cost_scale`): `CeilingDump.wall_of` pasa por `Construction.cost_of`.
static func _wall_at(def: BuildingDef, storehouse: int, tier: int, params: SimParams) -> int:
	var node := SimNode.new()
	node.tier = tier
	node.buildings.resize(Content.building_count())
	node.buildings[storehouse] = CeilingDump.max_storehouses(storehouse, tier, params)
	return CeilingDump.wall_of(Content.building_index(def.id), tier, node.storage_caps(params))


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
	# La investigación es una compra más: sin delegar, tampoco se hace sola.
	failures += TestUtil.check(
		node.upgrades.is_empty(),
		"ni se ha investigado nada por su cuenta",
		"se han comprado mejoras sin permiso: %s" % [Array(node.upgrades)]
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


## **Un nodo delegado juega al juego entero.** Reparte por todos los oficios —no solo campo y
## bosque—, mira lo que cada taller consume, e investiga.
##
## Antes clasificaba los edificios con un `if/elif` sobre comida y madera: cantera, taller,
## mercado y templo eran el mismo oficio indistinguible, `consumes` no se leía en ninguna parte
## y `Upgrading.buy` no tenía un solo llamador en `sim/`, así que un nodo delegado acumulaba
## recursos sin investigar jamás — y la UI, con razón, le apaga los botones al jugador.
func _the_governor_plays_the_whole_game() -> int:
	var quarry := Content.building_index("quarry")
	var workshop := Content.building_index("workshop")
	var hut := Content.building_index("hut")

	var engine := TestUtil.make_engine(777)
	var node := engine.state.root()
	node.tier = Content.TOWN
	node.buildings[hut] = 20
	node.buildings[quarry] = 3
	node.buildings[workshop] = 3
	node.pop = 60.0
	for i in Goods.COUNT:
		node.stocks[i] = 400.0
	node.governor = Governor.balanced()

	for _i in 20:
		engine.tick(30.0)

	var failures := TestUtil.check(
		not node.upgrades.is_empty(),
		"un pueblo delegado investiga solo: %s" % [Array(node.upgrades)],
		"600 ciclos delegado y no ha comprado una sola mejora"
	)
	failures += TestUtil.check(
		node.jobs[quarry] > 0.0 and node.jobs[workshop] > 0.0,
		"y el reparto llega a los oficios de pueblo: %.0f en la cantera, %.0f en el taller" % [
			node.jobs[quarry], node.jobs[workshop],
		],
		"cantera (%.0f) o taller (%.0f) se quedan sin gente" % [
			node.jobs[quarry], node.jobs[workshop],
		]
	)

	# Sin madera en el almacén el taller no puede fabricar nada, así que ahí no sobra un brazo.
	# Un checkpoint exacto: el reparto se decide antes de construir, así que lo que se levante
	# después no ensucia la medida.
	var starved := TestUtil.make_engine(778)
	var s := starved.state.root()
	s.tier = Content.TOWN
	s.buildings[hut] = 20
	s.buildings[quarry] = 3
	s.buildings[workshop] = 3
	s.buildings[Content.building_index("woodcutter")] = 0
	s.pop = 60.0
	for i in Goods.COUNT:
		s.stocks[i] = 400.0
	s.stocks[Goods.WOOD] = 0.0
	s.governor = Governor.balanced()
	s.governor_last_cycle = starved.state.cycle
	starved.tick(30.0)

	failures += TestUtil.check(
		s.jobs[workshop] < s.jobs[quarry] * 0.5,
		"sin madera el taller se queda casi vacío: %.0f frente a %.0f en la cantera" % [
			s.jobs[workshop], s.jobs[quarry],
		],
		"se manda gente a fabricar sin materia prima: %.0f en el taller, %.0f en la cantera" % [
			s.jobs[workshop], s.jobs[quarry],
		]
	)

	# Y una mejora que multiplica un edificio que no existe no vale nada: nadie compra
	# vagonetas sin cantera.
	var sit := GovernorSys.Situation.new()
	sit.weights = s.governor.normalized()
	sit.snap = Integrator.snapshot(s, starved.params)
	sit.caps = s.storage_caps(starved.params)
	var rails: Upgrades.Def = Upgrades.get_def("quarry_rails")
	var with_quarry := GovernorSys._upgrade_score(rails, s, sit)
	s.buildings[quarry] = 0
	var without_quarry := GovernorSys._upgrade_score(rails, s, sit)
	failures += TestUtil.check(
		without_quarry == 0.0 and with_quarry > 0.0,
		"«Vagonetas» puntúa %.2f con cantera y 0 sin ella" % with_quarry,
		"«Vagonetas» puntúa %.2f sin una sola cantera construida" % without_quarry
	)
	return failures


## **Ningún huérfano.** Lo que funda un gobernador nace delegado, con una copia de la política
## de su padre, y crece.
##
## Antes cada colonia nacía con `governor = null` y nadie podía llevarla: se quedaba para
## siempre con su granja y su leñador, clavada en el techo alimentario de esos dos edificios
## (~7,2 habitantes). Un gobernador que funda colonias que nadie lleva es ese bug.
func _the_governor_leaves_no_orphans() -> int:
	var hut := Content.building_index("hut")
	var engine := TestUtil.make_engine(5005)
	var state := engine.state
	var node := state.root()
	node.tier = Content.TOWN
	node.buildings[hut] = 20
	node.buildings[Content.building_index("farm")] = 8
	node.pop = 60.0
	for i in Goods.COUNT:
		node.stocks[i] = 400.0
	node.governor = Governor.balanced()
	# Una política que no es la de fábrica: si el hijo recibiera `balanced()` en vez de la copia,
	# esto lo delata.
	# No se le deja ascender para que siga siendo un pueblo y el caso pruebe lo que dice.
	node.governor.growth = 0.45
	node.governor.may_promote = false
	assert(node.governor.may_expand)

	# Con el reloj, la primera expedición sale en el primer checkpoint y llega ~2.400 ciclos
	# después: en 5.000 ciclos hay al menos una colonia **llegada**, que es la que se examina.
	var started := Time.get_ticks_msec()
	for _i in 200:
		engine.tick(25.0)
	var elapsed := Time.get_ticks_msec() - started

	var failures := TestUtil.check(
		not node.children.is_empty(),
		"un pueblo delegado con permiso para expandirse funda %d colonias en 5.000 ciclos (%d ms)"
			% [node.children.size(), elapsed],
		"5.000 ciclos delegado con `may_expand` y no ha fundado nada: el caso no prueba nada"
	)
	var orphans := PackedStringArray()
	var copies := 0
	var stuck := PackedStringArray()
	var pops := PackedStringArray()
	for id in node.children:
		var child: SimNode = state.nodes.get(id)
		if child == null:
			stuck.append("#%d colapsada" % id)
			continue
		pops.append("%s %.1f" % [child.name, child.pop])
		if child.governor == null:
			orphans.append(child.name)
			continue
		if is_equal_approx(child.governor.growth, 0.45) and not child.governor.may_promote \
				and child.governor != node.governor:
			copies += 1
		if child.pop <= 7.2:
			stuck.append("%s %.1f" % [child.name, child.pop])
	failures += TestUtil.check(
		orphans.is_empty() and copies == node.children.size(),
		"todas las colonias nacen delegadas, con una copia propia de la política del padre",
		"colonias sin gobernador: %s; con copia de la política: %d de %d" % [
			Array(orphans), copies, node.children.size(),
		]
	)
	failures += TestUtil.check(
		stuck.is_empty(),
		"y todas pasan de los 7,2 hab del techo de granja + leñador: %s" % [Array(pops)],
		"colonias estancadas o colapsadas: %s" % [Array(stuck)]
	)
	return failures


## **Un pueblo delegado con la comida al límite sigue fundando hasta llenar sus plazas.**
##
## `food_limited` no es hambre: dice que el campo sostiene menos gente de la que cabe en las casas,
## y un pueblo sano y lleno está casi siempre así. El gobernador se negaba a fundar con
## `food_limited` en vez de con `starving`, y además medía el techo sin su peaje (0,85) ni el
## legado, así que la población real se quedaba en el 85 % de lo que él creía y no llegaba nunca
## al 90 % de `FOUND_AT_CAP`. Con Ciudad pidiendo 4 hijos, una raíz así no ascendería nunca.
##
## El pueblo es el de `_order_run`, sin permiso para construir, investigar ni ascender: con 8
## granjas y 20 cabañas la comida pone el techo **todo el rato** y nada puede quitárselo, así que
## el caso no depende de que el gobernador decida no levantar granjas. La precondición se
## comprueba en cada salida con `Integrator.snapshot` y los mismos multiplicadores con los que
## decide el gobernador: si el pueblo no estuviera limitado por la comida al fundar, el caso no
## probaría nada. Con el reloj (2.400 × 1,5ⁿ) los 4 hijos llegan en ~19.500 ciclos más lo que
## tarda en rehacerse entre salidas; el tope de 30.000 lo cubre.
func _food_limited_town_keeps_founding() -> int:
	const MAX_CYCLES := 30000
	var engine := TestUtil.make_engine(4243)
	var state := engine.state
	var params := engine.params
	var node := state.root()
	node.tier = Content.TOWN
	node.buildings[Content.building_index("hut")] = 20
	node.buildings[Content.building_index("farm")] = 8
	node.pop = 60.0
	for i in Goods.COUNT:
		node.stocks[i] = 400.0
	var policy := Governor.balanced()
	policy.may_build = false
	policy.may_research = false
	policy.may_promote = false
	assert(policy.may_expand)
	GovernorSys.delegate(state, node, policy)
	state.refresh_totals()
	var slots := node.def().child_slots

	var started := Time.get_ticks_msec()
	var departures := 0
	var limited_departures := 0
	var starving_departures := 0
	# Se compara la expedición y no si hay una: la siguiente puede salir en el mismo `tick` en que
	# llega la anterior, y entonces «en camino» no se apaga nunca entre las dos.
	var last_seen: Expedition = null
	while node.children.size() < slots and state.cycle < MAX_CYCLES:
		engine.tick(25.0)
		var travelling := state.expedition_of(node.id)
		if travelling != null and travelling != last_seen:
			departures += 1
			# Lo que el gobernador veía al fundar: la población de después solo difiere en los
			# colonos que se acaban de ir, y el techo no depende de la población.
			var snap := Integrator.snapshot(node, params,
				SimEngine.delegated_modifiers(state, params))
			limited_departures += 1 if snap.food_limited else 0
			starving_departures += 1 if snap.starving else 0
		last_seen = travelling
	var elapsed := Time.get_ticks_msec() - started

	var failures := TestUtil.check(
		departures > 0 and limited_departures == departures and starving_departures == 0,
		"el pueblo está limitado por la comida, sin hambre, en las %d salidas" % departures,
		"precondición rota: %d salidas, %d con `food_limited`, %d con hambre — sin salidas o sin la comida al límite, el caso no prueba nada"
			% [departures, limited_departures, starving_departures]
	)
	failures += TestUtil.check(
		node.children.size() == slots,
		"y aun así llena sus %d plazas en el ciclo %d (%d ms)" % [slots, state.cycle, elapsed],
		"con la comida al límite se queda en %d de %d hijos tras %d ciclos: el gobernador no funda"
			% [node.children.size(), slots, state.cycle]
	)
	return failures


## **El tope de herederos.** Un gobernador solo coloniza si la profundidad de su nodo (raíz = 0)
## no pasa de `Ascension.bonuses(state).heirs`, que sube con «Dinastía» en el legado.
##
## Sin el tope cada colonia copia `may_expand` y funda las suyas, y el árbol delegado crece
## exponencialmente: 12 h fuera eran 29 s y 1.507 nodos. Se prueba con las dos generaciones a la
## vez: la raíz, una ciudad delegada, y una colonia suya que ya es pueblo (como si hubiese
## promocionado), delegada y llena, que es justo la que funda o no según el tope.
func _heirs_cap_the_delegated_tree() -> int:
	var failures := 0
	var no_heirs := _run_two_generations(PackedStringArray())
	failures += TestUtil.check(
		no_heirs[0] > 1,
		"con tope 0 la raíz delegada sigue fundando: %d colonias" % no_heirs[0],
		"con tope 0 la raíz delegada no ha fundado nada más: el caso no prueba nada"
	)
	failures += TestUtil.check(
		no_heirs[1] == 0 and no_heirs[3] == 0,
		"y su colonia delegada, pueblo lleno y con `may_expand`, no funda ninguna ni la manda",
		"con tope 0 una colonia delegada ha fundado %d y tiene %d en camino: el árbol vuelve a crecer sin freno"
			% [no_heirs[1], no_heirs[3]]
	)
	var one_heir := _run_two_generations(PackedStringArray(["heirs"]))
	failures += TestUtil.check(
		one_heir[1] > 0,
		"con 👑 Dinastía a 1 rango la colonia sí funda: %d" % one_heir[1],
		"con Dinastía a 1 rango la colonia sigue sin fundar"
	)
	failures += TestUtil.check(
		one_heir[2] == 0,
		"y sus nietas, a profundidad 2, ya no",
		"con Dinastía a 1 rango ha fundado una nieta: %d" % one_heir[2]
	)
	# El freno es de la profundidad, no del permiso: la política se sigue copiando entera.
	var state := TestUtil.make_engine(5006).state
	var root := state.root()
	var child := state.add_node(Content.TOWN, root.id)
	var grandchild := state.add_node(Content.SETTLEMENT, child.id)
	var base := [GovernorSys.may_found_by_heirs(state, root),
		GovernorSys.may_found_by_heirs(state, child),
		GovernorSys.may_found_by_heirs(state, grandchild)]
	state.legacy_nodes = PackedStringArray(["heirs", "heirs"])
	var top := [GovernorSys.may_found_by_heirs(state, root),
		GovernorSys.may_found_by_heirs(state, child),
		GovernorSys.may_found_by_heirs(state, grandchild)]
	failures += TestUtil.check(
		base == [true, false, false] and top == [true, true, true]
			and Ascension.bonuses(state).heirs == 2,
		"profundidad 0/1/2: sin Dinastía solo la raíz, con 2 rangos las tres",
		"tope mal calculado: sin Dinastía %s, con 2 rangos %s" % [str(base), str(top)]
	)
	return failures


## Ciudad raíz delegada + colonia-pueblo delegada y llena, con este legado: al menos 5.000 ciclos
## y, después, hasta que llega la segunda colonia de la raíz (tope 40.000).
## Devuelve [hijos de la raíz, hijos de la colonia, nietos fundados o en camino de los hijos de la
## colonia, expediciones en camino de la colonia]. Con el reloj por escala, la segunda expedición
## de una ciudad tarda 2.400 × 1,5 × 7 = 25.200 ciclos: ya no cabe en 5.000, así que se espera a
## que llegue en vez de acortar el caso. El tope era 25.000 con el reloj ×4 (14.400); con ×7
## (M5 de «Plan - Balance de la era») ya no llegaba, y 40.000 le deja holgura. La colonia, que es pueblo, manda la suya a los ~2.430.
## Los hijos cuentan llegadas, y lo que el tope prohíbe se mira también en camino: alargar el
## escenario solo le da más tiempo a una nieta para colarse.
func _run_two_generations(legacy: PackedStringArray) -> Array:
	var hut := Content.building_index("hut")
	var farm := Content.building_index("farm")
	var engine := TestUtil.make_engine(5006)
	var state := engine.state
	state.legacy_nodes = legacy
	var root := state.root()
	root.tier = Content.CITY
	root.buildings[hut] = 30
	root.buildings[farm] = 12
	root.pop = 90.0
	for i in Goods.COUNT:
		root.stocks[i] = 600.0
	var colony := TestUtil.found_now(state, root, engine.params)
	assert(colony != null and colony.tier == Content.TOWN)
	# La colonia «ya ha promocionado»: se le pone el estado a mano para no esperar a que crezca,
	# sin tocar `SimParams`.
	colony.buildings[hut] = 20
	colony.buildings[farm] = 8
	colony.pop = 60.0
	for i in Goods.COUNT:
		colony.stocks[i] = 400.0
	var policy := Governor.balanced()
	# Sin ascender, para que cada nodo siga siendo lo que el caso dice que es.
	policy.may_promote = false
	GovernorSys.delegate(state, root, policy)
	GovernorSys.delegate(state, colony, policy.duplicate_governor())
	for step in 1600:
		if step >= 200 and root.children.size() >= 2:
			break
		engine.tick(25.0)
	var grandchildren_founded := 0
	for id in colony.children:
		var grandchild: SimNode = state.nodes.get(id)
		if grandchild != null:
			grandchildren_founded += grandchild.children.size()
			grandchildren_founded += 1 if state.expedition_of(id) != null else 0
	var colony_travelling := 1 if state.expedition_of(colony.id) != null else 0
	return [root.children.size(), colony.children.size(), grandchildren_founded,
		colony_travelling]


## **Delegar no es rendirse.** El gobernador hace lo que se le deja hacer y nada más.
##
## Es la regla 3 vista desde el otro lado: si sin delegar no se destina, ni se compra, ni se
## investiga nada solo, delegando tiene que poder decirse *hasta dónde*. Un permiso apagado que
## el gobernador se saltara sería peor que no tenerlo: la UI enseñaría un interruptor que miente.
##
## Repartir la gente no lleva permiso y por eso se comprueba aquí que **sí** sigue pasando: es
## la línea que separa «gobernador atado» de «gobernador apagado».
func _the_governor_obeys_its_leash() -> int:
	var quarry := Content.building_index("quarry")
	var hut := Content.building_index("hut")

	var engine := TestUtil.make_engine(4310)
	var node := engine.state.root()
	node.tier = Content.TOWN
	node.buildings[hut] = 20
	node.buildings[quarry] = 3
	node.buildings[Content.building_index("farm")] = 12
	node.pop = 60.0
	for i in Goods.COUNT:
		node.stocks[i] = 4000.0
	node.governor = Governor.balanced()
	node.governor.may_build = false
	node.governor.may_research = false
	node.governor.may_promote = false

	var buildings_before := node.building_total()
	for _i in 20:
		engine.tick(30.0)

	var failures := TestUtil.check(
		node.building_total() == buildings_before,
		"con el permiso de construir quitado no levanta nada en 600 ciclos (%d edificios)"
			% buildings_before,
		"construye sin permiso: %d → %d edificios" % [
			buildings_before, node.building_total(),
		]
	)
	failures += TestUtil.check(
		node.upgrades.is_empty(),
		"y no investiga nada, con 4.000 de cada recurso en el almacén",
		"investiga sin permiso: %s" % [Array(node.upgrades)]
	)
	failures += TestUtil.check(
		node.tier == Content.TOWN,
		"y no asciende de escala aunque cumpla el umbral",
		"asciende sin permiso: ha llegado a %s" % Content.tier(node.tier).name
	)
	# Y aun así reparte: es lo único que un gobernador hace siempre.
	failures += TestUtil.check(
		Integrator.idle_population(node) < node.pop,
		"pero la gente sí está destinada: %.0f ociosos de %.0f habitantes" % [
			Integrator.idle_population(node), node.pop,
		],
		"atado de pies y manos no reparte a nadie: %.0f ociosos de %.0f" % [
			Integrator.idle_population(node), node.pop,
		]
	)
	return failures


## Las prioridades **se notan**. Dos gobernadores con la misma partida y distinta política
## tienen que repartir distinto.
##
## Sin esto, los cuatro deslizadores de la consola podrían no estar conectados a nada y la
## suite seguiría en verde: `Governor.normalized()` se llama, se pasa a `Situation.weights`… y
## todo lo demás podría ignorarlo sin que nadie se entere.
func _priorities_change_behaviour() -> int:
	var quarry := Content.building_index("quarry")
	var farm := Content.building_index("farm")

	# Se mide **la cantera contra la cantera**, no la cantera contra las granjas: el suelo que
	# `_good_weight` le da a la comida cuando ella pone el techo se aplica a las dos partidas
	# por igual, así que comparar oficios distintos mediría ese suelo y no la política.
	var mined := {}
	for industrial in [false, true]:
		var engine := TestUtil.make_engine(9090)
		var node := engine.state.root()
		node.tier = Content.TOWN
		# Alojamiento corto y campo de sobra: así la comida **no** pone el techo y su suelo de
		# urgencia no entra. Lo que se lee entonces es la política y nada más.
		node.buildings[Content.building_index("hut")] = 10
		node.buildings[farm] = 20
		node.buildings[quarry] = 20
		node.pop = 60.0
		for i in Goods.COUNT:
			node.stocks[i] = 2000.0
		node.governor = Governor.balanced()
		# Sin permiso de construir: lo que se mide es el reparto, no lo que se levante después.
		node.governor.may_build = false
		node.governor.food = 0.1 if industrial else 1.0
		node.governor.industry = 1.0 if industrial else 0.1
		for _i in 4:
			engine.tick(30.0)
		mined[industrial] = node.jobs[quarry]

	return TestUtil.check(
		mined[true] > mined[false],
		"la política manda: %.0f mineros con la industria al máximo, %.0f con la comida" % [
			mined[true], mined[false],
		],
		"cambiar las prioridades no cambia el reparto: %.0f mineros en los dos casos" % [
			mined[true],
		]
	)


## Las órdenes **se notan**, como las prioridades. Una orden fijada tiene que cambiar lo que
## la define frente a la misma partida sin orden: misma semilla, mismos pesos, mismo pueblo.
##
## Las cotas son holgadas a propósito —«menos de la mitad», «antes», «diez puntos más»— y no
## cifras exactas: lo que se comprueba es que la orden está conectada, no el balance de hoy.
## `tick(30)` en vez de `tick(1)` porque el gobernador decide en checkpoints de 30 ciclos y el
## resultado es el mismo con un coste treinta veces menor.
func _orders_change_behaviour() -> int:
	var none := _order_run(Governor.Order.NONE)

	# STOCKPILE: no gasta salvo lo que desborda, así que apenas levanta nada y no funda.
	var hoard := _order_run(Governor.Order.STOCKPILE)
	var failures := TestUtil.check(
		hoard["built"] * 2 < none["built"] and hoard["first_child"] < 0,
		"orden STOCKPILE: %d edificios nuevos frente a %d sin orden, y ninguna colonia" % [
			hoard["built"], none["built"],
		],
		"STOCKPILE no frena el gasto: %d edificios frente a %d, primera expedición en el ciclo %d"
			% [hoard["built"], none["built"], hoard["first_child"]]
	)

	# EXPAND: funda con el pueblo al 60 % del techo y no al 90 %, así que funda antes.
	var expand := _order_run(Governor.Order.EXPAND)
	failures += TestUtil.check(
		expand["first_child"] >= 0 and none["first_child"] >= 0
			and expand["first_child"] < none["first_child"],
		"orden EXPAND: primera expedición en el ciclo %d frente al %d sin orden" % [
			expand["first_child"], none["first_child"],
		],
		"EXPAND no adelanta la fundación: ciclo %d frente a %d (-1 es que no funda)" % [
			expand["first_child"], none["first_child"],
		]
	)
	# Los permisos mandan sobre las órdenes: expandir sin `may_expand` no funda.
	var leashed := _order_run(Governor.Order.EXPAND, false, false)
	failures += TestUtil.check(
		leashed["first_child"] < 0,
		"y con `may_expand` quitado, EXPAND no funda en %d ciclos" % ORDER_RUN_CYCLES,
		"EXPAND se salta el permiso: funda en el ciclo %d sin `may_expand`"
			% leashed["first_child"]
	)

	# SPECIALIZE: concentra la mano de obra en el eje dominante, que aquí es la comida.
	var spread := _top_job_share(Governor.Order.NONE)
	var focused := _top_job_share(Governor.Order.SPECIALIZE)
	failures += TestUtil.check(
		focused > spread + 0.1,
		"orden SPECIALIZE: el oficio más poblado pasa del %.0f %% al %.0f %% de los destinados"
			% [spread * 100.0, focused * 100.0],
		"SPECIALIZE no concentra: el oficio más poblado tiene el %.0f %% frente al %.0f %%" % [
			focused * 100.0, spread * 100.0,
		]
	)
	# Y especializar en industria no puede matar de hambre: la salvaguarda de `_good_weight` se
	# aplica después de la orden.
	var forge := _order_run(Governor.Order.SPECIALIZE, true)
	failures += TestUtil.check(
		not forge["starving"] and forge["pop"] >= 60.0,
		"SPECIALIZE con la política cargada a industria no pasa hambre: %.0f hab" % forge["pop"],
		"SPECIALIZE en industria mata de hambre: %.0f hab, %s" % [
			forge["pop"], "pasando hambre" if forge["starving"] else "sin hambre ahora",
		]
	)
	return failures


const ORDER_RUN_CYCLES := 900


## El pueblo delegado de `determinism_test._founding_town`, con la orden fijada antes de empezar,
## avanzado `ORDER_RUN_CYCLES`. Devuelve lo que define a cada orden.
func _order_run(order: Governor.Order, industrial := false, may_expand := true) -> Dictionary:
	var engine := TestUtil.make_engine(4242)
	var node := engine.state.root()
	node.tier = Content.TOWN
	node.buildings[Content.building_index("hut")] = 20
	node.buildings[Content.building_index("farm")] = 8
	node.pop = 60.0
	for i in Goods.COUNT:
		node.stocks[i] = 400.0
	node.governor = Governor.balanced()
	if industrial:
		node.governor.food = 0.1
		node.governor.industry = 1.0
	node.governor.may_expand = may_expand
	node.governor.order = order
	engine.state.refresh_totals()

	var built_before := node.building_total()
	var first_child := -1
	for _i in ORDER_RUN_CYCLES / 30:
		engine.tick(30.0)
		# Lo que adelanta la orden es la **salida**: el reloj de la expedición es el mismo para
		# todos. Se mide la primera expedición lanzada, llegue o no dentro de la tanda.
		if first_child < 0 and (not node.children.is_empty()
				or engine.state.expedition_of(node.id) != null):
			first_child = engine.state.cycle
	return {
		"built": node.building_total() - built_before,
		"first_child": first_child,
		"pop": node.pop,
		"starving": node.starving,
	}


## Fracción de los destinados que tiene el oficio más poblado, con la misma política por
## defecto (la comida manda) y la orden dada. El pueblo es el de `_priorities_change_behaviour`
## más leñadores: alojamiento corto y campo de sobra, para que la comida **no** ponga el techo y
## su suelo de urgencia no tape la orden; sin permiso de construir, para medir solo el reparto.
## En el pueblo que funda (`_order_run`) el hambre del arranque ya llena las granjas con o sin
## orden, y la diferencia se pierde en el ruido.
func _top_job_share(order: Governor.Order) -> float:
	var engine := TestUtil.make_engine(9090)
	var node := engine.state.root()
	node.tier = Content.TOWN
	node.buildings[Content.building_index("hut")] = 10
	node.buildings[Content.building_index("farm")] = 20
	node.buildings[Content.building_index("quarry")] = 20
	node.buildings[Content.building_index("woodcutter")] = 20
	node.pop = 60.0
	for i in Goods.COUNT:
		node.stocks[i] = 2000.0
	node.governor = Governor.balanced()
	node.governor.may_build = false
	node.governor.order = order
	for _i in 4:
		engine.tick(30.0)
	var top := 0.0
	var placed := 0.0
	for workers in node.jobs:
		placed += workers
		top = maxf(top, workers)
	return top / maxf(placed, 1.0)


## **Se puede alojar en piedra.** Un pueblo sin madera pero con cantera sigue creciendo.
##
## Este es el test del muro de las ~500 almas. Mientras la cabaña y el almacén fueron las
## únicas fuentes de techo, el límite de un pueblo era el tope de madera y nada más: la cabaña
## nº 59 costaba más de lo que cabía en el almacén y ahí se acababa la partida, con la promoción
## a Ciudad pidiendo 1.000 habitantes que no podían existir. La casa comunal rompe eso porque
## se paga con lo que produce la cantera.
func _housing_can_be_bought_in_stone() -> int:
	var commons := Content.building_index("commons")
	var hut := Content.building_index("hut")

	var engine := TestUtil.make_engine(5309)
	var node := engine.state.root()
	node.tier = Content.TOWN
	node.buildings[hut] = 20
	node.buildings[Content.building_index("farm")] = 30
	node.buildings[Content.building_index("quarry")] = 10
	node.pop = 100.0
	node.stocks[Goods.STONE] = 6000.0
	# La madera justa para no poder pagar ni una cabaña más (la nº 21 cuesta 262).
	node.stocks[Goods.WOOD] = 200.0
	node.stocks[Goods.FOOD] = 1000.0
	node.governor = Governor.balanced()
	node.governor.may_research = false  # que no se gaste la piedra en mejoras

	for _i in 20:
		engine.tick(30.0)

	var housing_before := SimParams.new().base_housing + 20.0 * Content.building(hut).housing
	return TestUtil.check(
		node.buildings[commons] > 0,
		"sin madera para otra cabaña, el pueblo se aloja en piedra: %d casas comunales (techo %.0f → %.0f)"
			% [node.buildings[commons], housing_before, node.housing(engine.params)],
		"sin madera el pueblo se queda sin techo: 0 casas comunales y %.0f de piedra sin gastar"
			% node.stocks[Goods.STONE]
	)


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


## El árbol se enseña entero —lo comprado, lo que está a tiro y lo que aún no—, pero sin
## prometer nada de una escala a la que todavía no se ha llegado.
##
## Es lo que separa una progresión legible de una rejilla de botones que aparecen y desaparecen:
## el jugador tiene que ver la forma. Y la forma la calcula `UpgradeTreeView.depths`, que es
## función pura del catálogo y por eso se comprueba aquí sin abrir una ventana.
func _the_tree_has_a_shape() -> int:
	const TreeView := preload("res://ui/UpgradeTreeView.gd")
	var engine := TestUtil.make_engine(607)
	var node := engine.state.root()

	var ids := PackedStringArray()
	for def in Upgrading.tree_for(node):
		ids.append((def as Upgrades.Def).id)

	var failures := TestUtil.check(
		ids.has("crop_rotation") and ids.has("shared_hearth"),
		"el árbol de un asentamiento trae las %d de su escala, alcanzables o no" % ids.size(),
		"al árbol le faltan mejoras de su propia escala: %s" % str(ids)
	)
	failures += TestUtil.check(
		not ids.has("stone_tools"),
		"y ninguna de pueblo: lo que se promete tiene que poder cumplirse hoy",
		"el árbol de un asentamiento enseña mejoras de pueblo"
	)

	failures += TestUtil.check(
		Upgrading.state_of(node, "crop_rotation") == Upgrading.State.AVAILABLE
			and Upgrading.state_of(node, "granary") == Upgrading.State.LOCKED,
		"«Rotación de cultivos» está a tiro y «Granero» bloqueada",
		"los estados de partida del árbol no cuadran"
	)
	node.stocks[Goods.FOOD] = 300.0
	Upgrading.buy(node, "crop_rotation", 0.0, null)
	failures += TestUtil.check(
		Upgrading.state_of(node, "crop_rotation") == Upgrading.State.OWNED
			and Upgrading.state_of(node, "granary") == Upgrading.State.AVAILABLE,
		"comprarla la marca y desbloquea a su hija",
		"comprar una mejora no mueve el estado de su hija"
	)

	# Las profundidades: la fila en la que cae cada nodo al dibujarlo.
	var items := []
	for def in Upgrades.all():
		var d: Upgrades.Def = def
		items.append(TreeView.Item.make(
			d.id, d.icon, d.name, "", "", d.requires, TreeView.State.AVAILABLE, false))
	var depth := TreeView.depths(items)
	failures += TestUtil.check(
		int(depth["crop_rotation"]) == 0 and int(depth["granary"]) == 1
			and int(depth["shared_hearth"]) == 2
			# La cadena larga del pueblo: herramientas → arados → casas → bodegas → oficios.
			and int(depth["stone_tools"]) == 0 and int(depth["guild_hall"]) == 4,
		"cada mejora cae en la fila que le toca por sus requisitos",
		"las profundidades del árbol no cuadran: %s" % str(depth)
	)
	# `guild_hall` cuelga de dos padres a la vez: manda el más profundo, o el conector saldría
	# hacia arriba desde uno de ellos.
	failures += TestUtil.check(
		int(depth["guild_hall"]) > int(depth["apprentices"])
			and int(depth["guild_hall"]) > int(depth["deep_cellars"]),
		"una mejora con dos requisitos cae por debajo de los dos",
		"«Casa de oficios» no queda por debajo de sus dos requisitos"
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
		# Paso 25 hasta 3.000 ciclos: el mismo bucle que usa `era_probe` para el resto de la curva.
		reached.append(TestUtil.cycles_until(engine,
			func() -> bool: return Promotion.can_promote(engine.state, root), 3000.0, 25.0))

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


## **El ritmo del tramo temprano**: primer hijo (H2) y Ciudad (H3c), los dos contra **el
## objetivo** de «Plan - Balance de la era». Mide como `era_probe`: la raíz delegada en un
## gobernador equilibrado con todos los permisos, paso 25, el mismo `TestUtil.cycles_until` y una
## sola pasada que apunta los dos hitos. El pico de 1.000 hab (H3, cuando la primera ascensión
## rinde) ya no se vigila: es informativo, y Ciudad, que lo sigue, es lo que marca la era.
func _early_curve_pacing() -> int:
	# H2, ~1 h (2.400-5.400): el primer hijo es Pueblo + 2.400 ciclos de viaje, 3.150 a paso 25.
	# Ciudad, ~6 h (14.400-32.400): la marca el cuarto hijo, porque Pueblo → Ciudad pide las
	# cuatro plazas ocupadas; 15.975 en `era_probe` (hijos en 3.150 / 5.850 / 9.900 / 15.975).
	# Las dos cifras, iguales en las 4 semillas (la economía no depende de la semilla).
	const H2_RANGE := Vector2(2400.0, 5400.0)
	const H3C_RANGE := Vector2(14400.0, 32400.0)
	# El techo de tolerancia de Ciudad en la sonda: más allá ya no es ritmo, es un fallo de balance.
	const CEILING := 32400.0

	var h2 := PackedFloat64Array()
	var h3c := PackedFloat64Array()
	for seed_value in [11, 222, 3333, 44444]:
		var engine := TestUtil.make_engine(seed_value)
		var state := engine.state
		var root := state.root()
		# Delegar por la ruta única, como la sonda: lo que funde la raíz nace delegado y crece.
		GovernorSys.delegate(state, root, Governor.balanced())
		var at := {"h2": -1.0, "h3c": -1.0}
		var both := func() -> bool:
			if at["h2"] < 0.0 and root.children.size() > 0:
				at["h2"] = state.cycle
			if at["h3c"] < 0.0 and root.tier >= Content.CITY:
				at["h3c"] = state.cycle
			return at["h2"] >= 0.0 and at["h3c"] >= 0.0
		TestUtil.cycles_until(engine, both, CEILING, 25.0)
		h2.append(at["h2"])
		h3c.append(at["h3c"])

	return (_within("H2 (primer hijo)", h2, H2_RANGE)
		+ _within("H3c (Ciudad)", h3c, H3C_RANGE))


## Todas las semillas dentro de `bounds` (`x` mínimo, `y` máximo), y ninguna sin llegar.
static func _within(label: String, reached: PackedFloat64Array, bounds: Vector2) -> int:
	var worst := 0.0
	var best := INF
	for at in reached:
		if at < 0.0:
			return TestUtil.check(false, "",
				"%s: alguna semilla no llega antes del tope: %s" % [label, Array(reached)])
		worst = maxf(worst, at)
		best = minf(best, at)
	return TestUtil.check(
		best >= bounds.x and worst <= bounds.y,
		"%s entre los ciclos %.0f y %.0f (rango %.0f-%.0f)" % [
			label, best, worst, bounds.x, bounds.y,
		],
		"el ritmo se ha desviado: %s entre %.0f y %.0f, fuera de %.0f-%.0f" % [
			label, best, worst, bounds.x, bounds.y,
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


## **Un gobernador no deja morir un nodo en silencio.** Al entrar en hambruna un nodo delegado
## sale un `famine`, uno por episodio y no uno por ciclo: lo que se avisa es el cambio. Con el
## nodo a mano no sale ninguno, porque el jugador ya tiene la población en rojo delante.
func _famine_warns_once_per_episode() -> int:
	var delegated := _famine_run(true)
	var by_hand := _famine_run(false)
	var failures := TestUtil.check(
		delegated["episodes"] >= 1 and delegated["starving_cycles"] > delegated["episodes"],
		"delegado y sin granjeros, pasa hambre %d ciclos en %d episodio(s)" % [
			delegated["starving_cycles"], delegated["episodes"],
		],
		"el caso no prueba nada: %d ciclos de hambre en %d episodio(s)" % [
			delegated["starving_cycles"], delegated["episodes"],
		]
	)
	failures += TestUtil.check(
		delegated["famines"] == delegated["episodes"],
		"`famine` sale una vez por episodio: %d avisos para %d episodio(s)" % [
			delegated["famines"], delegated["episodes"],
		],
		"`famine` sale %d veces para %d episodio(s) de hambre" % [
			delegated["famines"], delegated["episodes"],
		]
	)
	failures += TestUtil.check(
		delegated["well_formed"],
		"y lo firma el motor (`system`) sobre el nodo que pasa hambre",
		"`famine` sale con otro actor o sin el nodo que pasa hambre"
	)
	failures += TestUtil.check(
		by_hand["episodes"] >= 1 and by_hand["famines"] == 0,
		"a mano no avisa: %d episodio(s) de hambre y ningún `famine`" % by_hand["episodes"],
		"a mano: %d episodio(s) y %d `famine` (esperados ≥1 y 0)" % [
			by_hand["episodes"], by_hand["famines"],
		]
	)
	return failures


## Quita los granjeros al asentamiento, lo deja correr ciclo a ciclo y cuenta a la vez los
## episodios de hambre (flancos de subida de `starving`) y los `famine` del log.
func _famine_run(delegate: bool) -> Dictionary:
	var engine := TestUtil.make_engine(2024)
	# Los tests nacen con el log apagado: aquí lo que se mide es justo lo que pasa por él.
	engine.events.enabled = true
	var root := engine.state.root()
	if delegate:
		root.governor = Governor.balanced()
		root.governor_last_cycle = engine.state.cycle
	Construction.set_workers(root, Content.building_index("farm"), 0.0)
	Construction.set_workers(root, Content.building_index("woodcutter"), root.pop)

	# Se cuenta al vuelo y no leyendo `entries`: el ring buffer se queda con 256 y un
	# gobernador construyendo los llena. Un Array, porque la lambda captura los int por valor.
	var famines: Array[Dictionary] = []
	engine.events.event_pushed.connect(func(entry: Dictionary) -> void:
		if entry["category"] == "famine":
			famines.append(entry))

	var episodes := 0
	var starving_cycles := 0
	var was := root.starving
	for _i in 300:
		engine.tick(1.0)
		if root.starving:
			starving_cycles += 1
			if not was:
				episodes += 1
		was = root.starving

	var well_formed := not famines.is_empty()
	for entry in famines:
		well_formed = well_formed and entry["actor"] == "system" and entry["node"] == root.id
	return {
		"episodes": episodes,
		"starving_cycles": starving_cycles,
		"famines": famines.size(),
		"well_formed": well_formed or not delegate,
	}


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

	var child := TestUtil.found_now(state, root, engine.params)
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


## **La puerta cerrada.** Una escala sin edificios propios no tiene nada que jugar, así que no
## se promociona a ella aunque se cumpla el umbral de sobra: ni a mano ni delegando. La condición
## sale de los datos (`TierDef.is_playable`), así que cuando región tenga su primer edificio esto
## deja de aplicarse a ella sin tocar el código.
func _empty_tiers_are_closed() -> int:
	var failures := 0

	# Cada tier cuyo siguiente está vacío: con un umbral cumplido de sobra, la puerta sigue cerrada.
	var closed := PackedStringArray()
	var leaks := PackedStringArray()
	for tier in range(Content.TIER_COUNT - 1):
		if Content.tier(tier + 1).is_playable():
			continue
		var engine := TestUtil.make_engine(4040 + tier)
		var root := engine.state.root()
		root.tier = tier
		root.pop = 1.0e9
		root.buildings[Content.building_index("hut")] = 1000
		engine.state.refresh_totals()
		if Promotion.can_promote(engine.state, root):
			leaks.append("%s → %s" % [Content.tier(tier).name, Content.tier(tier + 1).name])
		else:
			closed.append(Content.tier(tier + 1).name)
	failures += TestUtil.check(
		leaks.is_empty() and not closed.is_empty(),
		"un tier sin edificios no es promocionable: %s" % ", ".join(closed),
		"se puede promocionar a una escala vacía: %s" % ", ".join(leaks)
	)

	# La raíz se queda en ciudad con el umbral de región cumplido.
	var engine := TestUtil.make_engine(4747)
	var state := engine.state
	var root := state.root()
	var city := Content.tier(Content.CITY)
	root.tier = Content.CITY
	root.pop = city.promote_pop * 1.5
	root.stocks[Goods.FOOD] = 1.0e4
	root.buildings[Content.building_index("hut")] = city.promote_buildings * 2
	state.refresh_totals()
	var threshold := city.can_promote(root.total_pop, root.building_total())
	failures += TestUtil.check(
		threshold and city.is_playable() and not Promotion.can_promote(state, root)
			and not Promotion.promote(state, root, null) and root.tier == Content.CITY,
		"una ciudad con %.0f hab y %d edificios no asciende a una región vacía" % [
			root.total_pop, root.building_total(),
		],
		"la raíz ha pasado de ciudad con región vacía (umbral cumplido: %s, tier %d)" % [
			threshold, root.tier,
		]
	)

	# El gobernador hereda la guarda: con permiso para promocionar, tampoco pasa.
	var policy := Governor.balanced()
	policy.may_promote = true
	# Se llama a `GovernorSys.run` sin avanzar el integrador: así el umbral sigue cumplido en el
	# checkpoint y el test no puede pasar solo porque la ciudad se haya despoblado.
	GovernorSys.delegate(state, root, policy)
	state.cycle += engine.params.governor_interval * 3.0
	var decisions := GovernorSys.run(state, root, engine.params, null)
	state.refresh_totals()
	failures += TestUtil.check(
		decisions > 0 and city.can_promote(root.total_pop, root.building_total())
			and root.tier == Content.CITY and state.peak_tier <= Content.CITY,
		"el gobernador con may_promote decide %d veces con el umbral cumplido y tampoco pasa" \
			% decisions,
		"el gobernador ha promocionado a una escala vacía, o no llegó a decidir (tier %d, %d decisiones)" \
			% [root.tier, decisions]
	)
	return failures


## **🎭 La influencia es √ de la cultura del subárbol.** No se almacena: `WorldState.influence_of`
## la calcula al vuelo sumando la 📜 del nodo y de todos sus descendientes, como `total_pop`. Así
## una ciudad con templos en sus pueblos también tiene influencia, y la cultura de un nieto cuenta.
## Y la cultura no tiene tope (`Goods.UNCAPPED`): si lo tuviera, la puerta podría quedar por encima.
func _influence_is_root_of_subtree_culture() -> int:
	var engine := TestUtil.make_engine(7171)
	var state := engine.state
	var params := engine.params
	var root := state.root()
	root.tier = Content.CITY
	root.pop = 5000.0
	root.stocks[Goods.FOOD] = 1.0e4
	state.refresh_totals()

	var failures := TestUtil.check(
		state.influence_of(root) == 0.0,
		"sin cultura en el árbol, la influencia es 0",
		"sin cultura, la influencia es %f" % state.influence_of(root)
	)

	var town := TestUtil.found_now(state, root, params)
	if town == null:
		return failures + TestUtil.check(false, "", "la ciudad no ha podido fundar un pueblo")
	town.pop = 500.0
	town.stocks[Goods.FOOD] = 1.0e4
	state.refresh_totals()
	var village := TestUtil.found_now(state, town, params)
	if village == null:
		return failures + TestUtil.check(false, "", "el pueblo no ha podido fundar una aldea")

	# 900 + 1.600 + 1.500 = 4.000 → √ = 63,2…; con la de un solo nivel saldría √900 = 30.
	root.stocks[Goods.CULTURE] = 900.0
	town.stocks[Goods.CULTURE] = 1600.0
	village.stocks[Goods.CULTURE] = 1500.0
	var expected := sqrt(4000.0)
	failures += TestUtil.check(
		is_equal_approx(state.influence_of(root), expected)
			and is_equal_approx(state.influence_of(town), sqrt(3100.0))
			and is_equal_approx(state.influence_of(village), sqrt(1500.0)),
		"la influencia es √ de la cultura del subárbol: raíz %.2f, pueblo %.2f, aldea %.2f" % [
			state.influence_of(root), state.influence_of(town), state.influence_of(village),
		],
		"influencia raíz %.4f (esperaba %.4f), pueblo %.4f (%.4f), aldea %.4f (%.4f)" % [
			state.influence_of(root), expected, state.influence_of(town), sqrt(3100.0),
			state.influence_of(village), sqrt(1500.0),
		]
	)
	failures += TestUtil.check(
		Goods.UNCAPPED.has(Goods.CULTURE) and root.storage_caps(params)[Goods.CULTURE] == INF,
		"la cultura no tiene tope: la puerta de influencia siempre es alcanzable",
		"la cultura tiene tope: la puerta de influencia podría quedar por encima de él"
	)
	return failures


## **🎭 Región pide influencia.** Una ciudad con sus seis pueblos, los 10.000 hab y los 40
## edificios no asciende sin influencia (`TierDef.promote_influence`, mirada en
## `Promotion.can_promote`, la lista única: botón, ⬆️, `Main` y gobernador), y sí en cuanto la
## cultura del subárbol llega a promote_influence². La cultura no se gasta al ascender: es un
## marcador. La que cuenta puede estar en los pueblos, no solo en la ciudad.
func _region_needs_influence() -> int:
	var engine := TestUtil.make_engine(7272)
	var state := engine.state
	var params := engine.params
	var root := state.root()
	var city := Content.tier(Content.CITY)
	root.tier = Content.CITY
	root.pop = city.promote_pop
	root.stocks[Goods.FOOD] = 1.0e4
	root.buildings[Content.building_index("hut")] = city.promote_buildings
	state.refresh_totals()
	var children: Array[SimNode] = []
	for _i in city.promote_children:
		children.append(TestUtil.found_now(state, root, params))
		state.refresh_totals()
	if children.has(null):
		return TestUtil.check(false, "", "la ciudad no ha podido fundar sus pueblos")

	var gate := city.promote_influence
	var everything_else := city.can_promote(root.total_pop, root.building_total()) \
		and Promotion.grown_children(state, root) >= city.promote_children \
		and Promotion.next_tier_playable(root) \
		and root.tier < Promotion.tier_ceiling(state, root)
	var failures := TestUtil.check(
		gate > 0.0 and everything_else and not Promotion.can_promote(state, root)
			and not Promotion.promote(state, root, null) and root.tier == Content.CITY,
		"con %d pueblos, %.0f hab y %d edificios, sin influencia no asciende (pide %.0f 🎭)" % [
			Promotion.grown_children(state, root), root.total_pop, root.building_total(), gate,
		],
		"la ciudad asciende sin influencia, o falla por otra cosa (resto cumplido: %s, tier %d)" % [
			everything_else, root.tier,
		]
	)

	# Un pelo por debajo: la mitad en la ciudad y la otra mitad en un pueblo, sin llegar.
	var short := gate * gate - 100.0
	root.stocks[Goods.CULTURE] = short * 0.5
	children[0].stocks[Goods.CULTURE] = short * 0.5
	failures += TestUtil.check(
		state.influence_of(root) < gate and not Promotion.can_promote(state, root),
		"con %.2f de %.0f influencia, todavía no" % [state.influence_of(root), gate],
		"asciende con %.4f de %.0f influencia" % [state.influence_of(root), gate]
	)

	# Justo lo que pide, repartido igual: la del pueblo cuenta para la ciudad.
	children[0].stocks[Goods.CULTURE] = gate * gate - root.stocks[Goods.CULTURE]
	var culture_before := root.stocks[Goods.CULTURE] + children[0].stocks[Goods.CULTURE]
	var promoted := Promotion.promote(state, root, null)
	var culture_after := root.stocks[Goods.CULTURE] + children[0].stocks[Goods.CULTURE]
	failures += TestUtil.check(
		promoted and root.tier == Content.REGION and culture_after == culture_before,
		"con %.0f de influencia (la mitad en un pueblo) asciende a región, y la cultura no se gasta" \
			% gate,
		"con la influencia justa no asciende (tier %d) o la cultura ha cambiado (%.1f → %.1f)" % [
			root.tier, culture_before, culture_after,
		]
	)
	return failures


## **Región (M2): se llega con hijos.** Una ciudad con los 10.000 hab y los 40 edificios no basta:
## hacen falta `promote_children` pueblos (la escala más alta que un hijo de ciudad puede tener).
## Un asentamiento no cuenta. Con todos (seis), la puerta de M0 se abre sola porque región ya tiene
## edificio, y en la región los establos producen 🐎.
func _region_is_reachable() -> int:
	var engine := TestUtil.make_engine(7070)
	var state := engine.state
	var params := engine.params
	var root := state.root()
	var city := Content.tier(Content.CITY)
	root.tier = Content.CITY
	root.pop = city.promote_pop
	root.stocks[Goods.FOOD] = 1.0e4
	root.buildings[Content.building_index("hut")] = city.promote_buildings
	# 🎭 La influencia de sobra desde el principio: este test mira los hijos, y cada «no asciende»
	# tiene que seguir siendo por ellos. La puerta de influencia la mide `_region_needs_influence`.
	root.stocks[Goods.CULTURE] = city.promote_influence * city.promote_influence + 1000.0
	state.refresh_totals()

	var failures := TestUtil.check(
		city.promote_children > 0 and Content.tier(Content.REGION).is_playable()
			and not Promotion.can_promote(state, root),
		"sin hijos, una ciudad con %.0f hab y %d edificios no asciende (pide %d pueblos)" % [
			root.total_pop, root.building_total(), city.promote_children,
		],
		"una ciudad sin hijos puede ascender a región, o región sigue cerrada"
	)

	var children: Array[SimNode] = []
	for _i in city.promote_children:
		children.append(TestUtil.found_now(state, root, params))
		state.refresh_totals()
	# Uno de ellos se queda en asentamiento: no cuenta, y con él la cuenta se queda corta.
	children[0].tier = Content.SETTLEMENT
	var short := Promotion.grown_children(state, root)
	var blocked := not Promotion.can_promote(state, root)
	children[0].tier = Content.TOWN
	failures += TestUtil.check(
		not children.has(null) and blocked and short == city.promote_children - 1,
		"con un hijo en asentamiento cuentan %d de %d, y no asciende" % [
			short, city.promote_children,
		],
		"un asentamiento cuenta como pueblo para ascender a región (%d hijos crecidos)" % short
	)

	var grown := Promotion.grown_children(state, root)
	var promoted := Promotion.promote(state, root, null)
	failures += TestUtil.check(
		promoted and root.tier == Content.REGION and state.peak_tier == Content.REGION,
		"con %d pueblos, la ciudad asciende a región" % grown,
		"la ciudad no asciende a región con todo cumplido (tier %d)" % root.tier
	)

	# Los establos: se construyen con lo que da una ciudad y producen 🐎 lineal en los mozos.
	var stables := Content.building_index("stables")
	root.stocks[Goods.STONE] = 1.0e4
	root.stocks[Goods.TOOLS] = 1.0e4
	root.stocks[Goods.WOOD] = 1.0e4
	var built := Construction.build(root, stables, state.cycle, null) \
		and Construction.build(root, stables, state.cycle, null)
	Construction.set_workers(root, stables, 8.0)
	var rate := Integrator.snapshot(root, params).rates[Goods.TRANSPORT]
	failures += TestUtil.check(
		built and Content.goods_for_tier(Content.REGION).has(Goods.TRANSPORT)
			and not Content.goods_for_tier(Content.CITY).has(Goods.TRANSPORT)
			and is_equal_approx(rate, 8.0 * 0.25),
		"dos establos con 8 mozos dan %.2f 🐎/ciclo, y el 🐎 solo aparece en región" % rate,
		"los establos no producen lo esperado: %s construidos, %.3f 🐎/ciclo" % [built, rate]
	)
	return failures


## Una ruta **gasta 🐎 en el origen**, a `Logistics.TRANSPORT_PER_FLOW` por unidad de caudal, y sin
## 🐎 se corta. Se mide con madera, que aquí nadie produce ni consume: lo que llega es lo movido.
func _routes_run_on_transport() -> int:
	var engine := TestUtil.make_engine(7171)
	var state := engine.state
	var params := engine.params
	var root := state.root()
	root.tier = Content.REGION
	root.pop = 500.0
	root.stocks[Goods.FOOD] = 1.0e4
	state.refresh_totals()
	var child := TestUtil.found_now(state, root, params)
	var woodcutter := Content.building_index("woodcutter")
	var stables := Content.building_index("stables")
	root.jobs[woodcutter] = 0.0
	child.jobs[woodcutter] = 0.0
	root.buildings[stables] = 1
	Construction.set_workers(root, stables, 4.0)  # 1 🐎/ciclo
	root.stocks[Goods.WOOD] = 1000.0

	# Con establos: 2 de caudal cuestan 1 🐎/ciclo, justo lo que dan.
	Logistics.set_route(state, root.id, child.id, Goods.WOOD, 2.0)
	var cost := 2.0 * Logistics.TRANSPORT_PER_FLOW
	var net := Integrator.snapshot(root, params).rates[Goods.TRANSPORT]
	root.stocks[Goods.TRANSPORT] = 10.0
	engine.tick(10.0)
	var failures := TestUtil.check(
		is_equal_approx(net, 1.0 - cost) and is_equal_approx(root.stocks[Goods.TRANSPORT], 10.0)
			and is_equal_approx(child.stocks[Goods.WOOD], 20.0),
		"una ruta de 2 🪵/ciclo gasta %.2f 🐎/ciclo en el origen; el establo lo repone (neto %+.2f)" \
			% [cost, net],
		"la ruta no gasta el 🐎 esperado: neto %.3f, 🐎 %.3f, madera llegada %.3f" % [
			net, root.stocks[Goods.TRANSPORT], child.stocks[Goods.WOOD],
		]
	)

	# Sin mozos en el establo: 3 🐎 en el almacén pagan 3 ciclos de ruta, y ahí se corta.
	Construction.set_workers(root, stables, 0.0)
	root.stocks[Goods.TRANSPORT] = 3.0
	var before := child.stocks[Goods.WOOD]
	engine.tick(10.0)
	var moved := child.stocks[Goods.WOOD] - before
	failures += TestUtil.check(
		absf(moved - 6.0) <= 1.0e-9 and root.stocks[Goods.TRANSPORT] <= 1.0e-9
			and state.routes[0].flow == 0.0,
		"sin establos, 3 🐎 mueven %.6f 🪵 y la ruta se corta hasta el checkpoint" % moved,
		"sin 🐎 la ruta no se corta: movido %.9f, 🐎 %.6f, caudal %.2f" % [
			moved, root.stocks[Goods.TRANSPORT], state.routes[0].flow,
		]
	)
	return failures


## El 🐎 lo paga **el padre**, baje la ruta o suba (enmienda de la decisión 1, M3). Una ciudad sin
## un solo 🐎 manda madera a su región, la región paga las dos rutas, y cuando a la región se le
## acaba el transporte se cortan las dos a la vez. Madera hacia arriba y piedra hacia abajo: aquí
## nadie las produce ni las consume, así que lo que llega es lo movido.
func _the_parent_pays_transport() -> int:
	var engine := TestUtil.make_engine(7272)
	var state := engine.state
	var params := engine.params
	var root := state.root()
	root.tier = Content.REGION
	root.pop = 500.0
	root.stocks[Goods.FOOD] = 1.0e4
	state.refresh_totals()
	var child := TestUtil.found_now(state, root, params)
	var woodcutter := Content.building_index("woodcutter")
	var quarry := Content.building_index("quarry")
	var stables := Content.building_index("stables")
	for node in [root, child]:
		node.jobs[woodcutter] = 0.0
		if quarry >= 0 and quarry < node.jobs.size():
			node.jobs[quarry] = 0.0
		node.stocks[Goods.TRANSPORT] = 0.0
	root.buildings[stables] = 1
	Construction.set_workers(root, stables, 4.0)  # 1 🐎/ciclo
	root.stocks[Goods.WOOD] = 0.0
	root.stocks[Goods.STONE] = 1000.0
	child.stocks[Goods.WOOD] = 1000.0
	child.stocks[Goods.STONE] = 0.0
	root.stocks[Goods.TRANSPORT] = 10.0

	# Hacia arriba, sin 🐎 en el hijo: 1 de caudal, que paga la región.
	var up := Logistics.set_route(state, child.id, root.id, Goods.WOOD, 1.0)
	var blocker := Logistics.route_blocker(state, child.id, root.id, Goods.WOOD)
	var child_net := Integrator.snapshot(child, params).rates[Goods.TRANSPORT]
	engine.tick(10.0)
	var failures := TestUtil.check(
		up != null and blocker.is_empty() and up.flow == 1.0 and child_net == 0.0
			and child.stocks[Goods.TRANSPORT] == 0.0
			and is_equal_approx(root.stocks[Goods.WOOD], 10.0)
			and is_equal_approx(root.stocks[Goods.TRANSPORT], 10.0 + 10.0 * 0.5),
		"una ciudad sin 🐎 manda 1 🪵/ciclo a su región; la región paga %.2f 🐎/ciclo" \
			% Logistics.TRANSPORT_PER_FLOW,
		"la ruta hacia arriba no va como debe: ruta %s, caudal %s, 🐎 del hijo %.3f (%+.3f/ciclo), "
			% [up != null, up.flow if up != null else -1.0, child.stocks[Goods.TRANSPORT],
				child_net]
			+ "madera llegada %.3f, 🐎 de la región %.3f" % [
				root.stocks[Goods.WOOD], root.stocks[Goods.TRANSPORT]]
	)

	# Las dos direcciones a la vez: 1 🪵 sube y 1 🪨 baja, y la región paga las dos (−1 + 1 = 0).
	Logistics.set_route(state, root.id, child.id, Goods.STONE, 1.0)
	var root_net := Integrator.snapshot(root, params).rates[Goods.TRANSPORT]
	child_net = Integrator.snapshot(child, params).rates[Goods.TRANSPORT]
	failures += TestUtil.check(
		is_equal_approx(root_net, 1.0 - 2.0 * Logistics.TRANSPORT_PER_FLOW)
			and child_net == 0.0,
		"con una ruta en cada sentido la región paga las dos (neto %+.2f) y el hijo nada" \
			% root_net,
		"el 🐎 no lo paga el padre: región %+.3f/ciclo, hijo %+.3f/ciclo" % [root_net, child_net]
	)

	# Sin mozos en el establo: 3 🐎 pagan 3 ciclos de dos rutas de 1, y se cortan las dos.
	Construction.set_workers(root, stables, 0.0)
	root.stocks[Goods.TRANSPORT] = 3.0
	var wood_before := root.stocks[Goods.WOOD]
	var stone_before := child.stocks[Goods.STONE]
	engine.tick(10.0)
	var wood := root.stocks[Goods.WOOD] - wood_before
	var stone := child.stocks[Goods.STONE] - stone_before
	var reason := Logistics.cut_reason(state, params, state.routes[0])
	failures += TestUtil.check(
		absf(wood - 3.0) <= 1.0e-9 and absf(stone - 3.0) <= 1.0e-9
			and root.stocks[Goods.TRANSPORT] <= 1.0e-9
			and state.routes[0].flow == 0.0 and state.routes[1].flow == 0.0
			and reason == "falta 🐎 en %s" % root.name,
		"sin 🐎 en la región, las dos rutas mueven %.6f 🪵 y %.6f 🪨 y se cortan: «%s»" \
			% [wood, stone, reason],
		"sin 🐎 en el padre las rutas no se cortan juntas: 🪵 %.9f, 🪨 %.9f, 🐎 %.6f, caudales "
			% [wood, stone, root.stocks[Goods.TRANSPORT]]
			+ "%.2f y %.2f, motivo «%s»" % [state.routes[0].flow, state.routes[1].flow, reason]
	)
	return failures


## El gobernador regional (M4): una región delegada con un hijo que pasa hambre y otro al que le
## sobra la comida tiende la ruta —por la región, porque las rutas solo van entre padre e hijo— y
## el hambriento sale del hambre. Con `may_route` apagado no toca ninguna, y el hambriento sigue
## igual. Los hijos no están delegados: su reparto no cambia, así que lo único que puede sacar al
## hambriento del hambre es la comida que le llega.
func _the_regional_governor_feeds_the_hungry() -> int:
	var on := _regional_run(true)
	var off := _regional_run(false)
	var failures := TestUtil.check(
		on.starving_before and not on.starving_after and on.food_routes == 2
			and on.hungry_in > 0.0 and on.routes_made_by_hand_gone
			and on.hungry_pop > off.hungry_cap + 1.0 and on.changes == 0,
		"con 🛣️ el gobernador tiende %d rutas de comida, por la región " % on.food_routes
			+ "(%.1f 🌾/ciclo al hambriento); " % on.hungry_in
			+ "hambre %s → %s, %.1f hab sobre un techo de %.1f, %d cambios de caudal en 600 ciclos, " \
			% [on.starving_before, on.starving_after, on.hungry_pop, on.hungry_cap, on.changes]
			+ "y borra la ruta de 🪵 hecha a mano",
		"el gobernador regional no da de comer al hambriento: %s" % [on]
	)
	failures += TestUtil.check(
		off.starving_before and off.starving_after and off.food_routes == 0
			and off.wood_routes == 1 and absf(off.hungry_pop - off.hungry_cap) < 0.01,
		"sin 🛣️ no crea ninguna ruta, no toca la de 🪵 y el hambriento sigue con hambre "
			+ "(%.1f hab sobre un techo de %.1f)" % [off.hungry_pop, off.hungry_cap],
		"con may_route apagado el gobernador toca las rutas: %s" % [off]
	)
	return failures


## El escenario de `TestUtil.make_regional_engine`, avanzado 600 ciclos.
func _regional_run(may_route: bool) -> Dictionary:
	var engine := TestUtil.make_regional_engine(7373, may_route)
	var state := engine.state
	var params := engine.params
	var root := state.root()
	var hungry: SimNode = state.nodes[root.children[1]]
	# El hambre se mira poco después del primer checkpoint (ciclo 30): sin comida de fuera, la
	# población baja hacia el techo de su campo y, al llegar, deja de contar como hambre aunque
	# siga sin poder crecer. Al final se mira a cuánta gente sostiene.
	# Y cuántas veces cambia el caudal que le llega una vez puesto: un reparto que oscila de un
	# checkpoint al siguiente es justo lo que la banda muerta tiene que evitar.
	var starving_before := Integrator.snapshot(hungry, params).starving
	var starving_after := true
	var last_in := 0.0
	var changes := 0
	for i in 600:
		engine.tick(1.0)
		if i == 44:
			starving_after = Integrator.snapshot(hungry, params).starving
		var now_in := 0.0
		for r in state.routes:
			if r.good == Goods.FOOD and r.to_id == hungry.id:
				now_in += r.rate
		if now_in != last_in and last_in > 0.0:
			changes += 1
		last_in = now_in
	var snap := Integrator.snapshot(hungry, params)
	var food_routes := 0
	var wood_routes := 0
	var hungry_in := 0.0
	for r in state.routes:
		if r.good == Goods.FOOD:
			food_routes += 1
			if r.to_id == hungry.id:
				hungry_in += r.rate
		elif r.good == Goods.WOOD:
			wood_routes += 1
	return {
		"starving_before": starving_before,
		"starving_after": starving_after,
		"hungry_pop": hungry.pop,
		"hungry_cap": snap.cap,
		"food_routes": food_routes,
		"wood_routes": wood_routes,
		"hungry_in": hungry_in,
		"routes_made_by_hand_gone": wood_routes == 0,
		"changes": changes,
	}


## Pueblo listo para fundar: población y comida de sobra y todas las plazas libres. Cada caso
## de abajo le quita una sola cosa, para que el motivo que se compruebe sea el único posible.
func _ready_to_found(seed_value: int) -> SimEngine:
	var engine := TestUtil.make_engine(seed_value)
	var root := engine.state.root()
	root.tier = Content.TOWN
	root.pop = 500.0
	root.stocks[Goods.FOOD] = 500.0
	engine.state.refresh_totals()
	return engine


## **Una ciudad tarda ×7 en mandar la misma expedición que un pueblo.** El reloj por escala
## (`TierDef.expedition_scale`) es lo que estira Región: sus pueblos 5.º y 6.º los funda ya la
## ciudad. Se comparan dos raíces idénticas, con los mismos hijos, que solo difieren en la escala,
## y se mira la expedición que **de verdad** sale (`arrive − depart`), no solo la fórmula. Tres
## hijos y no cuatro: un pueblo con cuatro ya no tiene plaza. Pueblo 2.400 × 1,5³ = 8.100 ciclos,
## ciudad 8.100 × 7 = 56.700. El factor era ×4 hasta M5 de «Plan - Balance de la era», que lo subió
## a ×7 para llevar Región de 107.100 a ~175.000 ciclos (`Content.gd`, Ciudad).
func _a_city_expedition_takes_seven_times() -> int:
	var spans := {}
	var expected := {}
	var params: SimParams = null
	for tier in [Content.TOWN, Content.CITY]:
		var engine := _ready_to_found(79)
		params = engine.params
		var state := engine.state
		var root := state.root()
		# Los hijos se fundan siendo pueblo (fundar es instantáneo con `found_now`, y así salen
		# asentamientos en los dos casos); la escala solo cambia justo antes de la que se mide.
		for _i in 3:
			TestUtil.found_now(state, root, params)
			root.pop = 500.0
			root.stocks[Goods.FOOD] = 500.0
			state.refresh_totals()
		root.tier = tier
		state.refresh_totals()
		expected[tier] = Promotion.expedition_cycles(state, root, params)
		var sent := Promotion.launch_expedition(state, root, params, null)
		spans[tier] = sent.arrive_cycle - sent.depart_cycle if sent != null else -1.0
	var town: float = spans[Content.TOWN]
	var city: float = spans[Content.CITY]
	var formula := params.expedition_base * pow(params.expedition_growth, 3) \
		* Content.tier(Content.CITY).expedition_scale
	return TestUtil.check(
		town > 0.0 and city > 0.0 and is_equal_approx(city, town * 7.0)
			and is_equal_approx(Content.tier(Content.CITY).expedition_scale, 7.0)
			and is_equal_approx(Content.tier(Content.TOWN).expedition_scale, 1.0)
			and is_equal_approx(city, expected[Content.CITY]) and is_equal_approx(city, formula),
		"con 3 hijos, la expedición de un pueblo tarda %.0f ciclos y la de una ciudad %.0f (×%.1f)"
			% [town, city, city / town],
		"el reloj por escala no se aplica: pueblo %.0f, ciudad %.0f (fórmula %.0f, se esperaba ×7)"
			% [town, city, formula]
	)


## El motivo y el `bool` tienen que contar lo mismo: si la frase dice que no, `can_found_child`
## dice que no, y la frase es la que se espera palabra por palabra.
func _blocked_for(engine: SimEngine, expected: String, what: String) -> int:
	var state := engine.state
	var root := state.root()
	var reason := Promotion.found_child_blocker(state, root, engine.params)
	var failures := TestUtil.check(
		reason == expected,
		"%s: «%s»" % [what, reason],
		"%s: se esperaba «%s» y el motivo es «%s»" % [what, expected, reason]
	)
	failures += TestUtil.check(
		not Promotion.can_found_child(state, root, engine.params),
		"%s: `can_found_child` también dice que no" % what,
		"%s: hay motivo para no fundar y aun así `can_found_child` dice que sí" % what
	)
	return failures


## Un asentamiento no tiene escala por debajo: lo dice así, no «0 de 0 hijos fundados».
func _cannot_found_in_a_settlement() -> int:
	var engine := _ready_to_found(71)
	engine.state.root().tier = Content.SETTLEMENT
	return _blocked_for(engine, "un asentamiento no puede tener hijos", "fundar desde un asentamiento")


## Con las plazas agotadas el motivo cuenta los hijos contra las plazas de la escala.
func _cannot_found_without_free_slots() -> int:
	var engine := _ready_to_found(72)
	var state := engine.state
	var root := state.root()
	# Antes de llenarlo, el pueblo listo tiene que poder: si no, el caso no prueba nada.
	var failures := TestUtil.check(
		Promotion.found_child_blocker(state, root, engine.params).is_empty()
			and Promotion.can_found_child(state, root, engine.params),
		"un pueblo con gente, comida y plazas puede fundar (sin motivo en contra)",
		"un pueblo listo para fundar tiene motivo en contra: «%s»"
			% Promotion.found_child_blocker(state, root, engine.params)
	)
	var slots := root.def().child_slots
	for _i in slots:
		TestUtil.found_now(state, root, engine.params)
	failures += TestUtil.check(
		root.children.size() == slots,
		"el pueblo funda sus %d hijos" % slots,
		"el pueblo solo ha fundado %d de %d hijos" % [root.children.size(), slots]
	)
	failures += _blocked_for(
		engine, "%d de %d hijos fundados" % [slots, slots], "fundar sin plazas libres"
	)
	return failures


## El umbral es el doble de los colonos que se llevan, y la frase dice ese número, no los colonos.
func _cannot_found_without_settlers() -> int:
	var engine := _ready_to_found(73)
	var root := engine.state.root()
	var min_pop := engine.params.initial_pop * 4.0
	root.pop = min_pop - 1.0
	engine.state.refresh_totals()
	return _blocked_for(
		engine, "necesitas %.0f habitantes" % min_pop, "fundar sin colonos suficientes"
	)


## Sin las provisiones del viaje no se funda, por mucha gente que haya.
func _cannot_found_without_food() -> int:
	var engine := _ready_to_found(74)
	engine.state.root().stocks[Goods.FOOD] = 49.0
	return _blocked_for(engine, "necesitas 50 🌾", "fundar sin provisiones")


## Con una expedición en camino no sale otra, y el motivo es ese aunque también falten plazas: va
## el primero tras el tier. Y la expedición ocupa su plaza en `free_slots`.
func _cannot_found_while_travelling() -> int:
	var engine := _ready_to_found(75)
	var state := engine.state
	var root := state.root()
	var slots := root.def().child_slots
	for _i in slots - 1:
		TestUtil.found_now(state, root, engine.params)
	var free_before := Promotion.free_slots(state, root)
	var sent := Promotion.launch_expedition(state, root, engine.params, null)
	var failures := TestUtil.check(
		sent != null and free_before == 1 and Promotion.free_slots(state, root) == 0,
		"la expedición en camino ocupa la última plaza: libres %d → %d" % [
			free_before, Promotion.free_slots(state, root),
		],
		"la expedición no ocupa su plaza: libres %d → %d (lanzada: %s)" % [
			free_before, Promotion.free_slots(state, root), sent != null,
		]
	)
	var left := OfflineReport.span(
		(sent.arrive_cycle - state.cycle) * engine.params.seconds_per_cycle) if sent != null else ""
	failures += _blocked_for(engine, "expedición en camino: llega en %s" % left,
		"fundar con una expedición en camino")
	failures += TestUtil.check(
		Promotion.launch_expedition(state, root, engine.params, null) == null
			and state.expeditions.size() == 1,
		"y una segunda expedición no sale: una por nodo",
		"han salido %d expediciones del mismo nodo" % state.expeditions.size()
	)
	return failures


## **Fundar es una expedición.** Los colonos y la comida salen al lanzarla y no cuentan en ningún
## total; el hijo nace al llegar, ni un tick antes, con lo que llevaba y la política que se le puso
## al salir; y la siguiente tarda `expedition_growth` veces más. Es la misma
## `launch_expedition` para el jugador y para el gobernador.
func _founding_is_an_expedition() -> int:
	var engine := _ready_to_found(76)
	engine.events.enabled = true
	var state := engine.state
	var params := engine.params
	var root := state.root()
	var pop_before := root.pop
	var food_before := root.stocks[Goods.FOOD]
	var policy := Governor.balanced()
	policy.growth = 0.45
	engine.events.actor = "governor"
	var sent := Promotion.launch_expedition(state, root, params, engine.events, policy)
	engine.events.actor = "player"
	if sent == null:
		return TestUtil.check(false, "", "un pueblo listo para fundar no lanza la expedición")
	state.refresh_totals()
	var settlers := Promotion.settler_pop(params)
	var failures := TestUtil.check(
		root.children.is_empty() and state.expedition_of(root.id) == sent
			and root.pop == pop_before - settlers
			and root.stocks[Goods.FOOD] == food_before - Promotion.settler_food(params)
			and root.total_pop == root.pop
			and sent.arrive_cycle == state.cycle + params.expedition_base,
		"al salir: %.0f colonos y %.0f 🌾 dejan el pueblo, no cuentan en ningún total y llegan en el ciclo %.0f"
			% [settlers, Promotion.settler_food(params), sent.arrive_cycle],
		"la expedición sale mal: hijos %d, pob %.1f (antes %.1f), total %.1f, llegada %.1f" % [
			root.children.size(), root.pop, pop_before, root.total_pop, sent.arrive_cycle,
		]
	)
	# Un ciclo antes de llegar no hay hijo, a saltos largos para que la llegada caiga dentro de un
	# tick y no en su borde.
	while state.cycle + 700.0 < sent.arrive_cycle - 1.0:
		engine.tick(700.0)
	engine.tick(sent.arrive_cycle - 1.0 - state.cycle)
	var early := root.children.size()
	engine.tick(300.0)
	var child: SimNode = state.nodes.get(root.children[0]) if root.children.size() == 1 else null
	var found_entry := {}
	for entry in engine.events.entries:
		if entry["category"] == "found":
			found_entry = entry
	failures += TestUtil.check(
		early == 0 and child != null and child.tier == Content.SETTLEMENT
			and child.parent_id == root.id and state.expeditions.is_empty()
			and child.pop > 0.0 and child.pop != settlers and child.governor != null
			and is_equal_approx(child.governor.growth, 0.45)
			# Su reloj de checkpoints arrancó en la llegada: va en múltiplos del intervalo desde ahí.
			and fmod(child.governor_last_cycle - sent.arrive_cycle, params.governor_interval) == 0.0,
		"el hijo nace al llegar (ni un ciclo antes), con la política de la salida, y vive: %.1f hab"
			% [child.pop if child != null else -1.0],
		"la llegada falla: hijos un ciclo antes %d, hijo %s, expediciones %d" % [
			early, "ninguno" if child == null else "%s tier %d pob %.1f gob %s" % [
				child.name, child.tier, child.pop, child.governor != null,
			], state.expeditions.size(),
		]
	)
	failures += TestUtil.check(
		not found_entry.is_empty() and found_entry["cycle"] == sent.arrive_cycle
			and found_entry["actor"] == "governor"
			and found_entry["data"] == {"parent": root.id, "tier": Content.SETTLEMENT},
		"el evento `found` sale al llegar, con el actor de quien la mandó y el `data` de siempre",
		"el evento `found` no sale como antes: %s" % [found_entry]
	)
	failures += TestUtil.check(
		is_equal_approx(Promotion.expedition_cycles(state, root, params),
			params.expedition_base * params.expedition_growth),
		"la segunda expedición tarda ×%.2f: %.0f ciclos" % [
			params.expedition_growth, Promotion.expedition_cycles(state, root, params),
		],
		"la segunda expedición no se alarga: %.0f ciclos" % Promotion.expedition_cycles(
			state, root, params)
	)
	return failures


## **🛤️ Carreteras acorta la siguiente expedición, no la que ya está en camino.** La duración se
## fija al salir: es una constante del segmento y no una tasa, así que comprarla a mitad de viaje
## no mueve la llegada. La siguiente tarda `base × growth^hijos × 0,75`.
func _roads_shorten_the_next_expedition() -> int:
	var engine := _ready_to_found(78)
	var state := engine.state
	var params := engine.params
	var root := state.root()
	var sent := Promotion.launch_expedition(state, root, params, null)
	if sent == null:
		return TestUtil.check(false, "", "un pueblo listo para fundar no lanza la expedición")
	var arrive_before := sent.arrive_cycle
	engine.tick(100.0)

	# Con la expedición en camino, se compra la mejora por la ruta del jugador, requisitos incluidos.
	root.stocks[Goods.STONE] = 2000.0
	root.stocks[Goods.TOOLS] = 500.0
	var bought := Upgrading.buy(root, "stone_tools", state.cycle, null) \
		and Upgrading.buy(root, "quarry_rails", state.cycle, null) \
		and Upgrading.buy(root, "roads", state.cycle, null)
	var failures := TestUtil.check(
		bought and sent.arrive_cycle == arrive_before
			and state.expedition_of(root.id) == sent,
		"con 🛤️ Carreteras comprada a mitad de viaje, la expedición sigue llegando en el %.0f"
			% arrive_before,
		"comprar Carreteras mueve la expedición en camino o no se compra: comprada %s, llegada %.1f → %.1f"
			% [bought, arrive_before, sent.arrive_cycle]
	)

	while state.cycle < arrive_before + 1.0:
		engine.tick(minf(700.0, arrive_before + 1.0 - state.cycle))
	# Se rellena el pueblo para que la segunda pueda salir: lo que se mide es el reloj, no la
	# economía del escenario.
	root.pop = 500.0
	root.stocks[Goods.FOOD] = 500.0
	state.refresh_totals()
	var expected := params.expedition_base * params.expedition_growth * 0.75
	var next := Promotion.launch_expedition(state, root, params, null)
	var took := next.arrive_cycle - next.depart_cycle if next != null else -1.0
	failures += TestUtil.check(
		root.children.size() == 1 and next != null and is_equal_approx(took, expected),
		"y la siguiente tarda base × %.1f × 0,75: %.0f ciclos" % [params.expedition_growth, took],
		"la siguiente expedición no se acorta: hijos %d, %.1f ciclos (se esperaban %.1f)" % [
			root.children.size(), took, expected,
		]
	)
	return failures


## Si el padre se despuebla con una expedición en camino, `_prune` la cancela: los colonos se
## pierden y no nace un hijo con un padre que ya no existe.
func _a_pruned_parent_loses_its_expedition() -> int:
	var engine := TestUtil.make_engine(77)
	var state := engine.state
	var root := state.root()
	root.tier = Content.CITY
	root.pop = 500.0
	root.stocks[Goods.FOOD] = 5000.0
	state.refresh_totals()
	var town := TestUtil.found_now(state, root, engine.params)
	town.tier = Content.TOWN
	town.pop = 100.0
	town.stocks[Goods.FOOD] = 500.0
	var sent := Promotion.launch_expedition(state, town, engine.params, null)
	town.pop = 0.0
	engine.tick(1.0)
	engine.tick(engine.params.expedition_base)
	var born := 0
	for id in state.ordered_ids():
		if (state.nodes[id] as SimNode).parent_id == town.id:
			born += 1
	return TestUtil.check(
		sent != null and not state.nodes.has(town.id) and state.expeditions.is_empty()
			and born == 0,
		"un padre podado con una expedición en camino la pierde, y no nace ningún huérfano",
		"podar con una expedición en camino: padre %s, %d expediciones, %d hijos sin padre" % [
			"vivo" if state.nodes.has(town.id) else "podado", state.expeditions.size(), born,
		]
	)


## La expedición se cuenta en el diario y en el informe de vuelta: `expedition` al salir, `found`
## al llegar y, si el jugador pulsó «🚩🎖️ Fundar y delegar», también la delegación —con su
## actor, aunque llegue en mitad de un tick—, que es lo que `Analytics` manda como `delegation`.
## Lo que funda un gobernador no la emite: nace delegado por herencia, no por decisión. Y la
## colonia que llega durante una ausencia sale en el informe de vuelta.
func _the_expedition_tells_its_story() -> int:
	var engine := _ready_to_found(78)
	engine.events.enabled = true
	var state := engine.state
	var params := engine.params
	var root := state.root()
	var sent := Promotion.launch_expedition(state, root, params, engine.events,
		Governor.balanced())
	if sent == null:
		return TestUtil.check(false, "", "un pueblo listo para fundar no lanza la expedición")
	var left := OfflineReport.span(params.expedition_base * params.seconds_per_cycle)
	var departed: Dictionary = engine.events.entries.back() if not engine.events.entries.is_empty() \
		else {}
	var failures := TestUtil.check(
		departed.get("category", "") == "expedition" and departed["node"] == root.id
			and departed["actor"] == "player"
			and departed["text"] == "%s envía colonos: llegan en %s" % [root.name, left],
		"al salir, el diario dice «%s»" % departed.get("text", ""),
		"el evento `expedition` no sale como se espera: %s" % [departed]
	)
	failures += TestUtil.check(
		Promotion.found_child_blocker(state, root, params) == "expedición en camino: llega en %s"
			% left,
		"en camino, el botón dice «%s»" % Promotion.found_child_blocker(state, root, params),
		"el motivo con la expedición en camino es «%s»" % Promotion.found_child_blocker(
			state, root, params)
	)

	# La llegada cae dentro de la ausencia, y el tick la conduce con otro actor.
	engine.events.actor = "system"
	engine.catch_up(params.expedition_base * 4.0 * params.seconds_per_cycle
		/ params.offline_efficiency)
	engine.events.actor = "player"
	var child: SimNode = state.nodes.get(root.children[0]) if root.children.size() == 1 else null
	var delegation := {}
	for entry in engine.events.entries:
		if entry["category"] == "governor":
			delegation = entry
	failures += TestUtil.check(
		child != null and child.is_delegated() and not delegation.is_empty()
			and delegation["node"] == child.id and delegation["actor"] == "player"
			and delegation["cycle"] == sent.arrive_cycle
			and delegation["data"] == {"delegated": true},
		"«Fundar y delegar» emite la delegación al llegar, con actor player: «%s»"
			% delegation.get("text", ""),
		"la delegación de «Fundar y delegar» no sale al llegar: hijo %s, evento %s" % [
			"ninguno" if child == null else child.name, delegation,
		]
	)
	var report := engine.last_offline
	failures += TestUtil.check(
		child != null and report != null
			and report.colonies_arrived == PackedStringArray([child.name])
			and "\n".join(report.lines()).contains(child.name),
		"el informe de vuelta cuenta la colonia que llegó: %s" % [
			report.colonies_arrived if report != null else []],
		"el informe de vuelta no cuenta la llegada: %s" % [
			report.colonies_arrived if report != null else "sin informe"]
	)

	# El gobernador funda delegado y no emite delegación: no la ha decidido nadie.
	var governed := _ready_to_found(79)
	governed.events.enabled = true
	governed.events.actor = "governor"
	var gsent := Promotion.launch_expedition(governed.state, governed.state.root(),
		governed.params, governed.events, Governor.balanced())
	governed.events.actor = "player"
	governed.tick(governed.params.expedition_base + 1.0)
	var categories := PackedStringArray()
	for entry in governed.events.entries:
		categories.append("%s/%s" % [entry["category"], entry["actor"]])
	failures += TestUtil.check(
		gsent != null and categories.has("expedition/governor")
			and categories.has("found/governor") and not categories.has("governor/governor")
			and not categories.has("governor/player"),
		"lo que funda un gobernador sale y llega con su actor, sin evento de delegación",
		"eventos de una fundación del gobernador: %s" % [categories]
	)
	return failures


## Un nodo de la escala `tier`, sin gobernador, con una expedición en camino y `gold` 🪙. El oro se
## pone a mano después de salir: lo que se mide es la cuenta del precio, no la economía.
func _with_expedition(seed_value: int, tier: int, gold: float) -> SimEngine:
	var engine := TestUtil.make_engine(seed_value)
	var root := engine.state.root()
	root.tier = tier
	root.pop = 500.0
	root.stocks[Goods.FOOD] = 500.0
	engine.state.refresh_totals()
	Promotion.launch_expedition(engine.state, root, engine.params, null)
	engine.tick(1000.0)
	root.stocks[Goods.GOLD] = gold
	return engine


## **La segunda aceleración cuesta ×1,5 la primera** con el mismo viaje por delante: el precio
## crece por las aceleraciones hechas, no por el reloj. Se compara contra la fórmula de la primera
## aplicada a lo que queda tras ella (el 75 %), así que el ×1,5 es lo único que puede sobrar. Y se
## cobra lo que se anunció, ni más ni menos.
func _the_second_acceleration_costs_more() -> int:
	var engine := _with_expedition(9191, Content.CITY, 1.0e9)
	var state := engine.state
	var params := engine.params
	var root := state.root()
	var e := state.expedition_of(root.id)
	var left := e.arrive_cycle - state.cycle
	var first := Promotion.accelerate_cost(state, root, params)
	var gold := root.stocks[Goods.GOLD]
	var ok := Promotion.accelerate_expedition(state, root, params, engine.events)
	var paid := gold - root.stocks[Goods.GOLD]
	var second := Promotion.accelerate_cost(state, root, params)
	# Lo que costaría la segunda si no encareciera: la fórmula de la primera, con lo que queda ya.
	var flat := params.accelerate_gold_per_cycle * (e.arrive_cycle - state.cycle) \
		* params.accelerate_fraction
	var failures := TestUtil.check(
		ok and is_equal_approx(first, 120.0 * left * 0.25) and is_equal_approx(paid, first)
			and is_equal_approx(e.arrive_cycle - state.cycle, left * 0.75)
			and e.accelerations == 1,
		"⏩ la primera aceleración cuesta k × 25 %% de lo que queda = %.0f 🪙, y recorta %.0f ciclos" % [
			first, left * 0.25,
		],
		"⏩ la primera aceleración no cobra o no recorta lo previsto: ok %s, %.2f (pagado %.2f), quedan %.2f de %.2f" % [
			ok, first, paid, e.arrive_cycle - state.cycle, left,
		]
	)
	failures += TestUtil.check(
		is_equal_approx(second, flat * 1.5)
			and Promotion.accelerate_expedition(state, root, params, engine.events)
			and e.accelerations == 2,
		"⏩ la segunda cuesta ×1,5 lo que costaría sin encarecer: %.0f = %.0f × 1,5" % [second, flat],
		"⏩ la segunda cuesta %.2f, no %.2f × 1,5" % [second, flat]
	)
	return failures


## **Sin oro, `accelerate_blocker` lo dice —con cuánto falta— y no se acelera**: ni se cobra ni se
## mueve la llegada. Con un 🪙 menos de lo justo, para que el «faltan» sea exacto.
func _no_gold_no_acceleration() -> int:
	var engine := _with_expedition(9292, Content.CITY, 0.0)
	var state := engine.state
	var params := engine.params
	var root := state.root()
	var cost := Promotion.accelerate_cost(state, root, params)
	root.stocks[Goods.GOLD] = cost - 1.0
	var e := state.expedition_of(root.id)
	var arrive := e.arrive_cycle
	var blocker := Promotion.accelerate_blocker(state, root, params)
	var expected := "faltan %.0f 🪙" % ceilf(1.0)
	var ok := Promotion.accelerate_expedition(state, root, params, engine.events)
	var failures := TestUtil.check(
		blocker == expected and not ok and e.arrive_cycle == arrive and e.accelerations == 0
			and root.stocks[Goods.GOLD] == cost - 1.0,
		"⏩ sin oro bastante no se acelera, y el botón dice «%s»" % blocker,
		"⏩ sin oro: blocker «%s» (se esperaba «%s»), acelerada %s, llegada %.2f → %.2f" % [
			blocker, expected, ok, arrive, e.arrive_cycle,
		]
	)
	# Y sin expedición no hay nada que acelerar, haya el oro que haya.
	var idle := TestUtil.make_engine(9393)
	idle.state.root().tier = Content.CITY
	idle.state.root().stocks[Goods.GOLD] = 1.0e9
	failures += TestUtil.check(
		Promotion.accelerate_blocker(idle.state, idle.state.root(), idle.params)
			== "no hay ninguna expedición en camino"
			and not Promotion.accelerate_expedition(idle.state, idle.state.root(), idle.params, null),
		"⏩ sin expedición en camino tampoco se acelera",
		"⏩ se acelera sin expedición, o el motivo no lo dice"
	)
	return failures


## **Un pueblo no puede acelerar**, aunque tenga oro de sobra: es el sumidero del oro de una ciudad.
func _a_town_cannot_accelerate() -> int:
	var engine := _with_expedition(9494, Content.TOWN, 1.0e9)
	var state := engine.state
	var root := state.root()
	var e := state.expedition_of(root.id)
	var arrive := e.arrive_cycle
	var blocker := Promotion.accelerate_blocker(state, root, engine.params)
	return TestUtil.check(
		blocker == "solo una ciudad tiene oro para esto"
			and not Promotion.accelerate_expedition(state, root, engine.params, engine.events)
			and e.arrive_cycle == arrive and root.stocks[Goods.GOLD] == 1.0e9,
		"⏩ un pueblo no acelera ni con oro de sobra: «%s»" % blocker,
		"⏩ un pueblo acelera, o el motivo es «%s»" % blocker
	)
