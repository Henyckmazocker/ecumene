extends SceneTree
## El mundo está anclado. Ejecutar con:
##   godot-4 --headless --path . -s res://tools/terrain_test.gd
##
## El invariante que hace posible que promocionar **abra el mundo** en vez de rehacerlo:
##
##   **El mismo punto del mundo da siempre el mismo terreno, sea cual sea el tamaño de la
##   ventana que se pida.**
##
## La versión anterior dividía la frecuencia del ruido por el tamaño del mapa y centraba el
## domo en la mitad de la ventana. Con eso, pedir 96 celdas en vez de 64 no daba el mismo
## mundo con más alrededores: daba otro mundo, y promocionar habría rehecho el terreno bajo
## los pies del jugador.

const TestUtil := preload("res://tools/TestUtil.gd")

## La última escala con tamaño propio: la ventana más grande que se genera.
const SIZE_LAST_TIER := 6


func _init() -> void:
	var failures := 0
	failures += _window_size_does_not_change_the_world()
	failures += _promotion_keeps_buildings_in_place()
	failures += _every_seed_is_habitable()
	failures += _buildings_all_find_a_spot()
	failures += _buildings_never_overlap()
	failures += _incremental_layout_matches_full()
	failures += _sliced_prep_matches()
	failures += _the_root_terrain_does_not_change()
	failures += _a_point_is_the_same_from_every_window()
	failures += _every_child_lands_on_buildable_ground()
	failures += _siblings_keep_their_distance()
	failures += _positions_survive_save_and_load()
	failures += _a_child_sees_its_parents_world()
	TestUtil.finish(self, failures)


## Ampliar la ventana no puede cambiar ni una celda de lo que ya se veía.
func _window_size_does_not_change_the_world() -> int:
	var failures := 0
	for seed_value in [1, 4242, 99999]:
		var small := TerrainGen.generate(seed_value, Vector2i.ZERO, Content.SETTLEMENT)
		var big := TerrainGen.generate(seed_value, Vector2i.ZERO, Content.CITY)
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

	var core := Layout.core_radius(engine.state.depth_of(node))
	var before_terrain := TerrainGen.generate(
		engine.state.terrain_seed(), engine.state.world_pos_of(node), node.tier)
	var before := Layout.build(node, before_terrain, core)
	var positions := {}
	for p in before.placements:
		positions[p.cell] = p.building

	# Promocionar sin tocar nada más: solo cambia el tier, y con él el tamaño de la ventana.
	# Relativo y no `= Content.TOWN`: el nodo va delegado y el gobernador ya lo asciende solo,
	# así que fijar la escala a mano podía no promocionar nada.
	node.tier += 1
	var after_terrain := TerrainGen.generate(
		engine.state.terrain_seed(), engine.state.world_pos_of(node), node.tier)
	var after := Layout.build(node, after_terrain, core)

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
		var terrain := TerrainGen.generate(seed_value, Vector2i.ZERO, Content.SETTLEMENT)
		if not terrain.is_buildable(Vector2i.ZERO):
			drowned += 1
			continue
		var hist := terrain.histogram()
		var buildable := 0
		for b in range(Relief.COUNT):
			if Relief.is_buildable(b):
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

	var core := Layout.core_radius(engine.state.depth_of(node))
	var terrain := TerrainGen.generate(
		engine.state.terrain_seed(), engine.state.world_pos_of(node), node.tier)
	var layout := Layout.build(node, terrain, core)
	var failures := TestUtil.check(
		layout.placements.size() == node.building_total(),
		"los %d edificios construidos están todos colocados" % node.building_total(),
		"solo %d de %d edificios encuentran sitio" % [
			layout.placements.size(), node.building_total(),
		]
	)
	# Y la ciudad de 48.000 ciclos con gobernador (M3b de «Vista agregada y zoom continuo») cabe
	# entera en el núcleo de la raíz, sobre el terreno que le pone la vista.
	var city := _full_city(engine.state)
	var window := TerrainGen.generate(engine.state.terrain_seed(), Vector2i.ZERO, city.tier,
			SettlementView.window_size(city.tier, 0))
	var packed := Layout.build(city, window, core)
	var far := 0.0
	for p in packed.placements:
		far = maxf(far, Vector2(p.cell).length())
	failures += TestUtil.check(
		packed.placements.size() == city.building_total() and far <= core,
		"la ciudad de %d edificios cabe entera en su núcleo de %.0f celdas (la más lejana a %.1f)" % [
			city.building_total(), core, far,
		],
		"la ciudad no cabe en su núcleo: %d de %d colocados, el más lejano a %.1f de %.0f" % [
			packed.placements.size(), city.building_total(), far, core,
		]
	)
	return failures


