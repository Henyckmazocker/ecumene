extends SceneTree
## Verificación headless del determinismo. Ejecutar con:
##   godot-4 --headless --path . -s res://tools/determinism_test.gd
##
## Comprueba que mismo seed + misma secuencia de acciones ⇒ mismo `state_hash()`, que dos
## seeds distintas divergen, y que un round-trip de guardado no altera el estado.

const TestUtil := preload("res://tools/TestUtil.gd")


func _init() -> void:
	var failures := 0

	# --- Dos partidas idénticas tienen que converger ciclo a ciclo ---
	var a := TestUtil.make_engine(1234)
	var b := TestUtil.make_engine(1234)
	var diverged_at := -1
	for i in 500:
		a.tick(1.0)
		b.tick(1.0)
		if a.state.state_hash() != b.state.state_hash():
			diverged_at = i
			break
	if diverged_at >= 0:
		print("FALLO: dos partidas con seed 1234 divergen en el ciclo %d" % diverged_at)
		failures += 1
	else:
		print("OK  determinismo: 500 ciclos, hash idéntico (%d)" % a.state.state_hash())

	# --- Seeds distintas producen mundos distintos ---
	var c := TestUtil.make_engine(9999)
	c.tick(500.0)
	if c.state.root().name == a.state.root().name:
		print("FALLO: seeds distintas generan el mismo nombre de asentamiento")
		failures += 1
	else:
		print("OK  seeds distintas: %s vs %s" % [a.state.root().name, c.state.root().name])

	# --- Las acciones del jugador no rompen el determinismo ---
	var d := TestUtil.make_engine(77)
	var e := TestUtil.make_engine(77)
	for i in 200:
		d.tick(1.0)
		e.tick(1.0)
		if i % 25 == 0:
			var hut := Content.building_index("hut")
			Construction.build(d.state.root(), hut, d.state.cycle, null)
			Construction.build(e.state.root(), hut, e.state.cycle, null)
	if d.state.state_hash() != e.state.state_hash():
		print("FALLO: construir en paralelo diverge")
		failures += 1
	else:
		print("OK  acciones deterministas: %d cabañas, hash %d" % [
			d.state.root().buildings[Content.building_index("hut")], d.state.state_hash(),
		])

	# --- Un gobernador que funda: el árbol delegado crece dentro del tick ---
	# Lo que funda un gobernador nace delegado (`GovernorSys.delegate`) al llegar la expedición,
	# así que el hijo y su gobernador se crean a mitad del tick, en el corte de la llegada. Dos
	# partidas iguales tienen que seguir iguales. Con el reloj, la primera expedición sale en el
	# primer checkpoint y llega 2.400 ciclos después: se miran 2.800.
	var f := _founding_town(4242)
	var g := _founding_town(4242)
	var forked_at := -1
	for i in 2800:
		f.tick(1.0)
		g.tick(1.0)
		if f.state.state_hash() != g.state.state_hash():
			forked_at = i
			break
	var delegated_children := 0
	for id in f.state.root().children:
		var child: SimNode = f.state.nodes.get(id)
		if child != null and child.is_delegated():
			delegated_children += 1
	if forked_at >= 0:
		print("FALLO: dos pueblos delegados que fundan divergen en el ciclo %d" % forked_at)
		failures += 1
	elif delegated_children == 0:
		print("FALLO: el pueblo delegado no ha fundado ninguna colonia delegada en 2.800 ciclos")
		failures += 1
	else:
		print("OK  un pueblo delegado funda %d colonias delegadas y el hash no se mueve (%d)" % [
			delegated_children, f.state.state_hash(),
		])

	# --- Cada orden del gobernador, por separado, sigue siendo determinista ---
	# El gobernador decide en checkpoints (cada `governor_interval` ciclos, con tope de 64 por
	# llamada), así que aquí **no** se compara `tick(N)` con N × `tick(1)`: eso no se cumple con
	# gobernador ni sin órdenes. Lo que sí tiene que cumplirse es que dos partidas iguales, con la
	# misma orden fijada antes de empezar, avancen igual paso a paso. Mientras las órdenes no hagan
	# nada pasa trivialmente; el test está para cuando empiecen a sesgar decisiones.
	for order in [Governor.Order.STOCKPILE, Governor.Order.EXPAND, Governor.Order.SPECIALIZE]:
		failures += _same_with_order(order, 4242, 1500)

	# --- Expediciones (M1): mismo `state_hash` con expediciones en camino y al llegar ---
	failures += _same_with_expeditions(4545)

	# --- Una ruta entre dos nodos no rompe el determinismo (M1, criterio 1) ---
	failures += _same_with_route(4242, 1500)
	failures += _same_with_regional_governor(4343, 1500)

	TestUtil.finish(self, failures)


