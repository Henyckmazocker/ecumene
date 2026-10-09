extends SceneTree
## El test que sostiene la arquitectura. Ejecutar con:
##   godot-4 --headless --path . -s res://tools/offline_test.gd
##
## Si esto se pone en rojo, el progreso offline y el tick del juego han dejado de ser el
## mismo código y hay que arreglarlo antes que ninguna otra cosa.

const TestUtil := preload("res://tools/TestUtil.gd")

## El integrador es exacto en aritmética real; en coma flotante, trocear 20.000 ciclos en
## pasos de 1 acumula error de redondeo frente a resolverlos de un salto. Esta es la
## discrepancia máxima que se acepta.
const TOLERANCE := 1.0e-6


func _init() -> void:
	var failures := 0

	failures += _compare(200, "corto")
	failures += _compare(5000, "medio")
	failures += _compare(20000, "largo")
	failures += _segment_count()
	failures += _cap_and_efficiency()
	failures += _delegated_grows_while_away()
	failures += _the_return_is_reported()
	failures += _upgrades_do_not_break_the_closed_form()
	# Rutas (M1): saltos de un checkpoint frente a ciclo a ciclo, y que no creen ni tiren nada.
	failures += _route_jumps_match_steps("ruta de comida", TestUtil.make_routed_engine.bind(4242))
	failures += _route_jumps_match_steps("ruta que vacía el origen",
		_wood_route.bind(5.0, 0.0))
	failures += _route_conserves("el origen se vacía", 5.0, 0.0, 5.0)
	failures += _route_conserves("el destino se llena", 100.0, -3.0, 3.0)
	failures += _pruned_node_drops_its_routes()
	# Región (M2): la comida importada sube el `K` del destino con tope, y cortar la ruta lo
	# devuelve a su `K` propio sin extinguirlo, también de un salto largo.
	failures += _imported_food_raises_k()
	failures += _cut_route_falls_to_own_k()
	# Expediciones (M1): el hijo nace a mitad del tramo y crece lo mismo de 1 en 1 que de un salto.
	failures += _expedition_jumps_match_steps("llegada en ciclo entero", 0.0)
	failures += _expedition_jumps_match_steps("llegada a mitad de ciclo", 0.3)
	# ⏩ Acelerar con oro (M3 del sumidero): adelantar la llegada no rompe N×1 == N, y lo que el
	# recorte deja en el pasado llega en el siguiente tick.
	failures += _accelerated_jumps_match_steps()
	failures += _accelerated_to_now_arrives_next_tick()
	# ⚡ Boost por nodo (M0 de Objetos de tiempo): el nodo dilata su tramo y su ruta va a `1/k`, así
	# que N×1 == N sigue en pie, la ruta no crea ni tira nada y la expedición llega igual.
	failures += _boost_n_by_1_equals_jump()
	failures += _boost_route_conserves()
	failures += _boost_expedition_n_by_1()
	# ⌛ Goteo (M4 de Objetos de tiempo): mira `state.cycle`, así que online y offline gotean igual.
	failures += _drip_online_offline_equal()

	TestUtil.finish(self, failures)


## Avanzar N veces 1 ciclo tiene que dar lo mismo que avanzar N ciclos de un salto.
func _compare(cycles: int, label: String) -> int:
	var stepwise := TestUtil.make_engine(4242)
	var jump := TestUtil.make_engine(4242)

	for _i in cycles:
		stepwise.tick(1.0)
	jump.tick(float(cycles))

	var a := stepwise.state.root()
	var b := jump.state.root()
	var worst := TestUtil.rel_error(a.pop, b.pop)
	var worst_name := "población"
	for i in Goods.COUNT:
		var err := TestUtil.rel_error(a.stocks[i], b.stocks[i])
		if err > worst:
			worst = err
			worst_name = Goods.NAMES[i]

	return TestUtil.check(
		worst <= TOLERANCE,
		"offline == online (%s, %d ciclos): error máx. %s en %s · pob %.4f" % [
			label, cycles, TestUtil.sci(worst), worst_name, b.pop,
		],
		"offline != online (%s, %d ciclos): error %s en %s (pob %.6f vs %.6f)" % [
			label, cycles, TestUtil.sci(worst), worst_name, a.pop, b.pop,
		]
	)


## El coste tiene que ir con el número de eventos, no con el tiempo simulado: resolver un
## día entero no puede costar más segmentos que resolver una hora.
func _segment_count() -> int:
	var engine := TestUtil.make_engine(4242)
	var node := engine.state.root()
	var mods := Integrator.Modifiers.none()
	var segments := Integrator.advance(node, engine.params, 86400.0, mods)
	return TestUtil.check(
		segments < 32,
		"coste acotado: 86.400 ciclos resueltos en %d segmentos" % segments,
		"demasiados segmentos para 86.400 ciclos: %d" % segments
	)