## Los edificios de la raíz tras 48.000 ciclos con gobernador (M2: ~538), sin simularlos: los
## mismos en todas las semillas, porque el gobernador no mira el terreno.
func _full_city(state: WorldState) -> SimNode:
	var city := state.root()
	city.tier = Content.CITY
	var want := {
		"hut": 70, "farm": 72, "woodcutter": 77, "storehouse": 47, "quarry": 49,
		"workshop": 47, "commons": 51, "depot": 40, "market": 45, "temple": 40,
	}
	var counts := PackedInt32Array()
	counts.resize(Content.building_count())
	for i in Content.building_count():
		counts[i] = want.get(Content.building(i).id, 0)
	city.buildings = counts
	return city


## Ningún edificio pisa a otro, y entre dos cualesquiera queda hueco.
##
## Este es el aserto que faltaba. `Layout` reservaba **una celda** por edificio mientras
## `SettlementView` los dibujaba con `def.footprint * TILE`: una granja de 1.5 de ancho ocupa
## de `celda − 0.25` a `celda + 1.25`, así que se comía a su vecino. Cinco de los ocho tipos
## tienen huella mayor que 1 y ninguna prueba lo miraba, porque todas comprobaban *cuántos*
## edificios se colocan y ninguna *dónde*.
##
## Se mide de dos maneras: en celdas reservadas (`bleed_of`, al menos `GAP`), y sobre las huellas
## **dibujadas** (`footprint`), donde tiene que quedar al menos `GAP − 2 × BLEED_TOLERANCE`. La
## segunda es la que no se puede trampear cambiando `bleed_of`. Y en una ciudad llena metida en
## su núcleo, que es donde más aprieta (M3b).
func _buildings_never_overlap() -> int:
	var failures := 0
	var min_drawn := float(Layout.GAP) - 2.0 * Layout.BLEED_TOLERANCE
	for tier in [Content.SETTLEMENT, Content.TOWN, Content.CITY]:
		var engine := TestUtil.make_engine(555)
		var node := engine.state.root()
		if tier == Content.CITY:
			node = _full_city(engine.state)
		else:
			node.governor = Governor.balanced()
			for _i in 80:
				engine.tick(25.0)
			node.tier = tier

		var terrain := TerrainGen.generate(
			engine.state.terrain_seed(), engine.state.world_pos_of(node), node.tier)
		var layout := Layout.build(node, terrain, Layout.core_radius(0))

		var collisions := 0
		var tightest := 999
		var tightest_drawn := 999.0
		for i in layout.placements.size():
			for j in range(i + 1, layout.placements.size()):
				var a: Layout.Placement = layout.placements[i]
				var b: Layout.Placement = layout.placements[j]
				# Separación libre entre las dos huellas dibujadas, por eje. Basta con que
				# **uno** de los dos ejes las separe para que no se toquen.
				var def_a := Content.building(a.building)
				var def_b := Content.building(b.building)
				var bleed_a := Layout.bleed_of(def_a)
				var bleed_b := Layout.bleed_of(def_b)
				var delta := (a.cell - b.cell).abs()
				var gap_x := delta.x - bleed_a.x - bleed_b.x - 1
				var gap_y := delta.y - bleed_a.y - bleed_b.y - 1
				var gap := maxi(gap_x, gap_y)
				tightest = mini(tightest, gap)
				# Y sobre lo dibujado: cada quad mide `footprint` centrado en su celda.
				var drawn := maxf(float(delta.x) - (def_a.footprint.x + def_b.footprint.x) * 0.5,
						float(delta.y) - (def_a.footprint.y + def_b.footprint.y) * 0.5)
				tightest_drawn = minf(tightest_drawn, drawn)
				if gap < Layout.GAP or drawn < min_drawn - 0.0001:
					collisions += 1

		failures += TestUtil.check(
			collisions == 0,
			"%s: los %d edificios no se pisan y guardan %d celda(s) de hueco (%.2f entre lo dibujado)" % [
				Content.tier(tier).name, layout.placements.size(), tightest, tightest_drawn,
			],
			"%s: %d parejas de edificios se pisan o quedan a menos de %d celda(s) (%.2f dibujado)" % [
				Content.tier(tier).name, collisions, Layout.GAP, min_drawn,
			]
		)
	return failures


