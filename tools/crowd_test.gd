extends SceneTree
## La dramatización: que se vea viva y que no mienta. Ejecutar con:
##   godot-4 --headless --path . -s res://tools/crowd_test.gd
##
## Sustituye al `agents_test` de M1. Aquel fijaba que rematerializar reprodujera exactamente
## los mismos habitantes, que era precisamente el bug: el pueblo entero se rebarajaba cada vez
## que la población cruzaba un entero. El contrato nuevo es otro:
##
##   **La multitud puede ir con retraso respecto a los números. No puede mentir, y no puede
##   dar saltos.**

const TestUtil := preload("res://tools/TestUtil.gd")

## Paso de tiempo visual usado en los tests, ~60 fps.
const STEP := 1.0 / 60.0


## Todo lo que hace falta para tener un pueblo vivo sin abrir una ventana.
class Village:
	extends RefCounted
	var engine: SimEngine
	var node: SimNode
	var terrain: TerrainGen.Terrain
	var layout: Layout.Result
	var crowd: Crowd
	var reconciler := CrowdReconciler.new()
	var params := CrowdParams.new()

	func rebuild_layout() -> void:
		if layout == null or layout.signature != node.buildings:
			layout = Layout.build(node, terrain)

	## Avanza `seconds` de tiempo **visual**, sin tocar la simulación económica.
	func live(seconds: float) -> void:
		var steps := int(seconds / STEP)
		for _i in steps:
			rebuild_layout()
			reconciler.sync(crowd, node, layout, params, STEP)
			crowd.advance(STEP, params)


## Los ciclos de cada escenario se bajaron en M0b de «Plan - Expediciones de colonización» (p. ej.
## 1.200 → 750, 1.600 → 1.125): el gobernador dejó de tirar el resto del intervalo y a `tick(25)`
## decide cada 30 ciclos y no cada 50, así que el mismo pueblo se alcanza antes. Se eligieron para
## que la población y los edificios sigan como antes, y la multitud se pruebe sobre lo mismo.
static func make_village(seed_value: int, cycles: float, delegate: bool = true) -> Village:
	var v := Village.new()
	v.engine = TestUtil.make_engine(seed_value)
	v.node = v.engine.state.root()
	if delegate:
		v.node.governor = Governor.balanced()
	var step := 25.0
	for _i in int(cycles / step):
		v.engine.tick(step)
	v.terrain = TerrainGen.generate(
		v.engine.state.terrain_seed(), v.engine.state.world_pos_of(v.node), v.node.tier)
	v.crowd = Crowd.new(v.node.seed)
	v.rebuild_layout()
	return v


## `_initialize` y no `_init`: el fundido (`_crossfade_never_jumps`) monta una `SettlementView` de
## verdad, y para eso el árbol tiene que estar ya en marcha.
func _initialize() -> void:
	var failures := 0
	failures += _view_never_writes_state()
	failures += _nobody_teleports()
	failures += _crossfade_never_jumps()
	failures += _converges_to_the_aggregate()
	failures += _no_reshuffle_when_population_grows()
	failures += _lives_while_paused()
	failures += _pace_ignores_sim_speed()
	failures += _new_buildings_appear_at_once()
	failures += _a_day_has_shape()
	failures += _pose_matches_what_they_are_doing()
	failures += _one_dot_per_several_villagers()
	failures += _the_drawn_crowd_stays_bounded()
	TestUtil.finish(self, failures)