## **Mismo `state_hash` con expediciones.** Dos pueblos gemelos lanzan una expedición a mano y
## otra tras la llegada, a `tick(1)`: el hash tiene que ser el mismo en cada ciclo, en camino y al
## llegar. Y la expedición entra en el hash: sin ella, el mismo mundo daría otra huella.
func _same_with_expeditions(seed_value: int) -> int:
	var a := _founding_town(seed_value)
	var b := _founding_town(seed_value)
	for e in [a, b]:
		e.state.root().governor = null
		Promotion.launch_expedition(e.state, e.state.root(), e.params, null)
	var in_flight := a.state.state_hash()
	var saved: Expedition = a.state.expeditions[0]
	a.state.expeditions.clear()
	var hashed := a.state.state_hash() != in_flight
	a.state.add_expedition(saved)
	var forked_at := -1
	var relaunched := false
	for i in 2700:
		a.tick(1.0)
		b.tick(1.0)
		if not relaunched and not a.state.root().children.is_empty():
			relaunched = true
			for e in [a, b]:
				e.state.root().pop = maxf(e.state.root().pop, 40.0)
				e.state.root().stocks[Goods.FOOD] = maxf(e.state.root().stocks[Goods.FOOD], 100.0)
				Promotion.launch_expedition(e.state, e.state.root(), e.params, null)
		if a.state.state_hash() != b.state.state_hash():
			forked_at = i
			break
	return TestUtil.check(
		forked_at < 0 and hashed and relaunched and a.state.expeditions.size() == 1,
		"con expediciones: 2.700 ciclos gemelos, una llegada y otra en camino, hash idéntico (%d)"
			% a.state.state_hash(),
		"con expediciones: divergen en el ciclo %d (en el hash: %s, llegada: %s, en camino: %d)"
			% [forked_at, hashed, relaunched, a.state.expeditions.size()]
	)


## Dos partidas gemelas con una ruta de comida de 0,5/ciclo, a `tick(1)`: el hash tiene que ser el
## mismo en cada ciclo. La ruta se corta y vuelve en los checkpoints, y el corte se busca con
## sondas sobre copias de los nodos: si algo de eso iterase un `Dictionary`, divergiría aquí.
func _same_with_route(seed_value: int, cycles: int) -> int:
	var a := TestUtil.make_routed_engine(seed_value)
	var b := TestUtil.make_routed_engine(seed_value)
	if a.state.routes.size() != 1:
		return TestUtil.check(false, "", "el escenario de la ruta no ha podido montarse")
	var forked_at := -1
	for i in cycles:
		a.tick(1.0)
		b.tick(1.0)
		if a.state.state_hash() != b.state.state_hash():
			forked_at = i
			break
	return TestUtil.check(
		forked_at < 0,
		"ruta de comida a 0,5/ciclo: %d ciclos gemelos, hash idéntico (%d)" % [
			cycles, a.state.state_hash(),
		],
		"dos partidas gemelas con una ruta divergen en el ciclo %d" % forked_at
	)


## Dos regiones delegadas gemelas cuyo gobernador lleva las rutas de comida (M4): crea, ajusta y
## borra rutas en sus checkpoints, y el hash tiene que seguir siendo el mismo en cada ciclo.
func _same_with_regional_governor(seed_value: int, cycles: int) -> int:
	var a := TestUtil.make_regional_engine(seed_value)
	var b := TestUtil.make_regional_engine(seed_value)
	var forked_at := -1
	for i in cycles:
		a.tick(1.0)
		b.tick(1.0)
		if a.state.state_hash() != b.state.state_hash():
			forked_at = i
			break
	var food := 0
	for r in a.state.routes:
		food += 1 if r.good == Goods.FOOD else 0
	return TestUtil.check(
		forked_at < 0 and food > 0,
		"gobernador regional con %d rutas de comida: %d ciclos gemelos, hash idéntico (%d)" % [
			food, cycles, a.state.state_hash(),
		],
		"dos regiones gemelas divergen en el ciclo %d (%d rutas de comida)" % [forked_at, food]
	)


## Dos pueblos delegados gemelos con la misma orden, avanzados `cycles` veces con `tick(1)`.
func _same_with_order(order: Governor.Order, seed_value: int, cycles: int) -> int:
	var label: String = Governor.Order.keys()[order]
	var a := _founding_town(seed_value)
	var b := _founding_town(seed_value)
	a.state.root().governor.order = order
	b.state.root().governor.order = order
	var forked_at := -1
	for i in cycles:
		a.tick(1.0)
		b.tick(1.0)
		if a.state.state_hash() != b.state.state_hash():
			forked_at = i
			break
	return TestUtil.check(
		forked_at < 0,
		"orden %s: %d ciclos delegados, hash idéntico (%d)" % [
			label, cycles, a.state.state_hash(),
		],
		"orden %s: dos partidas delegadas con la misma orden divergen en el ciclo %d" % [
			label, forked_at,
		]
	)


## Pueblo delegado con gente y comida de sobra para fundar en cuanto le toque un checkpoint.
func _founding_town(seed_value: int) -> SimEngine:
	var engine := TestUtil.make_engine(seed_value)
	var root := engine.state.root()
	root.tier = Content.TOWN
	root.buildings[Content.building_index("hut")] = 20
	root.buildings[Content.building_index("farm")] = 8
	root.pop = 60.0
	for i in Goods.COUNT:
		root.stocks[i] = 400.0
	root.governor = Governor.balanced()
	engine.state.refresh_totals()
	return engine