## Un nodo delegado tiene que **construir mientras no estás**, no al volver.
##
## El avance del tiempo se compone; las decisiones no. De un solo salto, el nodo crecía hasta
## el techo de los edificios que tenía al cerrar el juego y el gobernador construía todo de
## golpe al final — la ausencia entera desperdiciada, que es justo lo contrario de la razón
## por la que se delega. `catch_up` trocea en pasos acotados para que se alternen.
func _delegated_grows_while_away() -> int:
	var away := TestUtil.make_engine(31337)
	away.state.root().governor = Governor.balanced()
	# Ocho horas fuera.
	away.catch_up(8.0 * 3600.0)
	var node := away.state.root()

	var failures := TestUtil.check(
		node.building_total() > 20,
		"ocho horas delegado construyen %d edificios y %.0f habitantes" % [
			node.building_total(), node.pop,
		],
		"tras ocho horas delegado solo hay %d edificios y %.0f habitantes: las decisiones no " % [
			node.building_total(), node.pop,
		] + "se están intercalando con el crecimiento"
	)

	# Y la población tiene que haber aprovechado lo construido, no quedarse en el techo viejo.
	var snap := Integrator.snapshot(node, away.params)
	failures += TestUtil.check(
		node.pop > 50.0 and node.pop <= snap.cap + 1.0,
		"la población ha seguido al techo que se iba construyendo: %.1f de %.1f" % [
			node.pop, snap.cap,
		],
		"la población (%.1f) no ha seguido al techo construido (%.1f)" % [node.pop, snap.cap]
	)

	# Sin delegar no hay decisiones que intercalar: se resuelve de un salto y punto.
	var alone := TestUtil.make_engine(31337)
	alone.catch_up(8.0 * 3600.0)
	failures += TestUtil.check(
		alone.state.root().building_total() == 2,
		"un nodo sin delegar no construye solo mientras no estás",
		"un nodo sin delegar ha construido %d edificios sin permiso" % \
			alone.state.root().building_total()
	)
	return failures


## Volver tiene que contarse. El catch-up funcionaba y era invisible.
func _the_return_is_reported() -> int:
	var engine := TestUtil.make_engine(4040)
	engine.state.root().governor = Governor.balanced()
	engine.catch_up(6.0 * 3600.0)
	var report := engine.last_offline

	var failures := TestUtil.check(
		report != null and report.has_anything_to_say(),
		"volver de seis horas genera informe",
		"no se ha generado informe de la ausencia"
	)
	if report == null:
		return failures
	failures += TestUtil.check(
		report.pop_after > report.pop_before and report.buildings_built > 0,
		"el informe cuenta lo que pasó: %.0f → %.0f hab y %d edificios" % [
			report.pop_before, report.pop_after, report.buildings_built,
		],
		"el informe no recoge el crecimiento (%.0f → %.0f, %d edificios)" % [
			report.pop_before, report.pop_after, report.buildings_built,
		]
	)

	# Y un nodo **sin delegar** que se quedó en su techo tiene que salir señalado: es el
	# argumento honesto para delegar, y esconderlo sería vender el idle a medias.
	var alone := TestUtil.make_engine(4040)
	alone.catch_up(6.0 * 3600.0)
	failures += TestUtil.check(
		not alone.last_offline.idle_nodes.is_empty(),
		"y avisa de lo perdido por no delegar: %s parado en su techo" % \
			alone.last_offline.idle_nodes[0],
		"un nodo parado en su techo seis horas no se señala en el informe"
	)
	return failures


## **El guardián de la regla dura de las mejoras.** Todos sus efectos son multiplicadores
## constantes; si alguno dejara de serlo, la forma cerrada se rompería y esto lo cazaría.
func _upgrades_do_not_break_the_closed_form() -> int:
	var stepwise := TestUtil.make_engine(9090)
	var jump := TestUtil.make_engine(9090)
	for engine in [stepwise, jump]:
		var node: SimNode = engine.state.root()
		node.upgrades = PackedStringArray([
			"sharp_axes", "crop_rotation", "granary", "sturdy_frames", "shared_hearth",
			"wide_paths",
		])
		node.invalidate_effects()

	for _i in 5000:
		stepwise.tick(1.0)
	jump.tick(5000.0)

	var a := stepwise.state.root()
	var b := jump.state.root()
	var worst := TestUtil.rel_error(a.pop, b.pop)
	for i in Goods.COUNT:
		worst = maxf(worst, TestUtil.rel_error(a.stocks[i], b.stocks[i]))

	return TestUtil.check(
		worst <= TOLERANCE,
		"con las 6 mejoras compradas, offline == online sigue exacto (error %s)" % \
			TestUtil.sci(worst),
		"alguna mejora ha roto la linealidad: error %s entre online y offline" % \
			TestUtil.sci(worst)
	)


## El catch-up recorta por el tope de horas y cobra la eficiencia **en tiempo acreditado**.
func _cap_and_efficiency() -> int:
	var failures := 0

	var capped := TestUtil.make_engine(11)
	var p := capped.params
	var expected := p.offline_cap_seconds * p.offline_efficiency / p.seconds_per_cycle
	var credited := capped.catch_up(p.offline_cap_seconds * 10.0)
	failures += TestUtil.check(
		absf(credited - expected) < 1.0,
		"tope offline: 10× el máximo acredita %0.f ciclos (24 h al 50 %%)" % credited,
		"el tope offline acredita %0.f ciclos, se esperaban %0.f" % [credited, expected]
	)

	# Estar fuera tiene que dar **menos mundo**, no un mundo distinto: la mitad de tiempo
	# acreditado, con la misma economía. La regresión que esto fija era brutal — con la
	# eficiencia aplicada a la producción, la granja rendía menos de lo que comía su gente,
	# el techo alimentario caía a cero y cerrar el juego extinguía el asentamiento.
	var away := TestUtil.make_engine(11)
	var same := TestUtil.make_engine(11)
	var seconds := 200.0 * away.params.seconds_per_cycle
	away.catch_up(seconds)
	same.tick(seconds * same.params.offline_efficiency / same.params.seconds_per_cycle)

	var a := away.state.root()
	var b := same.state.root()
	failures += TestUtil.check(
		TestUtil.rel_error(a.pop, b.pop) <= TOLERANCE,
		"el offline es tiempo, no otra economía: pob %.4f == %.4f" % [a.pop, b.pop],
		"volver de estar fuera da un estado distinto a simular ese tiempo: %.4f vs %.4f" % [
			a.pop, b.pop,
		]
	)
	failures += TestUtil.check(
		a.pop > away.params.initial_pop and not a.starving,
		"tras 200 ciclos fuera el asentamiento ha crecido a %.2f hab, sin hambruna" % a.pop,
		"tras estar fuera el asentamiento se ha ido a %.3f hab (hambruna=%s)" % [
			a.pop, a.starving,
		]
	)
	return failures