## Un punto por cada varios habitantes: la multitud es una **muestra** del agregado, no una
## copia. Es lo que hace que el coste de la vista no crezca con la población.
func _one_dot_per_several_villagers() -> int:
	var params := CrowdParams.new()
	var detail := params.full_detail_pop

	var failures := TestUtil.check(
		params.dots_for(float(detail)) == detail,
		"hasta %d habitantes se dibujan todos, uno a uno" % detail,
		"un asentamiento de %d se dibuja con %d puntos" % [detail, params.dots_for(float(detail))]
	)

	# Pasado el detalle completo, cada punto vale por `villagers_per_dot`.
	var big := float(detail) + 1000.0
	var dots := params.dots_for(big)
	var expected := detail + int(round(1000.0 / params.villagers_per_dot))
	failures += TestUtil.check(
		dots == expected,
		"a %.0f habitantes salen %d puntos: uno por cada %.0f" % [
			big, dots, params.villagers_per_dot,
		],
		"a %.0f habitantes salen %d puntos y tocaban %d" % [big, dots, expected]
	)

	# Continuo en la frontera: cruzar `full_detail_pop` frena el ritmo de aparición, no borra a
	# nadie. Con un cociente a secas se pasaría de 60 puntos a 12 en un ciclo.
	var before := params.dots_for(float(detail))
	var after := params.dots_for(float(detail) + 1.0)
	failures += TestUtil.check(
		after >= before and after - before <= 1,
		"al cruzar el detalle completo nadie desaparece (%d → %d puntos)" % [before, after],
		"cruzar el detalle completo da un salto de %d a %d puntos" % [before, after]
	)

	# Y el tope duro sigue siendo tope.
	failures += TestUtil.check(
		params.dots_for(1.0e9) == params.max_villagers,
		"el tope duro aguanta: %d puntos con mil millones de habitantes" % params.max_villagers,
		"el tope duro no se respeta: %d puntos" % params.dots_for(1.0e9)
	)
	return failures


## **Lo que se dibuja tiene techo, pase lo que pase con la población.**
##
## El tope contaba solo a los habitantes activos, y los que se marchaban se apilaban encima sin
## contarse: cada bajada de población daba de baja a unos cuantos, cada subida creaba otros
## tantos nuevos, y los salientes tardaban `fade_seconds` en desaparecer. Con la población
## meciéndose —que es lo normal: una mala cosecha, un ciclo de hambre— la multitud dibujada
## llegaba a triplicar la que tocaba, y toda ella pagaba su fotograma.
func _the_drawn_crowd_stays_bounded() -> int:
	var v := make_village(1717, 750)
	v.live(10.0)

	var target := v.node.pop
	var worst := 0
	var worst_pop := 0.0
	# Cuarenta bandazos de población de los que hacen bulto: arriba, abajo y vuelta.
	for wave in 40:
		v.node.pop = target * (1.6 if wave % 2 == 0 else 0.5)
		v.live(0.5)
		var expected := v.params.dots_for(v.node.pop)
		if v.crowd.size() - expected > worst:
			worst = v.crowd.size() - expected
			worst_pop = v.node.pop

	# Margen: los que salen andando en el camino gradual sí siguen dibujándose mientras se van,
	# y eso es la dramatización, no un fallo. Lo que no puede haber es una cola sin fin.
	var slack := int(ceil(v.params.arrivals_per_second * v.params.fade_seconds)) + 4
	return TestUtil.check(
		worst <= slack,
		"la multitud dibujada no se desborda: %d puntos de más como mucho (margen %d) " % [
			worst, slack,
		] + "tras 40 vaivenes de población",
		"la multitud dibujada se desborda: %d puntos por encima de los %d que tocaban a %.0f " % [
			worst, v.params.dots_for(worst_pop), worst_pop,
		] + "habitantes"
	)


