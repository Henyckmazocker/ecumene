extends SceneTree
## La analítica observa y no escribe. Ejecutar con:
##   godot-4 --headless --path . -s res://tools/analytics_test.gd
##
## El rastro del gobernador se calcula **dentro** del tick, al lado de las decisiones que
## describe. Si algo de él escribiera en el nodo —aunque fuera una caché—, encender la
## analítica cambiaría la partida. Este test es el que lo impide:
##
##   1. La misma partida delegada con el rastro apagado y encendido acaba en el mismo
##      `state_hash()`, bit a bit.
##   2. Cada acción sale con su autor: lo que construye el gobernador, `governor`; lo que se
##      construye desde fuera, `player`; lo que anota el motor, `system`.
##   3. El rastro no entra en el diario: ninguna decisión aparece en `events.entries`.
##
## Y cronometra el catch-up de un día con y sin rastro, que es donde el coste se notaría.

const TestUtil := preload("res://tools/TestUtil.gd")

const SEED := 4242
const CYCLES := 6000
const TRACE_KIND := "governor_decision"
## Repeticiones del cronometraje. Se toma la mediana: una sola medida de ~100 ms es ruido.
const TIMING_RUNS := 7
const DAY := 86400.0
## Umbral del plan. Se **informa**, no se exige: el ruido de la máquina no puede poner la suite
## en rojo. Si se pasa de forma estable, toca el plan B.
const MAX_RATIO := 1.1


func _init() -> void:
	var failures := 0

	failures += _tracing_does_not_change_the_hash()
	failures += _authorship()
	failures += _traces_stay_out_of_the_diary()
	_time_catch_up()

	TestUtil.finish(self, failures)


## Partida delegada con todos los permisos, con el log encendido como en el juego.
func _engine(tracing: bool) -> SimEngine:
	var engine := TestUtil.make_engine(SEED)
	engine.events.enabled = true
	engine.events.tracing = tracing
	var g := Governor.balanced()
	g.may_build = true
	g.may_research = true
	g.may_promote = true
	g.may_expand = true
	engine.state.root().governor = g
	return engine


func _tracing_does_not_change_the_hash() -> int:
	var off := _engine(false)
	var on := _engine(true)
	var traced := [0]
	on.events.traced.connect(func(_k, _c, _n, _d): traced[0] += 1)
	var diverged_at := -1
	for i in CYCLES:
		off.tick(1.0)
		on.tick(1.0)
		# Comprobar cada 100 ciclos dice **dónde** se rompe sin pagar un hash por ciclo.
		if i % 100 == 99 and off.state.state_hash() != on.state.state_hash():
			diverged_at = i + 1
			break
	var a := off.state.state_hash()
	var b := on.state.state_hash()
	var failures := TestUtil.check(
		diverged_at < 0 and a == b,
		"%d ciclos delegados, rastro apagado y encendido: mismo hash (%d), %d nodos, %d decisiones trazadas" % [
			CYCLES, a, on.state.nodes.size(), traced[0],
		],
		"el rastro cambia la partida: divergen hacia el ciclo %d (%d != %d)" % [diverged_at, b, a]
	)
	# Sin decisiones trazadas, la igualdad no demostraría nada.
	failures += TestUtil.check(
		traced[0] > 0,
		"el rastro encendido ha emitido decisiones",
		"el rastro encendido no ha emitido ninguna decisión: el test no prueba nada"
	)
	return failures


