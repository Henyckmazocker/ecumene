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