## La pose dice lo que están haciendo.
##
## El fotograma va por instancia en el `MultiMesh` (`INSTANCE_CUSTOM`), y que el shader lo lea
## bien solo se comprueba con una captura. Lo que sí se puede fijar aquí es lo de arriba: que
## quien duerme salga tumbado, quien anda mueva las piernas y quien está parado no las mueva.
func _pose_matches_what_they_are_doing() -> int:
	var v := make_village(4242, 575)
	v.live(10.0)

	var sleeper := Villager.new()
	sleeper.activity = Villager.Activity.SLEEPING
	sleeper.velocity = Vector2(2.0, 0.0)  # aunque se moviera, dormir manda

	var idle := Villager.new()
	idle.activity = Villager.Activity.WORKING
	idle.velocity = Vector2(0.1, 0.0)  # micromovimiento dentro del edificio

	var walker := Villager.new()
	walker.activity = Villager.Activity.COMMUTING
	walker.velocity = Vector2(1.5, 0.0)

	var failures := TestUtil.check(
		SettlementView._villager_frame(sleeper, 0.0) == SettlementView.FRAME_SLEEP,
		"quien duerme se dibuja tumbado",
		"un durmiente no usa el fotograma de dormir"
	)
	failures += TestUtil.check(
		SettlementView._villager_frame(idle, 0.0) == SettlementView.FRAME_IDLE,
		"el micromovimiento de trabajar no dispara el ciclo de paso",
		"trabajar en el sitio se dibuja como andar"
	)

	# Andando, la pierna alterna con el tiempo: dos instantes separados tienen que dar
	# fotogramas distintos, o el ciclo de paso estaría congelado.
	var a := SettlementView._villager_frame(walker, 0.0)
	var b := SettlementView._villager_frame(walker, 1.0 / SettlementView.STEP_CADENCE)
	failures += TestUtil.check(
		a != b and a in [SettlementView.FRAME_WALK_A, SettlementView.FRAME_WALK_B]
			and b in [SettlementView.FRAME_WALK_A, SettlementView.FRAME_WALK_B],
		"quien anda alterna las dos poses de paso (%d → %d)" % [a, b],
		"el ciclo de paso no alterna: %d → %d" % [a, b]
	)
	return failures


## El invariante de siempre, y el único que no ha cambiado: la vista no es autoritativa.
func _view_never_writes_state() -> int:
	var v := make_village(4321, 625)
	var before := v.engine.state.state_hash()
	v.live(60.0)
	return TestUtil.check(
		v.engine.state.state_hash() == before,
		"60 s de vida del pueblo no tocan el estado (hash %d)" % before,
		"la multitud ha modificado el estado: %d != %d" % [
			v.engine.state.state_hash(), before,
		]
	)


## **El test de esta fase.** Nadie puede saltar de un sitio a otro entre fotogramas: ni al
## crecer la población, ni al construirse un edificio, ni al cambiar de oficio. Era justo lo
## que hacía la versión anterior cada pocos segundos.
func _nobody_teleports() -> int:
	var v := make_village(777, 500)
	v.live(5.0)  # que se repartan antes de empezar a medir

	# Tope generoso: el paso máximo con el jitter de velocidad, por dos.
	var limit := v.params.walk_speed * (1.0 + v.params.speed_jitter) * STEP * 2.5
	var worst := 0.0
	var previous := {}
	var samples := 0

	# 40 s de vida mientras la economía sigue corriendo y el gobernador construye.
	for frame in int(40.0 / STEP):
		if frame % 60 == 0:
			v.engine.tick(25.0)  # la población sube y aparecen edificios mientras se mira
		v.rebuild_layout()
		v.reconciler.sync(v.crowd, v.node, v.layout, v.params, STEP)
		v.crowd.advance(STEP, v.params)

		var current := {}
		for villager in v.crowd.villagers:
			current[villager] = villager.position
			if previous.has(villager):
				var moved: float = (previous[villager] as Vector2).distance_to(villager.position)
				worst = maxf(worst, moved)
				samples += 1
		previous = current

	return TestUtil.check(
		worst <= limit and samples > 10000,
		"nadie se teletransporta: salto máximo %.4f celdas/fotograma (tope %.4f, %d muestras)" % [
			worst, limit, samples,
		],
		"alguien ha saltado %.4f celdas en un fotograma (tope %.4f)" % [worst, limit]
	)


