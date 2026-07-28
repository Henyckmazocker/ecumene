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


## El catch-up recorta por el tope de horas y aplica la penalización de eficiencia.
func _cap_and_efficiency() -> int:
	var failures := 0

	var capped := TestUtil.make_engine(11)
	var cap_cycles := capped.params.offline_cap_seconds / capped.params.seconds_per_cycle
	var credited := capped.catch_up(capped.params.offline_cap_seconds * 10.0)
	failures += TestUtil.check(
		absf(credited - cap_cycles) < 1.0,
		"tope offline: 10× el máximo se recorta a %0.f ciclos" % credited,
		"el tope offline no recorta: %0.f ciclos acreditados" % credited
	)

	# Con eficiencia offline al 50 %, la producción tiene que quedarse corta frente al online.
	# Se mide antes de que el almacén se llene: con los stocks a tope los dos dan lo mismo.
	var online := TestUtil.make_engine(11)
	var offline := TestUtil.make_engine(11)
	online.tick(100.0, false)
	offline.tick(100.0, true)
	var on_wood := online.state.root().stocks[Goods.WOOD]
	var off_wood := offline.state.root().stocks[Goods.WOOD]
	failures += TestUtil.check(
		off_wood < on_wood,
		"penalización offline aplicada: madera %0.1f offline vs %0.1f online" % [off_wood, on_wood],
		"la penalización offline no se aplica: %0.1f vs %0.1f" % [off_wood, on_wood]
	)
	return failures