## Continuar el layout edificio a edificio da **exactamente** lo mismo que colocarlo de cero.
##
## La vista ya no recoloca el pueblo entero cada vez que se construye algo: continúa desde el
## layout anterior con `Layout.extend`. Pero al recargar la partida o al volver a entrar en el
## nodo lo que corre es un `build` en frío, y si las dos rutas no coincidieran el pueblo se
## vería distinto tras recargar. Por eso se compara celda a celda, no «sin solapes».
##
## La cadena crece casi siempre por tipos de índice bajo —cabañas, granjas—, que es el caso
## difícil: obliga a recolocar todo lo que va detrás exactamente como lo haría `build`. Y de
## vez en cuando algo baja o desaparece un tipo, que `extend` también tiene que aguantar
## aunque la vista use `build` en ese caso.
##
## Dos veces: sin núcleo, y con un núcleo pequeño que se llena a media cadena (M3b), para que
## `extend` pase también por los tipos que ya no cabían (`NO_SPOT`).
func _incremental_layout_matches_full() -> int:
	return _incremental_chain(INF) + _incremental_chain(14.0)


func _incremental_chain(core: float) -> int:
	var engine := TestUtil.make_engine(4242)
	var node := engine.state.root()
	node.tier = Content.REGION  # ventana grande: cabe todo y hay sitio para crecer
	var terrain := TerrainGen.generate(
		engine.state.terrain_seed(), engine.state.world_pos_of(node), node.tier)
	var rng := RandomNumberGenerator.new()
	rng.seed = 2026

	var counts := PackedInt32Array()
	counts.resize(Content.building_count())
	node.buildings = counts.duplicate()
	var chained := Layout.build(node, terrain, core)
	var steps := 0
	var mismatches := 0
	var first_bad := ""
	for step in 90:
		var b := rng.randi_range(0, Content.building_count() - 1)
		if rng.randf() < 0.5:
			b = rng.randi_range(0, 2)  # sesgo a índice bajo: lo que más hay que recolocar
		if step % 15 == 14 and counts[b] > 0:
			counts[b] = 0 if rng.randf() < 0.5 else counts[b] - 1
		else:
			counts[b] += rng.randi_range(1, 3)
		node.buildings = counts.duplicate()
		chained = Layout.extend(chained, node, terrain, core)
		var full := Layout.build(node, terrain, core)
		steps += 1
		var why := _layout_difference(chained, full)
		if why != "":
			mismatches += 1
			if first_bad == "":
				first_bad = "paso %d: %s" % [step, why]

	var unplaced := node.building_total() - chained.placements.size()
	return TestUtil.check(
		mismatches == 0 and (core == INF or unplaced > 0),
		"núcleo %s: %d pasos de `extend` dan lo mismo que `build`, celda a celda (%d edificios al final, %d sin sitio)" % [
			str(core), steps, chained.placements.size(), unplaced,
		],
		"núcleo %s: %d de %d pasos de `extend` no coinciden con `build` (%s), %d sin sitio" % [
			str(core), mismatches, steps, first_bad, unplaced,
		]
	)