## **El test de M3** («Vista agregada y zoom continuo»): cambiar de foco es un fundido, y durante el
## fundido **ningún punto visible salta**. Ida y vuelta entre un pueblo y su colonia, con un vaivén
## a medio fundido (que revive la capa que se iba), sobre una `SettlementView` de verdad y
## fotograma a fotograma, midiendo lo mismo que [method _nobody_teleports] pero con **todas** las
## capas que se ven, en coordenadas del mundo:
## - nadie se mueve más que el paso máximo entre dos fotogramas;
## - nadie aparece ni desaparece de golpe: la opacidad de cada punto (la de su capa por la suya)
##   cambia como mucho lo que dan los dos fundidos en un fotograma;
## - la multitud del destino sale **ya caliente**: completa en cuanto empieza a verse;
## - al acabar no queda capa saliente, y nada de esto toca el `state_hash`.
func _crossfade_never_jumps() -> int:
	var engine := TestUtil.make_engine(9090)
	var state := engine.state
	var town := state.root()
	town.governor = Governor.balanced()
	for _i in 30:
		engine.tick(25.0)
	town.tier = Content.TOWN
	town.pop = maxf(town.pop, 500.0)
	town.stocks[Goods.FOOD] = maxf(town.stocks[Goods.FOOD], 500.0)
	state.refresh_totals()
	# El gobernador puede tener ya una expedición en camino: el escenario quiere la colonia ahora.
	state.cancel_expedition_of(town.id)
	var colony := TestUtil.found_now(state, town, engine.params, null, Governor.balanced())
	if colony == null:
		return TestUtil.check(false, "", "no se pudo fundar la colonia del escenario del fundido: %s" % \
				Promotion.found_child_blocker(state, town, engine.params))
	for _i in 10:
		engine.tick(25.0)

	var view := SettlementView.new()
	get_root().add_child(view)
	view.show_node(town, state)
	view.warm_up(12.0)
	# A media mañana, con la gente yendo y viniendo: de noche duermen y no habría salto que medir.
	view.set_hour(8.5)
	view.warm_up(2.0)
	var hash_before := state.state_hash()

	var params := view.crowd_params
	var move_limit := params.walk_speed * (1.0 + params.speed_jitter) * STEP * 2.5
	# El tope no sale de `FADE_SECONDS`, que se podría bajar a cero: un fundido de menos de un
	# cuarto de segundo ya es un parpadeo, y uno instantáneo es el corte de antes.
	var alpha_limit := STEP / 0.25 + STEP / params.fade_seconds + 1e-4
	# Ida, vuelta, y a medio camino de la vuelta otra vez a la colonia.
	var script := {0: colony, 60: town, 75: colony, 160: town}
	var worst_move := 0.0
	var worst_alpha := 0.0
	var both_visible := 0
	var samples := 0
	var cold_crowds := 0
	var waiting_for := -1
	var previous := {}
	for dot in view.drawn_dots():
		previous[dot[0]] = [dot[1], dot[2]]
	for frame in 260:
		if script.has(frame):
			view.show_node(script[frame], state)
			waiting_for = script[frame].id
		view.advance(STEP)
		# El fotograma en que el destino empieza a verse: su multitud tiene que estar completa.
		if waiting_for >= 0 and view.focus_alpha() > 0.0:
			var target: SimNode = state.get_node_by_id(waiting_for)
			if view.crowd().active_count() != params.dots_for(target.pop):
				cold_crowds += 1
			waiting_for = -1
		if view.focus_alpha() > 0.0 and view.focus_alpha() < 1.0 and view.is_transitioning():
			both_visible += 1
		var current := {}
		for dot in view.drawn_dots():
			current[dot[0]] = [dot[1], dot[2]]
		for villager in current:
			var now: Array = current[villager]
			if previous.has(villager):
				var before: Array = previous[villager]
				worst_move = maxf(worst_move, (before[0] as Vector2).distance_to(now[0]))
				worst_alpha = maxf(worst_alpha, absf(float(now[1]) - float(before[1])))
				samples += 1
			else:
				worst_alpha = maxf(worst_alpha, float(now[1]))  # aparece: desde 0
		for villager in previous:
			if not current.has(villager):
				worst_alpha = maxf(worst_alpha, float(previous[villager][1]))  # se va: hasta 0
		previous = current

	var failures := TestUtil.check(
		both_visible > 10 and samples > 5000,
		"el fundido se ha visto: %d fotogramas con las dos capas, %d muestras" % [both_visible, samples],
		"el escenario no ha llegado a fundir (%d fotogramas, %d muestras)" % [both_visible, samples])
	failures += TestUtil.check(
		worst_move <= move_limit,
		"durante el fundido nadie se teletransporta: salto máximo %.4f celdas/fotograma (tope %.4f)" % [
			worst_move, move_limit],
		"durante el fundido alguien salta %.4f celdas en un fotograma (tope %.4f)" % [
			worst_move, move_limit])
	failures += TestUtil.check(
		worst_alpha <= alpha_limit,
		"nadie aparece ni desaparece de golpe: la opacidad cambia %.4f por fotograma como mucho (tope %.4f)" % [
			worst_alpha, alpha_limit],
		"alguien aparece o desaparece de golpe: su opacidad cambia %.4f en un fotograma (tope %.4f)" % [
			worst_alpha, alpha_limit])
	failures += TestUtil.check(
		cold_crowds == 0,
		"la multitud del destino sale caliente: completa en cuanto empieza a verse",
		"%d veces el destino empezó a verse con la multitud a medias" % cold_crowds)
	failures += TestUtil.check(
		not view.is_transitioning() and view.drawn_dots().size() == view.crowd().size(),
		"al acabar no queda ninguna capa saliente: solo se dibuja la multitud del foco",
		"al acabar sigue habiendo capas salientes (%d puntos dibujados, %d del foco)" % [
			view.drawn_dots().size(), view.crowd().size()])
	failures += TestUtil.check(
		state.state_hash() == hash_before,
		"cambiar de foco y fundir no toca el estado (mismo state_hash)",
		"cambiar de foco ha cambiado el state_hash")
	view.free()
	return failures


