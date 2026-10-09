extends SceneTree
## Prestigio y árbol de legado. Ejecutar con:
##   godot-4 --headless --path . -s res://tools/legacy_test.gd
##
## El legado es lo único del juego que sobrevive a una partida, y ascender es la única acción
## que **destruye** el mundo en marcha. Las dos cosas juntas hacen que un fallo aquí no se note
## hasta que ya no hay nada que recuperar: si `ascend` pierde un nodo comprado o `adopt` deja un
## estado a medias, el jugador se entera cuando ya ha tirado su asentamiento.

const TestUtil := preload("res://tools/TestUtil.gd")


func _init() -> void:
	var failures := 0
	failures += _the_reward_has_a_floor()
	failures += _culture_adds_legacy_above_the_floor()
	failures += _culture_adds_nothing_below_the_floor()
	failures += _the_tree_gates_by_requirement()
	failures += _ranks_and_costs()
	failures += _old_roads_shorten_the_next_expedition()
	failures += _ascending_keeps_the_legacy()
	failures += _items_survive_ascension()
	failures += _council_grants_seals_each_era()
	failures += _council_purchase_grants_seal()
	failures += _stewards_needs_council()
	failures += _the_new_era_is_playable()
	failures += _the_second_era_is_faster()
	TestUtil.finish(self, failures)


## Ascender el primer día no puede dar nada. Sin suelo, el prestigio se convierte en un botón
## que se pulsa a ciegas cada dos minutos y deja de significar nada.
func _the_reward_has_a_floor() -> int:
	var engine := TestUtil.make_engine(900)
	var state := engine.state

	state.peak_pop = Ascension.MIN_PEAK_POP - 1.0
	state.peak_tier = 0
	var failures := TestUtil.check(
		Ascension.reward(state) == 0.0 and not Ascension.can_ascend(state),
		"por debajo de %.0f de cúspide, ascender no da nada" % Ascension.MIN_PEAK_POP,
		"se puede ascender con una cúspide de %.0f" % state.peak_pop
	)

	state.peak_pop = 4000.0
	var at_settlement := Ascension.reward(state)
	state.peak_tier = 2
	var at_city := Ascension.reward(state)
	failures += TestUtil.check(
		at_settlement >= 1.0 and at_city > at_settlement,
		"la misma cúspide rinde más cuanto más alta es la escala alcanzada: %.0f → %.0f" % [
			at_settlement, at_city,
		],
		"la escala alcanzada no cambia la recompensa: %.0f → %.0f" % [at_settlement, at_city]
	)
	return failures


## La cultura suma legado por encima del suelo: ⌊√(Σ 📜 del árbol / CULTURE_PER_LEGACY)⌋, aparte
## de la población y sin multiplicarla. Se reparte entre la raíz y un hijo para comprobar que
## cuenta el árbol entero, como la influencia, y no solo la raíz.
func _culture_adds_legacy_above_the_floor() -> int:
	var engine := TestUtil.make_engine(907)
	var state := engine.state
	var root := state.root()
	root.tier = Content.CITY
	root.pop = 5000.0
	root.stocks[Goods.FOOD] = 1.0e4
	state.refresh_totals()
	var child := TestUtil.found_now(state, root, engine.params)
	if child == null:
		return TestUtil.check(false, "", "la ciudad no ha podido fundar un pueblo")
	state.peak_pop = 4000.0
	state.peak_tier = 2
	root.stocks[Goods.CULTURE] = 0.0
	child.stocks[Goods.CULTURE] = 0.0
	var without := Ascension.reward(state)

	# 30 × 30 × 1.000 = 900.000 📜 → 30 de legado, la mitad en el hijo.
	var culture := 30.0 * 30.0 * Ascension.CULTURE_PER_LEGACY
	root.stocks[Goods.CULTURE] = culture * 0.5
	child.stocks[Goods.CULTURE] = culture * 0.5
	var with_culture := Ascension.reward(state)
	var failures := TestUtil.check(
		Ascension.culture_reward(state) == 30.0 and with_culture == without + 30.0
			and Ascension.pop_reward(state) == without,
		"la cultura del árbol suma aparte: %.0f por población + %.0f por cultura = %.0f" % [
			without, Ascension.culture_reward(state), with_culture,
		],
		"la cultura no suma ⌊√(📜/%.0f)⌋ al legado: %.0f sin cultura, %.0f con %.0f 📜 (%.0f por cultura)" % [
			Ascension.CULTURE_PER_LEGACY, without, with_culture, culture, Ascension.culture_reward(state),
		]
	)

	# Un punto menos de la frontera no llega al 30: es un suelo (⌊⌋), no un redondeo.
	child.stocks[Goods.CULTURE] -= 1.0
	failures += TestUtil.check(
		Ascension.culture_reward(state) == 29.0,
		"y es ⌊⌋: con 1 📜 menos de 900.000 da 29",
		"con 899.999 📜 la cultura da %.0f, no 29" % Ascension.culture_reward(state)
	)

	# Y lo que cobra `ascend` es lo mismo que promete `reward`, leído antes del mundo nuevo.
	var expected := Ascension.reward(state)
	var fresh := Ascension.ascend(state, engine.params, null)
	failures += TestUtil.check(
		absf(fresh.legacy - (state.legacy + expected)) < 0.001,
		"ascender cobra la cultura del mundo que se deja: +%.0f" % expected,
		"ascender ha cobrado %.0f, no los %.0f prometidos" % [fresh.legacy - state.legacy, expected]
	)
	return failures


