extends SceneTree

## Perfil de fotograma del bucle real: `SimEngine._process` + `SettlementView.advance` + el
## refresco del HUD que cuelga de `cycle_advanced`, tal y como los encadena `Main`.
##
##   godot-4 --headless --path . -s res://tools/frame_probe.gd
##
## No mide medias: mide **la cola**. Un pico es un fotograma raro y caro, y una media de 30
## muestras lo esconde. Aquí sale el peor fotograma, el percentil 99 y qué se estaba haciendo
## en él.

const FRAMES := 1200
const DT := 1.0 / 60.0
const SPEED := 4  ## índice de `SimParams.speeds`: ×8
const POPS := [80, 400]

var _engine: SimEngine
var _view: SettlementView
var _hud: HUD
var _done := false

var _cycles_this_frame := 0
var _hud_usec := 0.0


func _initialize() -> void:
	_engine = SimEngine.new()
	root.add_child(_engine)
	_engine.start(12345)
	_view = SettlementView.new()
	root.add_child(_view)
	_hud = HUD.new()
	root.add_child(_hud)


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
	# Alojamiento de sobra: sin él la población se cae al techo en dos ciclos y la medida de
	# «pueblo grande» acaba midiendo un pueblo pequeño.
	var hut := Content.building_index("hut")
	for _i in 200:
		for i in Goods.COUNT:
			node.stocks[i] = 1.0e9
		Construction.build(node, hut, _engine.state.cycle, _engine.events)
	_engine.set_speed_index(SPEED)
	_engine.cycle_advanced.connect(_on_cycle_advanced)

	for pop in POPS:
		_seed_pop(node, float(pop))
		_view.show_node(node, _engine.state)
		_view.refresh(node)
		_view.warm_up(4.0)
		_profile(node, int(pop))

	quit()


func _seed_pop(node: SimNode, pop: float) -> void:
	node.pop = pop
	var workplaces := 0
	for bi in node.buildings.size():
		if node.buildings[bi] > 0 and Content.building(bi).is_workplace():
			workplaces += 1
	for bi in node.buildings.size():
		node.jobs[bi] = 0.0
		if node.buildings[bi] > 0 and Content.building(bi).is_workplace():
			node.jobs[bi] = pop * 0.8 / float(workplaces)


func _profile(node: SimNode, pop: int) -> void:
	var frames := PackedFloat64Array()
	var crowd_usec := 0.0
	var hud_total := 0.0
	var worst := {"total": 0.0, "hud": 0.0, "crowd": 0.0, "cycles": 0, "frame": 0}

	for _f in FRAMES:
		# Los stocks se rellenan para que el pueblo no colapse durante la medida y para que las
		# mejoras sigan estando a tiro: es el caso caro del árbol.
		for i in Goods.COUNT:
			node.stocks[i] = minf(node.stocks[i] + 500.0, 1.0e6)
		# La población se sujeta a pulso: lo que se mide es el coste de dibujar y reconciliar un
		# pueblo de este tamaño, no cuánto tarda en caerse al techo de comida.
		node.pop = float(pop)
		_cycles_this_frame = 0
		_hud_usec = 0.0

		var t0 := Time.get_ticks_usec()
		_engine._process(DT)
		var t1 := Time.get_ticks_usec()
		_view.advance(DT)
		var t2 := Time.get_ticks_usec()

		var total := float(t2 - t0) / 1000.0
		crowd_usec += float(t2 - t1)
		hud_total += _hud_usec
		frames.append(total)
		if total > float(worst["total"]):
			worst = {
				"total": total,
				"hud": _hud_usec / 1000.0,
				"crowd": float(t2 - t1) / 1000.0,
				"cycles": _cycles_this_frame,
				"frame": _f,
			}

	var sorted := frames.duplicate()
	sorted.sort()
	print("\n=== pop %d · %d puntos · ×%d · %d fotogramas ===" % [
		pop, _view.agent_count(), int(_engine.speed()), FRAMES])
	print("mediana %.2f ms · p95 %.2f · p99 %.2f · máximo %.2f" % [
		sorted[int(FRAMES * 0.5)], sorted[int(FRAMES * 0.95)], sorted[int(FRAMES * 0.99)],
		sorted[FRAMES - 1]])
	print("  multitud (cada fotograma)  %.3f ms de media" % (crowd_usec / FRAMES / 1000.0))
	print("  HUD (solo al pasar ciclo)  %.3f ms de media por fotograma" % (
		hud_total / FRAMES / 1000.0))
	print("  peor fotograma: el %d, %.2f ms — HUD %.2f · multitud %.2f · %d ciclos" % [
		worst["frame"], worst["total"], worst["hud"], worst["crowd"], worst["cycles"]])

	var over := 0
	for f in frames:
		if f > 16.6:
			over += 1
	print("  fotogramas por encima de 16.6 ms: %d" % over)
	var crowd := _view.crowd()
	var departing := 0
	for v in crowd.villagers:
		if v.departing:
			departing += 1
	print("  multitud: %d en total, %d activos, %d marchándose · representa %.2f" % [
		crowd.size(), crowd.active_count(), departing, crowd.represents])


func _on_cycle_advanced(_cycle: float) -> void:
	_cycles_this_frame += 1
	var node := _engine.state.root()
	var t := Time.get_ticks_usec()
	_view.refresh(node)
	var snap := Integrator.snapshot(node, _engine.params, _engine.current_modifiers())
	_hud.refresh(node, _engine.state, _engine.params, snap, _engine.speed_index,
		_view.agent_count(), _view.represents())
	_hud_usec += float(Time.get_ticks_usec() - t)