## Puede ir con retraso, no puede mentir: el reparto de oficios en pantalla tiene que acabar
## coincidiendo con el que `Integrator` usa para producir.
func _converges_to_the_aggregate() -> int:
	var v := make_village(2468, 750)
	v.live(20.0)

	# Un vuelco brusco: se vacían las granjas y se manda a todo el mundo al bosque.
	Construction.set_workers(v.node, Content.building_index("farm"), 2.0)
	Construction.set_workers(v.node, Content.building_index("woodcutter"), v.node.pop)
	v.engine.tick(1.0)
	v.live(20.0)

	var workers := Integrator.effective_workers(v.node)
	var counts := v.crowd.job_counts()
	var worst := 0.0
	var worst_job := ""
	for bi in workers.size():
		if workers[bi] <= 0.0 and int(counts.get(bi, 0)) == 0:
			continue
		var shown := float(int(counts.get(bi, 0))) * v.crowd.represents
		var error := TestUtil.rel_error(shown, workers[bi])
		if error > worst:
			worst = error
			worst_job = Content.building(bi).name if bi >= 0 else "sin oficio"

	return TestUtil.check(
		worst < 0.15,
		"converge al agregado en 20 s tras un vuelco de oficios (desvío máx. %.1f %% en %s)" % [
			worst * 100.0, worst_job,
		],
		"la multitud no converge: %.1f %% de desvío en %s" % [worst * 100.0, worst_job]
	)