## Por debajo del suelo, 0 aunque haya cultura: el suelo es de población pico, y un templo el
## primer día no puede abrir la puerta del prestigio.
func _culture_adds_nothing_below_the_floor() -> int:
	var engine := TestUtil.make_engine(908)
	var state := engine.state
	state.peak_pop = Ascension.MIN_PEAK_POP - 1.0
	state.peak_tier = 2
	state.root().stocks[Goods.CULTURE] = 1.0e9
	return TestUtil.check(
		Ascension.culture_reward(state) > 0.0 and Ascension.reward(state) == 0.0
			and not Ascension.can_ascend(state),
		"bajo %.0f de cúspide, 0 de legado aunque haya %.0f 📜 (que darían %.0f)" % [
			Ascension.MIN_PEAK_POP, state.root().stocks[Goods.CULTURE], Ascension.culture_reward(state),
		],
		"la cultura salta el suelo: legado %.0f con cúspide %.0f" % [
			Ascension.reward(state), state.peak_pop,
		]
	)


## El árbol de legado **es un árbol**: no se compra una rama sin haber empezado por su raíz,
## aunque sobre moneda. Plano, el legado se iba en lo primero que pillabas.
func _the_tree_gates_by_requirement() -> int:
	var engine := TestUtil.make_engine(901)
	var state := engine.state
	state.legacy = 1000.0

	var failures := TestUtil.check(
		not Ascension.can_buy(state, "night_watch")
			and not Ascension.buy(state, "night_watch", null),
		"«Guardia nocturna» no se compra sin «Crónica», por mucho legado que sobre",
		"se ha comprado un nodo de legado sin su requisito"
	)
	failures += TestUtil.check(
		Ascension.can_buy(state, "chronicle") and Ascension.buy(state, "chronicle", null),
		"«Crónica» sí, que es raíz de su rama",
		"no se puede comprar una raíz del árbol de legado con legado de sobra"
	)
	failures += TestUtil.check(
		Ascension.can_buy(state, "night_watch"),
		"y comprarla desbloquea a su hija",
		"comprar la raíz no desbloquea a su hija"
	)

	# Un save anterior a las ramas puede traer una hija sin su madre. Los bonos se le siguen
	# aplicando: esto solo gobierna las compras futuras, así que no hace falta migrar nada.
	var orphan := WorldState.create(902, engine.params)
	orphan.legacy_nodes = PackedStringArray(["night_watch", "night_watch"])
	failures += TestUtil.check(
		Ascension.bonuses(orphan).offline_rate > 0.19,
		"un nodo huérfano de un save viejo sigue dando su bono",
		"un save anterior a las ramas pierde sus bonos"
	)
	return failures