## **M1, criterio 2.** Con rutas, un salto por checkpoint (`tick(governor_interval)`) frente a
## `tick(1)`: mismo error relativo que `_compare`. El hash no se pide igual, porque la forma
## cerrada y el paso a paso no coinciden en el último bit ni sin rutas.
##
## No se compara contra un único salto largo: el caudal se fija en cada checkpoint, así que entre
## dos checkpoints es donde la ruta es una constante y el salto tiene que ser exacto.
func _route_jumps_match_steps(label: String, make: Callable) -> int:
	var measured := _jump_vs_step(make, true)
	# El mismo escenario sin la ruta, como vara de medir: el error que se acepta es el que ya hay.
	var baseline := _jump_vs_step(make, false)
	var worst: float = measured[0]
	return TestUtil.check(
		worst <= TOLERANCE and bool(measured[2]),
		"%s: 100 checkpoints de un salto == ciclo a ciclo, error máx. %s en %s (sin la ruta, %s)" % [
			label, TestUtil.sci(worst), measured[1], TestUtil.sci(baseline[0]),
		],
		"%s: saltar de checkpoint en checkpoint no da lo mismo que ciclo a ciclo: error %s en %s" % [
			label, TestUtil.sci(worst), measured[1],
		]
	)


## `[error máximo, dónde, mismos nodos]` entre `tick(1)` y `tick(governor_interval)` a lo largo de
## 100 checkpoints. Con `keep_route = false` se borra la ruta antes de empezar.
func _jump_vs_step(make: Callable, keep_route: bool) -> Array:
	var stepwise: SimEngine = make.call()
	var jump: SimEngine = make.call()
	if not keep_route:
		for engine in [stepwise, jump]:
			var r: Route = engine.state.routes[0]
			Logistics.set_route(engine.state, r.from_id, r.to_id, r.good, 0.0)
	var interval := stepwise.params.governor_interval
	var checkpoints := 100
	for _i in int(interval) * checkpoints:
		stepwise.tick(1.0)
	for _i in checkpoints:
		jump.tick(interval)

	var worst := 0.0
	var worst_name := "nada"
	for id in stepwise.state.ordered_ids():
		var a: SimNode = stepwise.state.nodes[id]
		var b: SimNode = jump.state.nodes.get(id)
		if b == null:
			return [INF, "el nodo %d, que solo existe paso a paso" % id, false]
		var err := TestUtil.rel_error(a.pop, b.pop)
		if err > worst:
			worst = err
			worst_name = "población de %d" % id
		for i in Goods.COUNT:
			err = TestUtil.rel_error(a.stocks[i], b.stocks[i])
			if err > worst:
				worst = err
				worst_name = "%s de %d" % [Goods.NAMES[i], id]
	return [worst, worst_name, stepwise.state.nodes.size() == jump.state.nodes.size()]


## **Lo que decide si el spike pasa:** una ruta no crea ni destruye nada. Si el origen se vacía a
## mitad de tramo, el destino deja de recibir en el mismo instante; si el destino se llena, el
## origen deja de pagar. Con madera, que nadie produce ni consume aquí, lo que hay entre los dos
## nodos tiene que ser lo mismo antes y después, y lo movido, exactamente `expected`.
##
## Sin el corte, el primer caso entregaba 15 de madera habiendo salido 5 del origen.
func _route_conserves(label: String, origin: float, dest_room: float, expected: float) -> int:
	var failures := 0
	for mode in ["paso a paso", "de un salto"]:
		var engine := _wood_route(origin, dest_room)
		var state := engine.state
		var root := state.root()
		var child: SimNode = state.nodes[root.children[0]]
		var dest_before := child.stocks[Goods.WOOD]
		var total_before := root.stocks[Goods.WOOD] + dest_before
		if mode == "paso a paso":
			for _i in 30:
				engine.tick(1.0)
		else:
			engine.tick(30.0)
		var moved := child.stocks[Goods.WOOD] - dest_before
		var total_after := root.stocks[Goods.WOOD] + child.stocks[Goods.WOOD]
		failures += TestUtil.check(
			TestUtil.rel_error(total_before, total_after) <= 1.0e-9
				and absf(moved - expected) <= 1.0e-9 and state.routes[0].flow == 0.0,
			"%s (%s): la ruta mueve %.6f de madera y se corta; total %.6f → %.6f" % [
				label, mode, moved, total_before, total_after,
			],
			"%s (%s): la ruta no conserva: movido %.9f (se esperaba %.1f), total %.9f → %.9f, caudal %.2f" % [
				label, mode, moved, expected, total_before, total_after, state.routes[0].flow,
			]
		)
	return failures