## Que suba la población no puede rebarajar el pueblo. Es el bug que motivó todo el cambio.
##
## La casa y el oficio se miden por separado **porque no significan lo mismo**. La casa no
## depende del agregado: cambiarla es rebarajar, y punto. El oficio sí, y con un punto por cada
## varios habitantes depende además de cuántos representa cada uno: al crecer la población,
## `represents` sube y el reparto de oficios se reescala aunque no se mueva un solo trabajador
## de la simulación. Ese puñado de cambios es **convergencia**, que es justo lo que se le pide a
## la multitud. Medirlos juntos, como se hacía antes, mezclaba el bug con su remedio.
func _no_reshuffle_when_population_grows() -> int:
	var v := make_village(1357, 975)
	v.live(20.0)

	var before := {}
	for villager in v.crowd.villagers:
		before[villager] = [villager.home, villager.job]
	var population_before := v.node.pop
	var represents_before := v.crowd.represents

	for _i in 6:
		v.engine.tick(25.0)
		v.live(2.0)

	var same_home := 0
	var same_job := 0
	var checked := 0
	for villager in v.crowd.villagers:
		if not before.has(villager):
			continue  # recién llegado, no cuenta
		checked += 1
		var previous: Array = before[villager]
		if villager.home == previous[0]:
			same_home += 1
		if villager.job == previous[1]:
			same_job += 1

	var failures := TestUtil.check(
		same_home == checked and checked > 20,
		"nadie se muda: los %d conservan su casa mientras la población sube de %.0f a %.0f" % [
			checked, population_before, v.node.pop,
		],
		"el pueblo se rebaraja: %d de %d han cambiado de casa" % [checked - same_home, checked]
	)

	# Un rebarajado deja el oficio al azar, que con este catálogo son dos de cada tres cambiados.
	# El margen está para el reescalado de `represents`, no para eso.
	var ratio := float(same_job) / float(maxi(checked, 1))
	failures += TestUtil.check(
		ratio >= 0.8,
		"y el oficio solo cambia lo que pide el agregado: %d de %d lo conservan (%.0f %%) " % [
			same_job, checked, ratio * 100.0,
		] + "con %.2f → %.2f habitantes por punto" % [represents_before, v.crowd.represents],
		"el oficio baila: solo %d de %d lo conservan (%.0f %%)" % [
			same_job, checked, ratio * 100.0,
		]
	)
	return failures


## Pausar detiene tu partida, no el mundo.
##
## Se mide **a media tarde, a propósito**. Antes se medía a la hora que cayera, que resultaba
## ser las tres y media de la madrugada: a esa hora el pueblo está durmiendo y «seguir vivo»
## significa justamente no moverse. El test pasaba solo porque con el paso corto quedaba gente
## volviendo a casa, y se puso en rojo al acelerar el paso —delatando que medía el rezago de
## los caminantes, no que el mundo siguiera andando—. A las 18:20 hay trasiego de verdad.
func _lives_while_paused() -> int:
	var v := make_village(99, 575)
	v.live(10.0)
	v.crowd.clock.elapsed = (float(v.crowd.clock.day() + 1) + 18.2 / 24.0) \
		* v.params.seconds_per_day
	v.live(2.0)
	v.engine.set_speed_index(0)

	var before := {}
	for villager in v.crowd.villagers:
		before[villager] = villager.position
	var cycle_before := v.engine.state.cycle

	v.live(8.0)

	var moved := 0
	for villager in v.crowd.villagers:
		if before.has(villager) and (before[villager] as Vector2).distance_to(villager.position) > 0.3:
			moved += 1

	var failures := TestUtil.check(
		moved > before.size() / 4,
		"con la simulación en pausa el pueblo sigue vivo: %d de %d se han movido" % [
			moved, before.size(),
		],
		"en pausa no se mueve nadie (%d de %d): el diorama se congela" % [moved, before.size()]
	)
	failures += TestUtil.check(
		v.engine.state.cycle == cycle_before,
		"y la economía sí está detenida (ciclo %0.f)" % cycle_before,
		"la economía ha avanzado estando en pausa"
	)
	return failures