## Los rangos se acaban y el coste crece. Es lo que impide que un solo nodo se lleve todo el
## legado de todas las eras.
func _ranks_and_costs() -> int:
	var engine := TestUtil.make_engine(903)
	var state := engine.state
	var def: Legacy.Node_ = Legacy.get_node_def("fertile_soil")
	state.legacy = 100000.0

	var failures := TestUtil.check(
		def.cost_for(1) > def.cost_for(0) and def.cost_for(2) > def.cost_for(1),
		"cada rango cuesta más que el anterior: %.1f → %.1f → %.1f" % [
			def.cost_for(0), def.cost_for(1), def.cost_for(2),
		],
		"el coste de los rangos no crece"
	)

	var spent := state.legacy
	for i in def.max_ranks:
		Ascension.buy(state, "fertile_soil", null)
	failures += TestUtil.check(
		Ascension.rank_of(state, "fertile_soil") == def.max_ranks
			and not Ascension.can_buy(state, "fertile_soil"),
		"se llega al tope de %d rangos y ahí se acaba" % def.max_ranks,
		"el tope de rangos no frena: %d comprados" % Ascension.rank_of(state, "fertile_soil")
	)
	var expected := 0.0
	for i in def.max_ranks:
		expected += def.cost_for(i)
	failures += TestUtil.check(
		absf((spent - state.legacy) - expected) < 0.001,
		"y ha costado exactamente la suma de sus rangos: %.1f" % expected,
		"lo cobrado no cuadra: %.1f contra %.1f" % [spent - state.legacy, expected]
	)
	return failures


## **🧭 Caminos antiguos acorta la siguiente expedición, no la que ya está en camino.** El legado
## se compra con una expedición a medio viaje: su llegada no se mueve, y la siguiente tarda
## `base × growth^hijos × (1 − 0,08 × rangos)`.
func _old_roads_shorten_the_next_expedition() -> int:
	var engine := TestUtil.make_engine(907)
	var state := engine.state
	var params := engine.params
	var root := state.root()
	root.tier = Content.TOWN
	root.pop = 500.0
	root.stocks[Goods.FOOD] = 500.0
	state.refresh_totals()
	state.legacy = 100.0

	var sent := Promotion.launch_expedition(state, root, params, null)
	if sent == null:
		return TestUtil.check(false, "", "un pueblo listo para fundar no lanza la expedición")
	var arrive_before := sent.arrive_cycle
	engine.tick(100.0)

	# Cuelga de «Tierra fértil»: sin ella no se compra.
	var gated := not Ascension.can_buy(state, "old_roads")
	var fertile_paid := state.legacy
	var bought := Ascension.buy(state, "fertile_soil", null)
	var roads_paid := state.legacy
	bought = bought and Ascension.buy(state, "old_roads", null) \
		and Ascension.buy(state, "old_roads", null)
	roads_paid -= state.legacy
	fertile_paid -= roads_paid + state.legacy
	var failures := TestUtil.check(
		gated and bought and Ascension.rank_of(state, "old_roads") == 2
			and sent.arrive_cycle == arrive_before,
		"dos rangos de 🧭 Caminos antiguos a mitad de viaje no mueven la llegada (%.0f)"
			% arrive_before,
		"Caminos antiguos no se compra como debe o mueve la expedición en camino: sin requisito %s, comprado %s, llegada %.1f → %.1f"
			% [not gated, bought, arrive_before, sent.arrive_cycle]
	)
	# El coste es la palanca de M4 de «Plan - Balance de la era»: 2 y ×1,6, para que el legado de
	# una ascensión en Ciudad dé para varios rangos (ver el comentario en `Legacy.gd`). Los dos
	# primeros rangos son 2 + 3,2.
	failures += TestUtil.check(
		is_equal_approx(fertile_paid, 2.0) and is_equal_approx(roads_paid, 5.2),
		"y sus dos primeros rangos cuestan 2 + 3,2 = %.1f de legado" % roads_paid,
		"Caminos antiguos no cuesta 2 · 3,2: %.2f por los dos rangos (Tierra fértil %.2f)"
			% [roads_paid, fertile_paid]
	)

	while state.cycle < arrive_before + 1.0:
		engine.tick(minf(700.0, arrive_before + 1.0 - state.cycle))
	# Se rellena el pueblo para que la segunda pueda salir: se mide el reloj, no la economía.
	root.pop = 500.0
	root.stocks[Goods.FOOD] = 500.0
	state.refresh_totals()
	var expected := params.expedition_base * params.expedition_growth * (1.0 - 0.08 * 2.0)
	var next := Promotion.launch_expedition(state, root, params, null)
	var took := next.arrive_cycle - next.depart_cycle if next != null else -1.0
	failures += TestUtil.check(
		root.children.size() == 1 and next != null and is_equal_approx(took, expected),
		"y la siguiente tarda base × %.1f × 0,84: %.0f ciclos" % [params.expedition_growth, took],
		"la siguiente expedición no se acorta: hijos %d, %.1f ciclos (se esperaban %.1f)" % [
			root.children.size(), took, expected,
		]
	)
	return failures