## La vista prepara el foco nuevo **por trozos** entre fotogramas (`SettlementView.PrepJob`, M3 de
## «Vista agregada y zoom continuo»): el terreno fila a fila, con su imagen, y el `Layout` por
## tandas de `extend`. Lo troceado tiene que salir **idéntico** a lo de un tirón —`TerrainGen
## .generate`, `TerrainGen.to_image` y `Layout.build`—, o entrar en un hijo dibujaría otro mundo
## que el que se ve desde el padre. Se trocea a lo bruto (un plazo ya vencido: un paso por
## llamada), en las cuatro escalas jugables, desde cero y desde un `Layout` en caché atrasado.
func _sliced_prep_matches() -> int:
	var engine := TestUtil.make_engine(5150)
	var state := engine.state
	var node := state.root()
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var mismatches: Array[String] = []
	var calls := 0
	for tier in [Content.SETTLEMENT, Content.TOWN, Content.CITY, Content.REGION]:
		node.tier = tier
		var counts := PackedInt32Array()
		counts.resize(Content.building_count())
		for b in Content.buildings_for_tier(tier):
			counts[b] = rng.randi_range(1, 6)
		node.buildings = counts.duplicate()
		var seed_value := state.terrain_seed()
		var at := state.world_pos_of(node)
		# Cada escala a otra profundidad: la ventana (`window_size`) y el núcleo salen de ella
		# (M3b), y la preparación troceada tiene que usar los mismos.
		var depth: int = tier % 3
		var core := Layout.core_radius(depth)
		var terrain := TerrainGen.generate(seed_value, at, tier,
				SettlementView.window_size(tier, depth))
		var full := Layout.build(node, terrain, core)

		var job := SettlementView.PrepJob.new(node, seed_value, at, null, depth)
		while not job.step(0):
			calls += 1
		var p := job.prepared
		if p.terrain.cells != terrain.cells or p.terrain.size != terrain.size:
			mismatches.append("tier %d: terreno distinto" % tier)
		if p.texture.get_image().get_data() != TerrainGen.to_image(terrain).get_data():
			mismatches.append("tier %d: textura distinta" % tier)
		var why := _layout_difference(p.layout, full)
		if why != "":
			mismatches.append("tier %d desde cero: %s" % [tier, why])

		# Desde la caché: el mismo terreno con un `Layout` de cuando había otros edificios.
		var older := counts.duplicate()
		older[Content.buildings_for_tier(tier)[0]] += 2
		for b in Content.buildings_for_tier(tier):
			if rng.randf() < 0.4:
				older[b] = maxi(older[b] - 2, 0)
		node.buildings = older
		p.layout = Layout.build(node, p.terrain, core)
		node.buildings = counts.duplicate()
		var again := SettlementView.PrepJob.new(node, seed_value, at, p, depth)
		while not again.step(0):
			calls += 1
		why = _layout_difference(again.prepared.layout, full)
		if why != "":
			mismatches.append("tier %d desde la caché: %s" % [tier, why])
		if again.prepared.terrain != p.terrain:
			mismatches.append("tier %d: con la caché se ha vuelto a generar el terreno" % tier)

	return TestUtil.check(
		mismatches.is_empty() and calls > 100,
		"lo troceado (%d trozos) sale idéntico: terreno, textura y `Layout`, en 4 escalas, desde cero y desde la caché" % calls,
		"la preparación troceada no coincide: %s" % ", ".join(mismatches)
	)


## Vacío si los dos layouts son idénticos; si no, la primera diferencia.
func _layout_difference(a: Layout.Result, b: Layout.Result) -> String:
	if a.signature != b.signature:
		return "firmas distintas"
	if a.placements.size() != b.placements.size():
		return "%d edificios frente a %d" % [a.placements.size(), b.placements.size()]
	for i in a.placements.size():
		var pa: Layout.Placement = a.placements[i]
		var pb: Layout.Placement = b.placements[i]
		if pa.building != pb.building or pa.cell != pb.cell:
			return "el edificio %d cae en %s y no en %s" % [i, pa.cell, pb.cell]
	if a.by_building != b.by_building:
		return "`by_building` distinto"
	return ""