## Pueblo y colonia sin leñadores, con una ruta de madera de 0,5/ciclo del pueblo a la colonia. El
## pueblo empieza con `origin` de madera y la colonia a `dest_room` de su tope (o vacía con 0).
func _wood_route(origin: float, dest_room: float) -> SimEngine:
	var engine := TestUtil.make_routed_engine(5150, Goods.WOOD, 0.5)
	var state := engine.state
	var root := state.root()
	var child: SimNode = state.nodes[root.children[0]]
	var woodcutter := Content.building_index("woodcutter")
	root.jobs[woodcutter] = 0.0
	child.jobs[woodcutter] = 0.0
	root.stocks[Goods.WOOD] = origin
	var cap := child.storage_caps(engine.params)[Goods.WOOD]
	child.stocks[Goods.WOOD] = cap + dest_room if dest_room < 0.0 else 0.0
	return engine


## Una colonia que se despuebla se poda, y sus rutas se van con ella **en el mismo tick**: el
## siguiente checkpoint no puede encontrarse una ruta con un extremo que ya no existe.
func _pruned_node_drops_its_routes() -> int:
	var engine := TestUtil.make_routed_engine(4243)
	var state := engine.state
	var child_id: int = state.root().children[0]
	(state.nodes[child_id] as SimNode).pop = 0.0
	engine.tick(1.0)
	return TestUtil.check(
		not state.nodes.has(child_id) and state.routes.is_empty()
			and state.root().route_offset.is_empty(),
		"podar una colonia borra sus rutas en el mismo tick, y el padre deja de pagarlas",
		"podar una colonia deja %d rutas colgando (colonia %s)" % [
			state.routes.size(), "viva" if state.nodes.has(child_id) else "podada",
		]
	)


## Una región que alimenta a una ciudad: el campo de la ciudad da de comer a 36 (15 granjeros ×
## 0,6 / 0,25) y la región le manda `rate` 🌾/ciclo. La región tiene comida y 🐎 de sobra en el
## almacén, para que lo único que se mida sea el destino.
func _fed_city(rate: float) -> SimEngine:
	var engine := TestUtil.make_engine(6060)
	var state := engine.state
	var root := state.root()
	root.tier = Content.REGION
	root.stocks[Goods.FOOD] = 5.0e4
	root.stocks[Goods.TRANSPORT] = 5.0e4
	state.refresh_totals()
	root.pop = 500.0
	var child := TestUtil.found_now(state, root, engine.params)
	root.pop = 5.0
	var farm := Content.building_index("farm")
	child.buildings[farm] = 5
	child.jobs[farm] = 15.0
	child.buildings[Content.building_index("hut")] = 20  # alojamiento de 110: manda la comida
	child.pop = 36.0
	state.refresh_totals()
	Logistics.set_route(state, root.id, child.id, Goods.FOOD, rate)
	return engine


## Lo importado se suma al `K` como `caudal / consumo por habitante`, hasta el 50 % del propio.
func _imported_food_raises_k() -> int:
	var failures := 0
	var cap := SimParams.new().food_import_cap
	for case in [[0.0, 36.0], [4.0, 52.0], [20.0, 36.0 * (1.0 + cap)]]:
		var engine := _fed_city(case[0])
		var child: SimNode = engine.state.nodes[engine.state.root().children[0]]
		var k := Integrator.snapshot(child, engine.params).food_capacity
		failures += TestUtil.check(
			absf(k - float(case[1])) <= 1.0e-9,
			"con %.0f 🌾/ciclo importados el techo por comida es %.2f (propio 36)" % [case[0], k],
			"con %.0f 🌾/ciclo importados el techo es %.6f y se esperaba %.2f" % [
				case[0], k, case[1],
			]
		)
	return failures


## **Hecho cuando de M2.** La ciudad crece con la ruta por encima de su campo; al cortarla baja a
## su `K` propio con la logística descendente, sin extinguirse. Paso a paso y de un salto dan lo
## mismo, y un salto offline de 40.000 ciclos la deja en 36, no en cero.
func _cut_route_falls_to_own_k() -> int:
	var stepwise := _fed_city(4.0)
	var jump := _fed_city(4.0)
	for engine in [stepwise, jump]:
		for _i in 40:
			engine.tick(30.0)
	var fed: float = (stepwise.state.nodes[stepwise.state.root().children[0]] as SimNode).pop
	for engine in [stepwise, jump]:
		var root: SimNode = engine.state.root()
		Logistics.set_route(engine.state, root.id, root.children[0], Goods.FOOD, 0.0)
	var cut_k := Integrator.snapshot(
		stepwise.state.nodes[stepwise.state.root().children[0]], stepwise.params).food_capacity
	for _i in 3000:
		stepwise.tick(1.0)
	jump.tick(3000.0)
	var a: SimNode = stepwise.state.nodes[stepwise.state.root().children[0]]
	var b: SimNode = jump.state.nodes[jump.state.root().children[0]]
	var err := TestUtil.rel_error(a.pop, b.pop)
	var failures := TestUtil.check(
		fed > 50.0 and absf(cut_k - 36.0) <= 1.0e-9 and absf(a.pop - 36.0) <= 1.0e-3
			and err <= TOLERANCE,
		"con la ruta la ciudad llega a %.2f hab; cortada, su techo vuelve a %.0f y baja a %.4f (de un salto, %.4f; error %s)" % [
			fed, cut_k, a.pop, b.pop, TestUtil.sci(err),
		],
		"cortar la ruta no devuelve la ciudad a su K propio: con ruta %.2f, K %.3f, paso a paso %.6f, de un salto %.6f" % [
			fed, cut_k, a.pop, b.pop,
		]
	)
	# Un día fuera de golpe tras el corte: la caída logística se detiene en el K propio.
	var away := _fed_city(4.0)
	for _i in 40:
		away.tick(30.0)
	var away_root: SimNode = away.state.root()
	Logistics.set_route(away.state, away_root.id, away_root.children[0], Goods.FOOD, 0.0)
	away.tick(40000.0)
	var c: SimNode = away.state.nodes.get(away_root.children[0])
	failures += TestUtil.check(
		c != null and absf(c.pop - 36.0) <= 1.0e-6,
		"un salto offline de 40.000 ciclos tras el corte la deja en %.6f hab, no en cero" % [
			c.pop if c != null else -1.0,
		],
		"tras el corte y un salto largo la ciudad no está en su K propio: %s" % [
			"podada" if c == null else "%.6f hab" % c.pop,
		]
	)
	return failures