## Ascender conserva lo único que se conserva.
func _ascending_keeps_the_legacy() -> int:
	var engine := TestUtil.make_engine(904)
	var state := engine.state
	state.peak_pop = 9000.0
	state.peak_tier = 1
	state.legacy = 7.0
	state.legacy_nodes = PackedStringArray(["chronicle", "night_watch", "first_stones"])
	var gained := Ascension.reward(state)

	var fresh := Ascension.ascend(state, engine.params, null)
	var failures := TestUtil.check(
		fresh != state,
		"ascender devuelve un mundo nuevo, no vacía el que hay",
		"ascender ha devuelto el mismo estado"
	)
	failures += TestUtil.check(
		absf(fresh.legacy - (7.0 + gained)) < 0.001
			and Array(fresh.legacy_nodes) == Array(state.legacy_nodes),
		"con el legado cobrado (%.0f + %.0f) y el árbol intacto" % [7.0, gained],
		"el legado no ha sobrevivido: %.1f y %s" % [fresh.legacy, str(fresh.legacy_nodes)]
	)
	failures += TestUtil.check(
		fresh.era == state.era + 1,
		"y la era sube a %d" % fresh.era,
		"la era no ha subido: %d → %d" % [state.era, fresh.era]
	)

	# «Primeras piedras» es lo que hace que la era nueva no empiece de cero pelado.
	var barren := WorldState.create(905, engine.params)
	failures += TestUtil.check(
		fresh.root().stocks[Goods.FOOD] > barren.root().stocks[Goods.FOOD]
			and fresh.root().stocks[Goods.WOOD] > barren.root().stocks[Goods.WOOD],
		"«Primeras piedras» surte de provisiones al mundo nuevo",
		"la era nueva arranca sin las provisiones del legado"
	)
	return failures