## El paso de la gente no depende de la velocidad de simulación. La multitud ni siquiera ve
## esa velocidad — este test existe para que nadie vuelva a atarlas en el futuro.
func _pace_ignores_sim_speed() -> int:
	var slow := make_village(555, 575)
	var fast := make_village(555, 575)
	slow.engine.set_speed_index(1)
	fast.engine.set_speed_index(4)

	slow.live(10.0)
	fast.live(10.0)

	var slow_distance := _total_travel(slow, 6.0)
	var fast_distance := _total_travel(fast, 6.0)

	return TestUtil.check(
		TestUtil.rel_error(slow_distance, fast_distance) < 0.2,
		"el ritmo ignora la velocidad de juego: %.1f celdas a ×1 vs %.1f a ×8" % [
			slow_distance, fast_distance,
		],
		"la gente anda más rápido a ×8: %.1f vs %.1f celdas recorridas" % [
			slow_distance, fast_distance,
		]
	)


func _total_travel(v: Village, seconds: float) -> float:
	var start := {}
	for villager in v.crowd.villagers:
		start[villager] = villager.position
	v.live(seconds)
	var total := 0.0
	for villager in v.crowd.villagers:
		if start.has(villager):
			total += (start[villager] as Vector2).distance_to(villager.position)
	return total / float(maxi(start.size(), 1))


## Lo que el jugador **decide** sí responde al instante: construyes y el edificio está ahí.
func _new_buildings_appear_at_once() -> int:
	var v := make_village(31, 450)
	v.live(5.0)
	var before := v.layout.placements.size()

	v.node.stocks[Goods.WOOD] = 5000.0
	Construction.build(v.node, Content.building_index("hut"), 0.0, null)
	v.rebuild_layout()

	var failures := TestUtil.check(
		v.layout.placements.size() == before + 1,
		"un edificio nuevo aparece en el acto (%d → %d)" % [before, v.layout.placements.size()],
		"el edificio no aparece: %d → %d" % [before, v.layout.placements.size()]
	)

	# Y la casa nueva entra en el reparto de viviendas sin esperar.
	v.reconciler.sync(v.crowd, v.node, v.layout, v.params, STEP)
	failures += TestUtil.check(
		v.crowd.places.homes.size() == v.node.buildings[Content.building_index("hut")],
		"la cabaña nueva ya es una casa habitable (%d viviendas)" % v.crowd.places.homes.size(),
		"la cabaña nueva no ha entrado en el reparto de viviendas"
	)
	return failures


## El día tiene forma: de noche la gente duerme en casa y a media mañana está trabajando.
## Sin esto, «rutina diaria» sería solo un nombre bonito para deambular.
func _a_day_has_shape() -> int:
	var v := make_village(8080, 1125)
	v.live(15.0)

	var night := _activity_share(v, 2.0, Villager.Activity.SLEEPING)
	var morning := _activity_share(v, 10.0, Villager.Activity.WORKING)

	var failures := TestUtil.check(
		night > 0.7,
		"de madrugada duerme el %.0f %% del pueblo" % (night * 100.0),
		"de madrugada solo duerme el %.0f %%: la jornada no se nota" % (night * 100.0)
	)
	failures += TestUtil.check(
		morning > 0.4,
		"a media mañana trabaja el %.0f %% del pueblo" % (morning * 100.0),
		"a media mañana solo trabaja el %.0f %%" % (morning * 100.0)
	)
	return failures


## Adelanta el reloj del pueblo a una hora y mide qué está haciendo la gente.
func _activity_share(v: Village, hour: float, activity: int) -> float:
	var day := float(v.crowd.clock.day() + 1)
	v.crowd.clock.elapsed = (day + hour / 24.0) * v.params.seconds_per_day
	v.live(6.0)
	var matching := 0
	for villager in v.crowd.villagers:
		if villager.activity == activity:
			matching += 1
	return float(matching) / float(maxi(v.crowd.size(), 1))