func _authorship() -> int:
	var failures := 0

	# Delegado: todo lo que se construye lo construye el gobernador. Se escucha la señal y no el
	# ring buffer, que solo guarda las últimas 256 entradas.
	var engine := _engine(false)
	var builds := {"governor": 0}
	var others := []
	engine.events.event_pushed.connect(func(entry: Dictionary):
		if String(entry["category"]) != "build":
			return
		var who := String(entry["actor"])
		if who == "governor":
			builds["governor"] += 1
		else:
			others.append(who))
	for _i in 2000:
		engine.tick(1.0)
	failures += TestUtil.check(
		builds["governor"] > 0 and others.is_empty(),
		"nodo delegado: los %d build salen con actor = governor" % builds["governor"],
		"nodo delegado: %d build del gobernador y %d con otro actor (%s)" % [
			builds["governor"], others.size(), others,
		]
	)
	failures += TestUtil.check(
		engine.events.actor == "player",
		"al salir del gobernador el actor vuelve a player",
		"el actor se ha quedado en %s fuera del gobernador" % engine.events.actor
	)

	# Fuera de `GovernorSys`, la misma función sale como `player`.
	# Montado a mano y no con `make_engine`, que arranca con el log apagado: así queda en el
	# diario el `world` de la fundación.
	var hand := SimEngine.new()
	hand.events.enabled = true
	hand.start(SEED)
	TestUtil._engines.append(hand)
	var node := hand.state.root()
	for i in Goods.COUNT:
		node.stocks[i] = 100000.0
	var bi: int = Content.buildings_for_tier(node.tier)[0]
	var built := Construction.build(node, bi, hand.state.cycle, hand.events)
	var last: Dictionary = hand.events.entries.back()
	failures += TestUtil.check(
		built and String(last["category"]) == "build" and String(last["actor"]) == "player",
		"Construction.build desde fuera del gobernador sale con actor = player",
		"Construction.build desde fuera sale con %s (construyó: %s)" % [last.get("actor"), built]
	)

	# Lo que anota el motor es del sistema.
	var first: Dictionary = hand.events.entries.front()
	failures += TestUtil.check(
		String(first["category"]) == "world" and String(first["actor"]) == "system",
		"fundar el mundo sale con actor = system",
		"fundar el mundo sale con %s" % first.get("actor")
	)
	var away := _engine(false)
	away.catch_up(3600.0)
	var offline: Dictionary = away.events.entries.back()
	failures += TestUtil.check(
		String(offline["category"]) == "offline" and String(offline["actor"]) == "system",
		"el anuncio de vuelta sale con actor = system",
		"el anuncio de vuelta sale como %s/%s" % [offline.get("category"), offline.get("actor")]
	)
	return failures


func _traces_stay_out_of_the_diary() -> int:
	var engine := _engine(true)
	var traced := [0]
	var leaked := [0]
	engine.events.traced.connect(func(_k, _c, _n, _d): traced[0] += 1)
	engine.events.event_pushed.connect(func(entry: Dictionary):
		if String(entry["category"]) == TRACE_KIND:
			leaked[0] += 1)
	for _i in 2000:
		engine.tick(1.0)
	for entry in engine.events.entries:
		if String((entry as Dictionary)["category"]) == TRACE_KIND:
			leaked[0] += 1
	return TestUtil.check(
		traced[0] > 0 and leaked[0] == 0,
		"%d decisiones trazadas y ninguna en el diario" % traced[0],
		"%d decisiones trazadas, %d coladas en el diario" % [traced[0], leaked[0]]
	)


## Catch-up de un día, rastro apagado contra encendido, con alguien escuchando el rastro (que
## es el caso real). Se alterna el orden para que la caché caliente no favorezca a uno.
func _time_catch_up() -> void:
	var off_times: Array[float] = []
	var on_times: Array[float] = []
	for run in TIMING_RUNS:
		if run % 2 == 0:
			off_times.append(_catch_up_msec(false))
			on_times.append(_catch_up_msec(true))
		else:
			on_times.append(_catch_up_msec(true))
			off_times.append(_catch_up_msec(false))
	var off := _median(off_times)
	var on := _median(on_times)
	var ratio := on / maxf(off, 0.001)
	print("INFO catch-up de %d s (mediana de %d): sin rastro %.1f ms, con rastro %.1f ms, ratio %.3f (umbral %.1f)" % [
		int(DAY), TIMING_RUNS, off, on, ratio, MAX_RATIO,
	])
	if ratio > MAX_RATIO:
		print("AVISO el rastro encarece el catch-up por encima de %.1f×: si se repite, plan B" % MAX_RATIO)


func _catch_up_msec(tracing: bool) -> float:
	var engine := _engine(tracing)
	var sink := [0]
	engine.events.traced.connect(func(_k, _c, _n, d: Dictionary): sink[0] += d.size())
	var t0 := Time.get_ticks_usec()
	engine.catch_up(DAY)
	return float(Time.get_ticks_usec() - t0) / 1000.0


func _median(values: Array[float]) -> float:
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]