## **El inventario sobrevive a la ascensión; los ⚡ boosts no** (Objetos de tiempo, M2). Los objetos
## se han comprado y viven en el estado; el boost vive en un nodo, y los nodos mueren con la era. El
## goteo se rebasa al reloj nuevo conservando lo recorrido: ni se pierde ni bloquea la era nueva.
func _items_survive_ascension() -> int:
	var engine := TestUtil.make_engine(907)
	var state := engine.state
	engine.tick(500.0)
	SimEngine.apply_boost(state, state.root(), 4.0, 600.0)
	engine.tick(50.0)
	state.peak_pop = 9000.0
	state.peak_tier = 1
	state.items = {"skip_1h": 2, "boost_x2": 1, "seal": 1}
	state.drip_cycle = state.cycle - 1234.0
	state.drip_held = 1
	var fresh := Ascension.ascend(state, engine.params, null)
	var same := true
	for def in Items.all():
		if int(fresh.items.get(def.id, 0)) != int(state.items.get(def.id, 0)):
			same = false
	var root := fresh.root()
	var failures := TestUtil.check(
		fresh != state and same and fresh.drip_held == 1,
		"el inventario sobrevive a la ascensión: %s, %d del goteo" % [fresh.items, fresh.drip_held],
		"la ascensión pierde objetos: %s → %s, goteo %d" % [state.items, fresh.items, fresh.drip_held]
	)
	failures += TestUtil.check(
		fresh.cycle - fresh.drip_cycle == 1234.0,
		"y el goteo sigue a %.0f ciclos del último ⌛, rebasado al reloj nuevo" % (fresh.cycle - fresh.drip_cycle),
		"el goteo no se rebasa: %.1f en el ciclo %.1f" % [fresh.drip_cycle, fresh.cycle]
	)
	failures += TestUtil.check(
		root.boost_factor == 1.0 and root.local_cycle == fresh.cycle and fresh.min_boost_until == INF,
		"y el ⚡ ×4 de la raíz muere con la era",
		"un ⚡ cruza la ascensión: ×%.0f hasta %.1f" % [root.boost_factor, root.boost_until]
	)
	# Copia, no referencia: gastar en la era nueva no puede tocar el estado viejo.
	fresh.items["seal"] = 0
	failures += TestUtil.check(
		int(state.items["seal"]) == 1,
		"y es una copia: gastar en la era nueva no toca la vieja",
		"la era nueva comparte el inventario con la vieja"
	)
	return failures


## **🎖️ Consejo regala un sello por rango al empezar cada era**, y se suma a los que sobraron:
## el oro para comprarlos solo llega en Ciudad, y sin el regalo la llave no abriría nada.
func _council_grants_seals_each_era() -> int:
	var engine := TestUtil.make_engine(908)
	var state := engine.state
	state.peak_pop = 9000.0
	state.peak_tier = 1
	var closed := not Ascension.governor_open(state)
	state.legacy_nodes = PackedStringArray(["council", "council"])
	var fresh := Ascension.ascend(state, engine.params, null)
	var failures := TestUtil.check(
		closed and Ascension.governor_open(fresh) and Ascension.bonuses(fresh).seals == 2
			and int(fresh.items.get("seal", 0)) == 2,
		"Consejo 2 abre los gobernadores y la era nueva empieza con 2 🎖️",
		"Consejo no abre o no regala: abierto antes %s, %s en la era nueva" % [
			not closed, fresh.items,
		]
	)
	# Lo que sobra no se vacía: la era siguiente suma su regalo encima.
	fresh.peak_pop = 9000.0
	fresh.peak_tier = 1
	var third := Ascension.ascend(fresh, engine.params, null)
	failures += TestUtil.check(
		int(third.items.get("seal", 0)) == 4,
		"y los que sobran se quedan: 2 + 2 = %d 🎖️ en la era 3" % int(third.items.get("seal", 0)),
		"los sellos sobrantes no se suman al regalo: %s" % third.items
	)
	return failures


## **🎖️ Consejo da su sello en el acto, uno por rango comprado** (M3 de «Plan - Gobernador por
## sello»). Comprado a mitad de era, sin él no habría nada que sellar hasta la ascensión siguiente.
func _council_purchase_grants_seal() -> int:
	var engine := TestUtil.make_engine(910)
	var state := engine.state
	state.legacy = 1000.0
	var before := Shop.count_of(state, "seal")
	var first := Ascension.buy(state, "council", null)
	var after_one := Shop.count_of(state, "seal")
	var failures := TestUtil.check(
		first and before == 0 and after_one == 1 and Ascension.governor_open(state),
		"comprar Consejo 1 da 1 🎖️ en el acto y abre los gobernadores",
		"Consejo 1 no da su sello: %d → %d 🎖️ (comprado %s)" % [before, after_one, first]
	)
	var second := Ascension.buy(state, "council", null)
	failures += TestUtil.check(
		second and Shop.count_of(state, "seal") == 2,
		"y el rango 2 da otro: %d 🎖️" % Shop.count_of(state, "seal"),
		"Consejo 2 no da su sello: %d 🎖️ (comprado %s)" % [Shop.count_of(state, "seal"), second]
	)
	# Otro nodo del árbol no regala nada.
	Ascension.buy(state, "fertile_soil", null)
	failures += TestUtil.check(
		Shop.count_of(state, "seal") == 2,
		"y otro nodo de legado no da sellos",
		"comprar otro nodo de legado da sellos: %d 🎖️" % Shop.count_of(state, "seal")
	)
	return failures