## **Una expedición llega igual tickeando de 1 en 1 que de un salto.** `SimEngine.tick` parte el
## tramo en el ciclo de llegada, así que el hijo nace en el mismo instante y crece el mismo resto
## del tramo avance como avance el reloj: 2.450 × `tick(1)`, un `tick(2450)` y 64 pasos como los
## del catch-up. Con `offset` la salida, y con ella la llegada, cae a mitad de ciclo y el corte
## parte un `tick(1)`. Sin gobernador: las decisiones no se componen (ver `catchup_test`).
func _expedition_jumps_match_steps(label: String, offset: float) -> int:
	# 50 ciclos después de la llegada: la colonia todavía está lejos de su techo y cualquier ciclo
	# de más o de menos se nota en su población y en sus stocks.
	const CYCLES := 2450
	var engines: Array[SimEngine] = []
	var child_id := -1
	for _i in 3:
		var engine := TestUtil.make_engine(4343)
		var root := engine.state.root()
		root.tier = Content.TOWN
		root.buildings[Content.building_index("hut")] = 20
		root.buildings[Content.building_index("farm")] = 8
		root.pop = 60.0
		for i in Goods.COUNT:
			root.stocks[i] = 400.0
		engine.state.refresh_totals()
		if offset > 0.0:
			engine.tick(offset)
		# El hijo será el siguiente id: sin gobernador no nace ningún otro nodo.
		child_id = engine.state.next_id
		Promotion.launch_expedition(engine.state, root, engine.params, null)
		engines.append(engine)
	var stepwise := engines[0]
	var jump := engines[1]
	var chunked := engines[2]
	for _i in CYCLES:
		stepwise.tick(1.0)
	jump.tick(float(CYCLES))
	for _i in 64:
		chunked.tick(float(CYCLES) / 64.0)

	var a: SimNode = stepwise.state.nodes.get(child_id)
	var failures := 0
	for pair in [[jump, "de un salto"], [chunked, "en 64 pasos"]]:
		var other: SimEngine = pair[0]
		var b: SimNode = other.state.nodes.get(child_id)
		if a == null or b == null:
			failures += TestUtil.check(false, "",
				"%s: el hijo no ha llegado (%s 1 en 1, %s %s)" % [
					label, a != null, b != null, pair[1],
				])
			continue
		var worst := TestUtil.rel_error(a.pop, b.pop)
		for i in Goods.COUNT:
			worst = maxf(worst, TestUtil.rel_error(a.stocks[i], b.stocks[i]))
			worst = maxf(worst, TestUtil.rel_error(
				stepwise.state.root().stocks[i], other.state.root().stocks[i]))
		worst = maxf(worst, TestUtil.rel_error(stepwise.state.root().pop, other.state.root().pop))
		failures += TestUtil.check(
			worst <= TOLERANCE and other.state.expeditions.is_empty(),
			"expedición, %s: el hijo nace igual de 1 en 1 que %s, error máx. %s · pob %.4f" % [
				label, pair[1], TestUtil.sci(worst), b.pop,
			],
			"expedición, %s: de 1 en 1 y %s difieren, error %s (pob %.6f vs %.6f)" % [
				label, pair[1], TestUtil.sci(worst), a.pop, b.pop,
			]
		)
	return failures


## Una ciudad sin gobernador con una expedición en camino (16.800 ciclos: 2.400 × el reloj ×7 de
## Ciudad, sin hijos). Sin gobernador, como `_expedition_jumps_match_steps`: las decisiones no se
## componen. El oro justo para la aceleración se pone a mano, que el test es del reloj y no de la
## economía.
func _accelerating_city(fraction: float = -1.0) -> SimEngine:
	var engine := TestUtil.make_engine(4444)
	if fraction >= 0.0:
		engine.params.accelerate_fraction = fraction
	var root := engine.state.root()
	root.tier = Content.CITY
	root.buildings[Content.building_index("hut")] = 20
	root.buildings[Content.building_index("farm")] = 8
	root.pop = 60.0
	for i in Goods.COUNT:
		root.stocks[i] = 400.0
	engine.state.refresh_totals()
	Promotion.launch_expedition(engine.state, root, engine.params, null)
	return engine


func _pay_and_accelerate(engine: SimEngine) -> bool:
	var root := engine.state.root()
	root.stocks[Goods.GOLD] = Promotion.accelerate_cost(engine.state, root, engine.params)
	return Promotion.accelerate_expedition(engine.state, root, engine.params, null)


