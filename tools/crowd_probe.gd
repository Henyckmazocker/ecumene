extends SceneTree

## Sonda de la multitud: cuánto cuesta un fotograma de pueblo según cuánta gente hay.
##
##   godot-4 --headless --path . -s res://tools/crowd_probe.gd
##
## No afirma nada, solo mide. Separa las tres piezas de `SettlementView.advance` —reconciliar,
## vivir y dibujar— y además cronometra el **peor caso**: el rellenado de golpe, que es el que
## se lleva un fotograma entero cuando el pueblo pega un salto.

const POPS := [50, 100, 200, 400, 800]
const FRAMES := 120

var _engine: SimEngine
var _done := false


func _initialize() -> void:
	_engine = SimEngine.new()
	root.add_child(_engine)
	_engine.start(12345)


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	_run()
	return true


func _run() -> void:
	var node := _engine.state.root()
	for _i in 200:
		_engine.tick(1.0)
	for _round in 10:
		for i in Goods.COUNT:
			node.stocks[i] = 1.0e9
		for bi in Content.buildings_for_tier(node.tier):
			Construction.build(node, bi, _engine.state.cycle, _engine.events)
	for i in Goods.COUNT:
		node.stocks[i] = 1.0e9
	_engine.tick(1.0)

	print("edificios=%d" % node.building_total())
	print("%6s %8s %9s %9s %9s %9s" % [
		"pop", "puntos", "bulk", "sync", "advance", "draw"])

	for pop in POPS:
		_measure(node, float(pop))

	quit()


func _measure(node: SimNode, pop: float) -> void:
	node.pop = pop
	# Repartir la población entre todos los oficios que existan: es el caso caro del
	# reconciliador, que tiene que casar el reparto punto a punto.
	var jobs := 0
	for bi in node.buildings.size():
		if node.buildings[bi] > 0 and Content.building(bi).is_workplace():
			jobs += 1
	for bi in node.buildings.size():
		node.jobs[bi] = 0.0
		if node.buildings[bi] > 0 and Content.building(bi).is_workplace():
			node.jobs[bi] = pop * 0.8 / float(jobs)

	var view := SettlementView.new()
	root.add_child(view)
	view.show_node(node)
	view.refresh(node)

	var t0 := Time.get_ticks_usec()
	view.advance(0.016)
	var bulk := float(Time.get_ticks_usec() - t0) / 1000.0

	# Unos segundos de vida para que la gente se reparta por el pueblo antes de medir.
	for _i in 200:
		view.advance(0.016)

	var sync_us := 0.0
	var advance_us := 0.0
	var draw_us := 0.0
	var crowd := view.crowd()
	for _i in FRAMES:
		var t := Time.get_ticks_usec()
		view._reconciler.sync(crowd, node, view.layout, view.crowd_params, 0.016)
		sync_us += float(Time.get_ticks_usec() - t)
		t = Time.get_ticks_usec()
		crowd.advance(0.016, view.crowd_params)
		advance_us += float(Time.get_ticks_usec() - t)
		t = Time.get_ticks_usec()
		view._draw_crowd()
		draw_us += float(Time.get_ticks_usec() - t)

	print("%6d %8d %9.3f %9.3f %9.3f %9.3f" % [
		int(pop), view.agent_count(), bulk,
		sync_us / FRAMES / 1000.0, advance_us / FRAMES / 1000.0, draw_us / FRAMES / 1000.0])

	view.queue_free()
	root.remove_child(view)