## **🎓 Escuela de gobernadores cuelga de 🎖️ Consejo**, y con ella 👑 Dinastía: no tiene sentido
## mejorar algo que todavía no tienes.
func _stewards_needs_council() -> int:
	var engine := TestUtil.make_engine(909)
	var state := engine.state
	state.legacy = 1000.0
	Ascension.buy(state, "fertile_soil", null)
	Ascension.buy(state, "old_crafts", null)
	var failures := TestUtil.check(
		not Ascension.can_buy(state, "stewards") and not Ascension.buy(state, "stewards", null),
		"sin Consejo no hay Escuela, aunque haya Oficios antiguos y legado de sobra",
		"se ha comprado la Escuela sin Consejo"
	)
	failures += TestUtil.check(
		Ascension.can_buy(state, "council") and Ascension.buy(state, "council", null)
			and Ascension.can_buy(state, "stewards"),
		"Consejo es raíz, y comprarlo abre la Escuela",
		"Consejo no se compra como raíz o no abre la Escuela"
	)
	return failures


## El mundo nuevo entra por el mismo camino que una partida cargada, y corre.
##
## Es el punto donde el prestigio se puede quedar a medias sin que ningún otro test lo note: el
## estado es nuevo, pero el reloj, el acumulador y el nodo enfocado son los de antes.
func _the_new_era_is_playable() -> int:
	var engine := TestUtil.make_engine(906)
	engine.state.peak_pop = 5000.0
	engine.state.peak_tier = 1

	var fresh := Ascension.ascend(engine.state, engine.params, null)
	engine.adopt(fresh)
	engine.tick(300.0)

	var root := engine.state.root()
	return TestUtil.check(
		root != null and engine.state.cycle >= 300.0 and root.pop > 0.0,
		"tras adoptar el mundo nuevo, 300 ciclos corren y queda gente viva: %.1f hab" % root.pop,
		"la era nueva no es jugable: ciclo %.1f" % engine.state.cycle
	)