## **Acelerar y luego avanzar N×1 da lo mismo que acelerar y avanzar N de golpe.** Acelerar es una
## acción discreta entre ticks: mueve `arrive_cycle` y `SimEngine.tick` ya parte el tramo en la
## llegada nueva. Se acelera dos veces a mitad de viaje (ciclo 8.001: quedan 8.799 → 6.599,25 →
## 4.949,4375), así que la llegada cae a mitad de ciclo y el corte parte un `tick(1)`; luego 1 en 1,
## de un salto y en 64 pasos hasta 50 ciclos después de la llegada.
func _accelerated_jumps_match_steps() -> int:
	const PREFIX := 8001.0
	var engines: Array[SimEngine] = []
	var child_id := -1
	var arrive := 0.0
	var failures := 0
	for _i in 3:
		var engine := _accelerating_city()
		engine.tick(PREFIX)
		child_id = engine.state.next_id
		var ok := _pay_and_accelerate(engine) and _pay_and_accelerate(engine)
		var e := engine.state.expedition_of(engine.state.root().id)
		if not ok or e == null or e.accelerations != 2:
			return TestUtil.check(false, "", "⏩ no se ha podido acelerar dos veces la expedición")
		arrive = e.arrive_cycle
		engines.append(engine)
	failures += TestUtil.check(
		is_equal_approx(arrive, PREFIX + (16800.0 - PREFIX) * 0.75 * 0.75),
		"⏩ dos aceleraciones recortan un 25 %% cada una: llega en el ciclo %.4f" % arrive,
		"⏩ la llegada acelerada está en %.4f, no en %.4f" % [
			arrive, PREFIX + (16800.0 - PREFIX) * 0.5625,
		]
	)
	var cycles := int(ceil(arrive - PREFIX)) + 50
	var stepwise := engines[0]
	var jump := engines[1]
	var chunked := engines[2]
	for _i in cycles:
		stepwise.tick(1.0)
	jump.tick(float(cycles))
	for _i in 64:
		chunked.tick(float(cycles) / 64.0)

	var a: SimNode = stepwise.state.nodes.get(child_id)
	for pair in [[jump, "de un salto"], [chunked, "en 64 pasos"]]:
		var other: SimEngine = pair[0]
		var b: SimNode = other.state.nodes.get(child_id)
		if a == null or b == null:
			failures += TestUtil.check(false, "",
				"⏩ acelerada: el hijo no ha llegado (%s 1 en 1, %s %s)" % [
					a != null, b != null, pair[1],
				])
			continue
		var worst := TestUtil.rel_error(a.pop, b.pop)
		for i in Goods.COUNT:
			worst = maxf(worst, TestUtil.rel_error(a.stocks[i], b.stocks[i]))
			worst = maxf(worst, TestUtil.rel_error(
				stepwise.state.root().stocks[i], other.state.root().stocks[i]))
		worst = maxf(worst, TestUtil.rel_error(stepwise.state.root().pop, other.state.root().pop))
		failures += TestUtil.check(
			worst <= TOLERANCE and other.state.expeditions.is_empty(),
			"⏩ acelerar y avanzar %d ciclos: 1 en 1 == %s, error máx. %s · pob %.4f" % [
				cycles, pair[1], TestUtil.sci(worst), b.pop,
			],
			"⏩ acelerada: de 1 en 1 y %s difieren, error %s (pob %.6f vs %.6f)" % [
				pair[1], TestUtil.sci(worst), a.pop, b.pop,
			]
		)
	return failures


## **Acelerar con la llegada en el mismo ciclo.** Con un recorte del 100 % la llegada caería justo
## ahora: se acota a `state.cycle`, sigue en camino (no se pierde en el pasado) y el siguiente
## `tick(1)` la recoge con `pop_arrivals`, en ese ciclo exacto.
func _accelerated_to_now_arrives_next_tick() -> int:
	var engine := _accelerating_city(1.0)
	engine.tick(1000.5)
	var child_id := engine.state.next_id
	var ok := _pay_and_accelerate(engine)
	var e := engine.state.expedition_of(engine.state.root().id)
	var waiting := ok and e != null and e.arrive_cycle == engine.state.cycle
	engine.tick(1.0)
	return TestUtil.check(
		waiting and engine.state.nodes.has(child_id) and engine.state.expeditions.is_empty(),
		"⏩ acelerar hasta ahora la deja en el ciclo de hoy y llega en el siguiente tick",
		"⏩ acelerar hasta ahora: acelerada %s, en camino %s, hijo %s" % [
			ok, waiting, engine.state.nodes.has(child_id),
		]
	)


## Lo que se pide a un nodo con ⚡ boost, más estricto que `TOLERANCE`: sin boost, los mismos
## escenarios dan errores de 1e-11.
const BOOST_TOLERANCE := 1.0e-9
## El boost acaba a mitad de un checkpoint (1.515 no es múltiplo de 30): el salto parte el tramo.
const BOOST_CYCLES := 1515.0