## La raíz tiene que ver exactamente el terreno de antes de que hubiera centro: con
## `center = (0, 0)` no puede cambiar ni un téxel, o las partidas existentes verían otro mapa.
##
## Se compara contra la `generate` vieja copiada tal cual (`_legacy_generate`), no contra un
## fixture: así el test no depende de un fichero binario y dice qué fórmula era la buena.
func _the_root_terrain_does_not_change() -> int:
	var failures := 0
	for seed_value in [1, 555, 4242, 31337, 99999, -123456789]:
		for tier in [Content.SETTLEMENT, Content.TOWN, Content.CITY, SIZE_LAST_TIER]:
			var now := TerrainGen.generate(seed_value, Vector2i.ZERO, tier)
			var before := _legacy_generate(seed_value, tier)
			failures += TestUtil.check(
				now.size == before.size and now.cells == before.cells,
				"seed %d, ventana de %d: el terreno de la raíz es idéntico al de antes" % [
					seed_value, now.size,
				],
				"seed %d, ventana de %d: el terreno de la raíz ha cambiado" % [
					seed_value, now.size,
				]
			)
	return failures



## Copia literal de `TerrainGen.generate(node_seed, tier)` antes de M1. No se toca: es la
## referencia contra la que se mide la raíz.
func _legacy_generate(node_seed: int, tier: int) -> TerrainGen.Terrain:
	var size: int = TerrainGen.SIZE_BY_TIER[clampi(tier, 0, TerrainGen.SIZE_BY_TIER.size() - 1)]
	var terrain := TerrainGen.Terrain.new()
	terrain.size = size
	terrain.seed = node_seed
	terrain.cells.resize(size * size)

	var height := TerrainGen._make_noise(node_seed, 3.0 / TerrainGen.NOISE_SCALE, 4)

	var origin := terrain.origin()
	for y in size:
		for x in size:
			var wx := float(x - origin)
			var wy := float(y - origin)
			terrain.cells[y * size + x] = TerrainGen.relief_at(height, wx, wy)
	return terrain


## El mismo punto del mundo, visto desde ventanas con centros distintos, da el mismo terreno.
## Es lo que permite que un hijo sea una ventana del mundo de su padre: si el realce o el
## ruido se midieran desde el centro de cada ventana, acercarse a tierra baja abriría una
## cumbre. Los centros incluyen el (0, 0) para que el realce de la raíz entre en la cuenta.
func _a_point_is_the_same_from_every_window() -> int:
	var failures := 0
	var centers := [
		Vector2i(0, 0), Vector2i(5, -3), Vector2i(-20, 17), Vector2i(40, 0), Vector2i(-37, -51),
	]
	for seed_value in [1, 4242, 99999]:
		var reference := TerrainGen.generate(seed_value, Vector2i.ZERO, Content.CITY)
		var mismatches := 0
		var compared := 0
		var against_world := 0
		for center: Vector2i in centers:
			var window := TerrainGen.generate(seed_value, center, Content.SETTLEMENT)
			for ly in range(-window.extent(), window.extent()):
				for lx in range(-window.extent(), window.extent()):
					var local := Vector2i(lx, ly)
					var global := local + center
					if not reference.in_bounds(global):
						continue
					compared += 1
					if window.at(local) != reference.at(global):
						mismatches += 1
			# Y contra la consulta suelta, que no construye ventana: el centro de cada ventana
			# es el terreno de su posición en el mundo.
			if window.at(Vector2i.ZERO) != TerrainGen.relief_at_world(
					seed_value, float(center.x), float(center.y)):
				against_world += 1
		failures += TestUtil.check(
			mismatches == 0 and against_world == 0 and compared > 0,
			"seed %d: %d celdas vistas desde %d ventanas con centros distintos dan el mismo terreno" % [
				seed_value, compared, centers.size(),
			],
			"seed %d: %d de %d celdas cambian según el centro de la ventana (%d centros contra relief_at_world)" % [
				seed_value, mismatches, compared, against_world,
			]
		)
	return failures