## **La era 2 se nota.** Un árbol de legado que no acelera es decorativo: ascender al llegar a
## Ciudad (H3c, la era completa) tiene que dejar una era nueva que llegue a Pueblo (H6) y a
## Ciudad (H7c) claramente antes que la primera (H1, H3c).
##
## Mide exactamente como `era_probe -- --until=h3`: raíz delegada en un gobernador equilibrado,
## paso 25 con `TestUtil.cycles_until`, se asciende al llegar a Ciudad, el mundo nuevo entra por
## `adopt` y el legado se gasta con `TestUtil.spend_legacy`, la misma política que la sonda.
## Ascender resiembra con `seed + era`, así que se comparan las **medianas** sobre las semillas,
## no semilla a semilla.
func _the_second_era_is_faster() -> int:
	# Lo que dejó «Plan - Balance de la era» (`era_probe`, paso 25, igual en las 4 semillas):
	# ascender en Ciudad rinde 28 de legado, y `spend_legacy` compra tres rangos de 🧭 Caminos
	# antiguos (−24 % a cada expedición). H6/H1 = 625/725 = 0,86: hasta Pueblo no hay
	# expediciones, solo acelera el resto del árbol, y por eso basta con 0,95. H7c/H3c =
	# 12.275/15.975 = 0,77: Ciudad la marca el reloj de los cuatro hijos, y Caminos antiguos lo
	# acorta. El umbral es el objetivo del plan, 0,8, con poco margen a propósito: si un ajuste
	# lo saca, es que la era 2 ha dejado de notarse donde más se espera.
	const H6_OVER_H1 := 0.95
	const H7C_OVER_H3C := 0.8
	# El techo de tolerancia de Ciudad en la sonda, para las dos eras.
	const CEILING := 32400.0
	const STEP := 25.0

	var era1 := {"H1": [], "H3c": []}
	var era2 := {"H6": [], "H7c": []}
	for seed_value in [11, 222, 3333, 44444]:
		var engine := TestUtil.make_engine(seed_value)
		var state := engine.state
		var root := state.root()
		GovernorSys.delegate(state, root, Governor.balanced())
		var at := {"H1": -1.0, "H3c": -1.0, "fresh": null}
		var first := func() -> bool:
			if at["H1"] < 0.0 and (root.tier >= Content.TOWN or Promotion.can_promote(state, root)):
				at["H1"] = state.cycle
			if at["H3c"] < 0.0 and root.tier >= Content.CITY:
				at["H3c"] = state.cycle
				at["fresh"] = Ascension.ascend(state, engine.params, null)
			return at["fresh"] != null
		TestUtil.cycles_until(engine, first, CEILING, STEP)
		era1["H1"].append(at["H1"])
		era1["H3c"].append(at["H3c"])
		var fresh: WorldState = at["fresh"]
		if fresh == null or fresh.era < 2:
			return TestUtil.check(false, "",
				"la semilla %d no llega a Ciudad antes del ciclo %.0f: no hay era 2 que medir" % [
					seed_value, CEILING,
				])

		var next := TestUtil.make_engine(seed_value)
		next.adopt(fresh)
		var state2 := next.state
		var root2 := state2.root()
		TestUtil.spend_legacy(state2)
		GovernorSys.delegate(state2, root2, Governor.balanced())
		var at2 := {"H6": -1.0, "H7c": -1.0}
		var second := func() -> bool:
			if at2["H6"] < 0.0 and (
				root2.tier >= Content.TOWN or Promotion.can_promote(state2, root2)
			):
				at2["H6"] = state2.cycle
			if at2["H7c"] < 0.0 and root2.tier >= Content.CITY:
				at2["H7c"] = state2.cycle
			return at2["H6"] >= 0.0 and at2["H7c"] >= 0.0
		TestUtil.cycles_until(next, second, CEILING, STEP)
		era2["H6"].append(at2["H6"])
		era2["H7c"].append(at2["H7c"])

	for values: Array in [era1["H1"], era1["H3c"], era2["H6"], era2["H7c"]]:
		if values.has(-1.0):
			return TestUtil.check(false, "",
				"algún hito no llega antes del ciclo %.0f: H1 %s · H3c %s · H6 %s · H7c %s" % [
					CEILING, era1["H1"], era1["H3c"], era2["H6"], era2["H7c"],
				])
	var town := _median(era2["H6"]) / _median(era1["H1"])
	var city := _median(era2["H7c"]) / _median(era1["H3c"])
	var failures := TestUtil.check(
		town <= H6_OVER_H1,
		"la era 2 llega a Pueblo en el %.0f de mediana, %.2f veces H1 (%.0f; tope %.2f)" % [
			_median(era2["H6"]), town, _median(era1["H1"]), H6_OVER_H1,
		],
		"la era 2 no acelera lo bastante hasta Pueblo: H6/H1 = %.0f/%.0f = %.2f > %.2f" % [
			_median(era2["H6"]), _median(era1["H1"]), town, H6_OVER_H1,
		]
	)
	failures += TestUtil.check(
		city <= H7C_OVER_H3C,
		"y a Ciudad en el %.0f, %.2f veces H3c (%.0f; tope %.2f)" % [
			_median(era2["H7c"]), city, _median(era1["H3c"]), H7C_OVER_H3C,
		],
		"la era 2 no acelera lo bastante hasta Ciudad: H7c/H3c = %.0f/%.0f = %.2f > %.2f" % [
			_median(era2["H7c"]), _median(era1["H3c"]), city, H7C_OVER_H3C,
		]
	)
	return failures


static func _median(values: Array) -> float:
	var sorted_values := values.duplicate()
	sorted_values.sort()
	var n := sorted_values.size()
	if n % 2 == 1:
		return sorted_values[n / 2]
	return (sorted_values[n / 2 - 1] + sorted_values[n / 2]) / 2.0
