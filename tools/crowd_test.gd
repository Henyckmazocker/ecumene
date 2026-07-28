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
			reconciler.sync(crowd, node, layout, terrain.center(), params, STEP)
			crowd.advance(STEP, params)


static func make_village(seed_value: int, cycles: float, delegate: bool = true) -> Village:
	var v := Village.new()
	v.engine = TestUtil.make_engine(seed_value)
	v.node = v.engine.state.root()
	if delegate:
		v.node.governor = Governor.balanced()
	var step := 25.0
	for _i in int(cycles / step):
		v.engine.tick(step)
	v.terrain = TerrainGen.generate(v.node.seed, v.node.tier)
	v.crowd = Crowd.new(v.node.seed)
	v.rebuild_layout()
	return v


func _init() -> void:
	var failures := 0
	failures += _view_never_writes_state()
	failures += _nobody_teleports()
	failures += _converges_to_the_aggregate()
	failures += _no_reshuffle_when_population_grows()
	failures += _lives_while_paused()
	failures += _pace_ignores_sim_speed()
	failures += _new_buildings_appear_at_once()
	failures += _a_day_has_shape()
	TestUtil.finish(self, failures)


## El invariante de siempre, y el único que no ha cambiado: la vista no es autoritativa.
func _view_never_writes_state() -> int:
	var v := make_village(4321, 1000)
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
	var v := make_village(777, 800)
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
		v.reconciler.sync(v.crowd, v.node, v.layout, v.terrain.center(), v.params, STEP)
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


## Puede ir con retraso, no puede mentir: el reparto de oficios en pantalla tiene que acabar
## coincidiendo con el que `Integrator` usa para producir.
func _converges_to_the_aggregate() -> int:
	var v := make_village(2468, 1200)
	v.live(20.0)

	# Un vuelco brusco: todo el mundo al bosque.
	Construction.set_job_weight(v.node, Content.building_index("farm"), 0.2)
	Construction.set_job_weight(v.node, Content.building_index("woodcutter"), 3.0)
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
func _no_reshuffle_when_population_grows() -> int:
	var v := make_village(1357, 1500)
	v.live(20.0)

	var before := {}
	for villager in v.crowd.villagers:
		before[villager] = [villager.home, villager.job]
	var population_before := v.node.pop

	for _i in 6:
		v.engine.tick(25.0)
		v.live(2.0)

	var kept := 0
	var checked := 0
	for villager in v.crowd.villagers:
		if not before.has(villager):
			continue  # recién llegado, no cuenta
		checked += 1
		var previous: Array = before[villager]
		if villager.home == previous[0] and villager.job == previous[1]:
			kept += 1

	var ratio := float(kept) / float(maxi(checked, 1))
	return TestUtil.check(
		ratio >= 0.9 and checked > 20,
		"sin rebarajado: %d de %d conservan casa y oficio (%.0f %%) mientras la población " % [
			kept, checked, ratio * 100.0,
		] + "sube de %.0f a %.0f" % [population_before, v.node.pop],
		"el pueblo se rebaraja: solo %d de %d conservan casa y oficio (%.0f %%)" % [
			kept, checked, ratio * 100.0,
		]
	)


## Pausar detiene tu partida, no el mundo.
func _lives_while_paused() -> int:
	var v := make_village(99, 900)
	v.live(10.0)
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
	var slow := make_village(555, 900)
	var fast := make_village(555, 900)
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
	var v := make_village(31, 700)
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
	v.reconciler.sync(v.crowd, v.node, v.layout, v.terrain.center(), v.params, STEP)
	failures += TestUtil.check(
		v.crowd.places.homes.size() == v.node.buildings[Content.building_index("hut")],
		"la cabaña nueva ya es una casa habitable (%d viviendas)" % v.crowd.places.homes.size(),
		"la cabaña nueva no ha entrado en el reparto de viviendas"
	)
	return failures


## El día tiene forma: de noche la gente duerme en casa y a media mañana está trabajando.
## Sin esto, «rutina diaria» sería solo un nombre bonito para deambular.
func _a_day_has_shape() -> int:
	var v := make_village(8080, 1600)
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