# ---------------------------------------------------------------------------
# Posición de cada nodo en el mundo común (`WorldState.world_pos_of`)
# ---------------------------------------------------------------------------

## Semillas de los árboles de prueba. Variadas a propósito, con una negativa.
const TREE_SEEDS := [1, 555, 4242, 31337, 99999, -123456789]
## El árbol de M0: una región con 6 pueblos, y 4 asentamientos en cada pueblo.
const TREE_TOWNS := 6
const TREE_SETTLEMENTS := 4


## El árbol completo hasta Región, montado a mano con `add_node`: la colocación solo depende de
## las semillas y del árbol, no de la simulación, así que no hace falta tickear nada.
func _make_tree(seed_value: int) -> WorldState:
	var state := WorldState.create(seed_value, SimParams.new())
	state.root().tier = Content.REGION
	for _t in TREE_TOWNS:
		var town := state.add_node(Content.TOWN, state.root_id)
		for _s in TREE_SETTLEMENTS:
			state.add_node(Content.SETTLEMENT, town.id)
	return state


## Extensión del anillo de un nodo, la misma regla que `WorldState` (por profundidad).
func _extent_of(state: WorldState, node: SimNode) -> float:
	var table := WorldState.PLACE_EXTENT_BY_DEPTH
	return table[clampi(state.depth_of(node) - 1, 0, table.size() - 1)]


## Cada colonia cae en tierra: centro edificable y al menos el 80 % del cuadrado de 7×7 a su
## alrededor, para que `Layout` tenga dónde poner sus primeros edificios. Sin el realce propio
## de cada nodo (que ahora solo tiene la raíz), un hijo podría nacer en el agua. Se mira sobre
## la ventana que verá el jugador, no sobre la cuenta interna de `WorldState`.
func _every_child_lands_on_buildable_ground() -> int:
	var children := 0
	var drowned := 0
	var cramped := 0
	var worst := 1.0
	var outside_ring := 0
	for seed_value in TREE_SEEDS:
		var state := _make_tree(seed_value)
		for id in state.ordered_ids():
			var node: SimNode = state.nodes[id]
			if id == state.root_id:
				continue
			children += 1
			var pos := state.world_pos_of(node)
			var terrain := TerrainGen.generate(state.terrain_seed(), pos, node.tier)
			if not terrain.is_buildable(Vector2i.ZERO):
				drowned += 1
			var ok := 0
			for dy in range(-3, 4):
				for dx in range(-3, 4):
					if terrain.is_buildable(Vector2i(dx, dy)):
						ok += 1
			var fraction := float(ok) / 49.0
			worst = minf(worst, fraction)
			if fraction < WorldState.PLACE_MIN_BUILDABLE:
				cramped += 1
			# Y dentro del anillo de su padre, fuera de su núcleo (±1 celda por el redondeo).
			var parent: SimNode = state.nodes[node.parent_id]
			var ring := state.child_ring(parent)
			var r := Vector2(pos - state.world_pos_of(parent)).length()
			if r < ring.x - 1.0 or r > ring.y + 1.0 \
					or r <= Layout.core_radius(state.depth_of(parent)):
				outside_ring += 1
	return TestUtil.check(
		drowned == 0 and cramped == 0 and outside_ring == 0,
		"%d colonias en %d árboles hasta Región: todas en tierra, dentro de su anillo, y la peor con un %.0f %% edificable alrededor" % [
			children, TREE_SEEDS.size(), worst * 100.0,
		],
		"de %d colonias: %d en suelo no edificable, %d con menos del 80 %% edificable alrededor, %d fuera del anillo" % [
			children, drowned, cramped, outside_ring,
		]
	)