## **⚡ N×1 == N con un nodo a otro ritmo y su ruta al padre.** El escenario del spike de rutas
## (`TestUtil.make_routed_engine`), con el boost en el hijo a ×2 y ×4 y luego en el padre, que es
## quien paga el 🐎. 100 checkpoints ciclo a ciclo frente a uno de un salto cada uno, como
## `_route_jumps_match_steps`, con el boost expirando a mitad: los stocks, las poblaciones y el
## reloj propio del nodo (`k·1.515 + el resto`) tienen que salir iguales.
func _boost_n_by_1_equals_jump() -> int:
	var failures := 0
	for k in [2.0, 4.0]:
		for on_parent in [false, true]:
			var who: String = "el padre" if on_parent else "el hijo"
			var engines: Array[SimEngine] = []
			for _i in 2:
				var engine := TestUtil.make_routed_engine(4242)
				var root := engine.state.root()
				var node: SimNode = root if on_parent else engine.state.nodes[root.children[0]]
				SimEngine.apply_boost(engine.state, node, k, BOOST_CYCLES)
				engines.append(engine)
			var stepwise := engines[0]
			var jump := engines[1]
			var interval := stepwise.params.governor_interval
			for _i in int(interval) * 100:
				stepwise.tick(1.0)
			for _i in 100:
				jump.tick(interval)
			var measured := _worst_between(stepwise, jump)
			var boosted_id: int = stepwise.state.root_id if on_parent \
				else stepwise.state.root().children[0]
			var a: SimNode = stepwise.state.nodes[boosted_id]
			var b: SimNode = jump.state.nodes[boosted_id]
			var clock: float = stepwise.state.cycle + (k - 1.0) * BOOST_CYCLES
			failures += TestUtil.check(
				float(measured[0]) <= BOOST_TOLERANCE and bool(measured[2])
					and a.local_cycle == clock and b.local_cycle == clock
					and a.boost_factor == 1.0 and b.boost_factor == 1.0,
				"⚡ ×%d en %s con ruta: 100 checkpoints de un salto == ciclo a ciclo, error máx. %s en %s; reloj %.0f" % [
					int(k), who, TestUtil.sci(measured[0]), measured[1], a.local_cycle,
				],
				"⚡ ×%d en %s: error %s en %s, reloj %.4f / %.4f (se esperaba %.0f), ×%.0f / ×%.0f al final" % [
					int(k), who, TestUtil.sci(measured[0]), measured[1], a.local_cycle,
					b.local_cycle, clock, a.boost_factor, b.boost_factor,
				]
			)
	return failures


## `[error relativo máximo, dónde, mismos nodos]` entre dos motores, en población y stocks.
func _worst_between(x: SimEngine, y: SimEngine) -> Array:
	var worst := 0.0
	var worst_name := "nada"
	for id in x.state.ordered_ids():
		var a: SimNode = x.state.nodes[id]
		var b: SimNode = y.state.nodes.get(id)
		if b == null:
			return [INF, "el nodo %d, que solo existe en uno" % id, false]
		var err := TestUtil.rel_error(a.pop, b.pop)
		if err > worst:
			worst = err
			worst_name = "población de %d" % id
		for i in Goods.COUNT:
			err = TestUtil.rel_error(a.stocks[i], b.stocks[i])
			if err > worst:
				worst = err
				worst_name = "%s de %d" % [Goods.NAMES[i], id]
	return [worst, worst_name, x.state.nodes.size() == y.state.nodes.size()]


## **⚡ Una ruta con un extremo acelerado no crea ni tira nada.** `_route_conserves` con el boost
## en el destino o en el origen: el hijo integra `k·t` ciclos suyos con el caudal a `1/k`, y lo que
## entra tiene que ser lo que sale, también en el instante del corte (la sonda de `_first_breach`
## cuenta en ciclos del nodo y lo pasa al reloj global). Con madera, que nadie produce ni consume.
func _boost_route_conserves() -> int:
	var failures := 0
	for k in [2.0, 4.0]:
		for on_origin in [false, true]:
			for case in [[5.0, 0.0, 5.0, "el origen se vacía"], [100.0, -3.0, 3.0, "el destino se llena"]]:
				for mode in ["paso a paso", "de un salto"]:
					var engine := _wood_route(case[0], case[1])
					var state := engine.state
					var root := state.root()
					var child: SimNode = state.nodes[root.children[0]]
					SimEngine.apply_boost(state, root if on_origin else child, k, 600.0)
					var parent_before := root.stocks[Goods.WOOD]
					var dest_before := child.stocks[Goods.WOOD]
					if mode == "paso a paso":
						for _i in 30:
							engine.tick(1.0)
					else:
						engine.tick(30.0)
					var left_parent := parent_before - root.stocks[Goods.WOOD]
					var moved := child.stocks[Goods.WOOD] - dest_before
					var label := "⚡ ×%d en %s, %s (%s)" % [
						int(k), "el origen" if on_origin else "el destino", case[3], mode,
					]
					failures += TestUtil.check(
						absf(left_parent - moved) <= BOOST_TOLERANCE
							and absf(moved - float(case[2])) <= BOOST_TOLERANCE
							and state.routes[0].flow == 0.0,
						"%s: sale %.6f de madera del padre y entra %.6f en el hijo" % [
							label, left_parent, moved,
						],
						"%s: la ruta no conserva: sale %.12f, entra %.12f (se esperaba %.1f), caudal %.2f" % [
							label, left_parent, moved, case[2], state.routes[0].flow,
						]
					)
	return failures


## **⚡ La colonia nace en el mismo ciclo de 1 en 1 que de un salto, con el boost expirando a mitad
## de viaje.** Dos casos sobre el pueblo de `_expedition_jumps_match_steps`: el boost llega con la
## expedición ya en camino (×2 en el ciclo 100,3: se recalcula lo que le queda) y la expedición
## sale con el boost puesto (×4 en el ciclo 0,3). En los dos la llegada cerrada tiene que ser la de
## la cuenta a mano —el tramo acelerado cuenta `k` y el resto 1— y el hijo, el mismo en los tres
## troceados.
func _boost_expedition_n_by_1() -> int:
	var failures := 0
	for boost_first in [false, true]:
		var k: float = 4.0 if boost_first else 2.0
		var at: float = 0.3 if boost_first else 100.3
		# A ×4, 600 ciclos son justo los 2.400 del viaje: con 450 el boost acaba a mitad.
		var lasts: float = 450.0 if boost_first else 600.0
		var engines: Array[SimEngine] = []
		var child_id := -1
		var arrive := 0.0
		var expected := 0.0
		for _i in 3:
			var engine := TestUtil.make_engine(4343)
			var state := engine.state
			var root := state.root()
			root.tier = Content.TOWN
			root.buildings[Content.building_index("hut")] = 20
			root.buildings[Content.building_index("farm")] = 8
			root.pop = 60.0
			for i in Goods.COUNT:
				root.stocks[i] = 400.0
			state.refresh_totals()
			var trip := Promotion.expedition_cycles(state, root, engine.params)
			child_id = state.next_id
			if boost_first:
				engine.tick(at)
				SimEngine.apply_boost(state, root, k, lasts)
				Promotion.launch_expedition(state, root, engine.params, null)
				# `lasts` ciclos a ×k son `lasts·k` del viaje; el resto, a ritmo normal.
				expected = at + lasts + (trip - lasts * k)
			else:
				Promotion.launch_expedition(state, root, engine.params, null)
				engine.tick(at)
				SimEngine.apply_boost(state, root, k, lasts)
				expected = at + lasts + (trip - at - lasts * k)
			arrive = state.expedition_of(root.id).arrive_cycle
			engines.append(engine)
		var case := "×%d %s" % [int(k), "y luego sale" if boost_first else "con la expedición en camino"]
		failures += TestUtil.check(
			is_equal_approx(arrive, expected) and arrive > at + lasts,
			"⚡ %s: llega en el ciclo %.4f, después del fin del boost (%.1f)" % [case, arrive, at + lasts],
			"⚡ %s: la llegada está en %.6f, no en %.6f" % [case, arrive, expected]
		)
		var cycles := int(ceil(arrive - at)) + 50
		var stepwise := engines[0]
		var jump := engines[1]
		var chunked := engines[2]
		for _i in cycles:
			stepwise.tick(1.0)
		jump.tick(float(cycles))
		for _i in 64:
			chunked.tick(float(cycles) / 64.0)
		var a: SimNode = stepwise.state.nodes.get(child_id)
		for pair in [[jump, "de un salto"], [chunked, "en 64 pasos"]]:
			var other: SimEngine = pair[0]
			var b: SimNode = other.state.nodes.get(child_id)
			if a == null or b == null:
				failures += TestUtil.check(false, "",
					"⚡ %s: el hijo no ha llegado (%s 1 en 1, %s %s)" % [case, a != null, b != null, pair[1]])
				continue
			var measured := _worst_between(stepwise, other)
			var root_a := stepwise.state.root()
			var root_b := other.state.root()
			failures += TestUtil.check(
				float(measured[0]) <= BOOST_TOLERANCE and bool(measured[2])
					and other.state.expeditions.is_empty() and root_b.boost_factor == 1.0
					and root_a.local_cycle == root_b.local_cycle,
				"⚡ %s: la colonia nace igual de 1 en 1 que %s, error máx. %s · pob %.4f" % [
					case, pair[1], TestUtil.sci(measured[0]), b.pop,
				],
				"⚡ %s: de 1 en 1 y %s difieren, error %s en %s, reloj %.4f / %.4f" % [
					case, pair[1], TestUtil.sci(measured[0]), measured[1], root_a.local_cycle,
					root_b.local_cycle,
				]
			)
	return failures


## **⌛ El goteo cuenta igual online que offline.** 10.800 ciclos de 1 en 1 frente a una ausencia
## que acredita esos mismos 10.800 (`catch_up` con el doble de segundos, por la eficiencia offline):
## los dos dejan 3 ⌛ goteados y el mismo `drip_cycle`, en el último múltiplo de `drip_interval`.
func _drip_online_offline_equal() -> int:
	var online := TestUtil.make_engine(4242)
	var offline := TestUtil.make_engine(4242)
	var p := online.params
	var cycles := 3.0 * p.drip_interval
	for _i in int(cycles):
		online.tick(1.0)
	var credited := offline.catch_up(cycles * p.seconds_per_cycle / p.offline_efficiency)
	var a := online.state
	var b := offline.state
	return TestUtil.check(
		credited == cycles and a.cycle == cycles and b.cycle == cycles
			and Shop.count_of(a, "skip_15m") == 3 and Shop.count_of(b, "skip_15m") == 3
			and a.drip_held == 3 and b.drip_held == 3
			and a.drip_cycle == cycles and b.drip_cycle == a.drip_cycle,
		"⌛ goteo: %d ciclos de 1 en 1 y una ausencia equivalente dejan 3 ⌛ y `drip_cycle` %.0f" % [
			int(cycles), a.drip_cycle,
		],
		"⌛ goteo online != offline: acreditados %.1f, ⌛ %d / %d, goteados %d / %d, `drip_cycle` %.1f / %.1f" % [
			credited, Shop.count_of(a, "skip_15m"), Shop.count_of(b, "skip_15m"), a.drip_held,
			b.drip_held, a.drip_cycle, b.drip_cycle,
		]
	)