## Dos hermanos no se pisan: entre cualquier pareja quedan más de 0,30 de la extensión del
## anillo. Con eso la vista agregada puede pintarlos sin que una mancha tape a la otra.
func _siblings_keep_their_distance() -> int:
	var pairs := 0
	var too_close := 0
	var tightest := INF
	for seed_value in TREE_SEEDS:
		var state := _make_tree(seed_value)
		for id in state.ordered_ids():
			var parent: SimNode = state.nodes[id]
			for i in parent.children.size():
				for j in range(i + 1, parent.children.size()):
					var a: SimNode = state.nodes[parent.children[i]]
					var b: SimNode = state.nodes[parent.children[j]]
					var e := _extent_of(state, a)
					var d := Vector2(state.world_pos_of(a) - state.world_pos_of(b)).length() / e
					pairs += 1
					tightest = minf(tightest, d)
					if d <= WorldState.PLACE_SIBLING_GAP:
						too_close += 1
	return TestUtil.check(
		too_close == 0 and pairs > 0,
		"%d parejas de hermanos, ninguna a menos de %.2f e (la más justa, %.2f e)" % [
			pairs, WorldState.PLACE_SIBLING_GAP, tightest,
		],
		"%d de %d parejas de hermanos están a menos de %.2f e" % [
			too_close, pairs, WorldState.PLACE_SIBLING_GAP,
		]
	)


## La posición no se guarda: se recalcula. Tras `Save.write`/`read` cada nodo tiene que estar
## exactamente donde estaba, o al volver a la partida las colonias aparecerían en otro sitio.
## Se lee la carga **antes** de pedir ninguna posición, para que la caché nazca vacía.
func _positions_survive_save_and_load() -> int:
	var state := _make_tree(4242)
	var before := {}
	for id in state.ordered_ids():
		before[id] = state.world_pos_of(state.nodes[id])
	Save.write(state)
	var loaded := Save.read([])
	Save.erase()
	if loaded == null:
		return TestUtil.check(false, "", "el árbol no se ha podido cargar")
	var moved := 0
	for id in loaded.ordered_ids():
		if not before.has(id) or loaded.world_pos_of(loaded.nodes[id]) != before[id]:
			moved += 1
	return TestUtil.check(
		moved == 0 and loaded.nodes.size() == before.size(),
		"los %d nodos están en la misma posición tras guardar y cargar" % before.size(),
		"%d de %d nodos cambian de posición al guardar y cargar" % [moved, before.size()]
	)


## Un hijo es una ventana del mundo de su padre: lo que ve alrededor de su centro es lo que el
## padre ve en esa posición. Se compara el cuadrado de 7×7 del centro, no solo la celda, para
## que un desfase de una celda en el muestreo no pase por casualidad.
func _a_child_sees_its_parents_world() -> int:
	var compared := 0
	var mismatches := 0
	var outside := 0
	for seed_value in TREE_SEEDS:
		var state := _make_tree(seed_value)
		var windows := {}
		for id in state.ordered_ids():
			var node: SimNode = state.nodes[id]
			# La ventana que pone la vista (M3b): la de la escala se queda corta para el anillo
			# de las colonias, que ahora cae fuera del núcleo del padre.
			windows[id] = TerrainGen.generate(state.terrain_seed(), state.world_pos_of(node),
				node.tier, SettlementView.window_size(node.tier, state.depth_of(node)))
		for id in state.ordered_ids():
			if id == state.root_id:
				continue
			var node: SimNode = state.nodes[id]
			var parent: SimNode = state.nodes[node.parent_id]
			var mine: TerrainGen.Terrain = windows[id]
			var theirs: TerrainGen.Terrain = windows[parent.id]
			var offset := state.world_pos_of(node) - state.world_pos_of(parent)
			for dy in range(-3, 4):
				for dx in range(-3, 4):
					var local := Vector2i(dx, dy)
					if not theirs.in_bounds(local + offset):
						outside += 1
						continue
					compared += 1
					if mine.at(local) != theirs.at(local + offset):
						mismatches += 1
	return TestUtil.check(
		mismatches == 0 and outside == 0 and compared > 0,
		"%d celdas alrededor de cada colonia dan el mismo terreno vistas desde ella y desde su padre" % compared,
		"%d de %d celdas cambian entre la colonia y su padre (%d fuera de la ventana del padre)" % [
			mismatches, compared, outside,
		]
	)
