extends SceneTree

## Sonda del cruce de escala (M0 y M3 del plan «Vista agregada y zoom continuo»): cuánto cuesta el
## fotograma en que el foco cambia de nodo, y los que le siguen mientras se prepara y se funde.
##
##   timeout 600 env -u AUGUR_KEY godot-4 --headless --path . -s res://tools/cross_probe.gd
##
## Alterna el foco entre una raíz y un hijo (creado con `TestUtil.found_now`) cada 60 fotogramas,
## haciendo lo mismo que `Main._focus` por la API de la vista: `show_node` y el refresco del HUD y
## de la vista agregada; luego, cada fotograma, `SimEngine._process` y `SettlementView.advance`,
## que es donde se trocea la preparación del destino y corre el fundido. Dos variantes:
## - **caliente**: como cuando el jugador se aleja o se acerca con el zoom, los 30 fotogramas
##   antes del cruce se llama a `prefetch` (lo que hace `Main` con `ScaleCamera.crossing_target`);
## - **frío**: la caché se vacía justo antes de cada cruce y no hay `prefetch`.
## Mide el peor fotograma y el p99 de **todos** los fotogramas (no solo el del cruce: con la
## preparación troceada el coste se reparte entre los siguientes), y cuántos fotogramas tarda el
## destino en empezar a verse. Los primeros cruces se descartan (calentamiento). No toca el save.

const DT := 1.0 / 60.0
const PERIOD := 60
const CROSSINGS := 20
const DISCARD := 4
const PREFETCH_FRAMES := 30
const TestUtil := preload("res://tools/TestUtil.gd")

var _engine: SimEngine
var _view: SettlementView
var _hud: HUD

var _scenarios: Array = []
var _si := -1
var _frame := 0
var _nodes: Array[SimNode] = []
var _which := 0
var _results: Array[String] = []

var _cpu := PackedFloat64Array()
var _cross_frame := PackedFloat64Array()
var _latency := PackedFloat64Array()
var _waiting := -1


func _initialize() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	for tier in [Content.TOWN, Content.REGION]:
		for furnish in ["realista", "lleno"]:
			for variant in ["caliente", "frío"]:
				_scenarios.append({"root_tier": tier, "variant": variant, "furnish": furnish})


func _process(_delta: float) -> bool:
	if _si < 0 or _frame >= (CROSSINGS + 1) * PERIOD:
		if _si >= 0:
			_report()
		_si += 1
		if _si >= _scenarios.size():
			for line in _results:
				print(line)
			quit()
			return true
		_setup(_scenarios[_si])
		_frame = 0
		return false

	var sc: Dictionary = _scenarios[_si]
	var measured := _frame >= DISCARD * PERIOD
	var t0 := Time.get_ticks_usec()
	var crossing := _frame % PERIOD == 0
	if crossing:
		_which = 1 - _which
		if sc["variant"] == "frío":
			_view.clear_cache()
		_focus(_nodes[_which])
		_waiting = 0
	elif sc["variant"] == "caliente" and _frame % PERIOD >= PERIOD - PREFETCH_FRAMES:
		_view.prefetch(_nodes[1 - _which], _engine.state)
	for n in _nodes:
		for i in Goods.COUNT:
			n.stocks[i] = minf(n.stocks[i] + 500.0, 1.0e6)
	_engine._process(DT)
	for n in _nodes:
		n.pop = float(n.get_meta("probe_pop"))
	_view.advance(DT)
	var total := float(Time.get_ticks_usec() - t0) / 1000.0
	if _waiting >= 0:
		if _view.focus_alpha() > 0.0:
			if measured:
				_latency.append(_waiting)
			_waiting = -1
		else:
			_waiting += 1
	if measured:
		_cpu.append(total)
		if crossing:
			_cross_frame.append(total)
	_frame += 1
	return false


## Lo que hace `Main._focus`, sin cámara: la vista, la vista agregada y el HUD.
func _focus(node: SimNode) -> void:
	_view.show_node(node, _engine.state)
	var mods := _engine.current_modifiers()
	_view.child_map.refresh(node, _engine.state, _engine.params, mods)
	var snap := Integrator.snapshot(node, _engine.params, mods)
	_hud.refresh(node, _engine.state, _engine.params, snap, _engine.speed_index,
		_view.agent_count(), _view.represents())


func _setup(sc: Dictionary) -> void:
	if _engine != null:
		_engine.free()
		_view.free()
		_hud.free()
	_engine = SimEngine.new()
	_engine.events.enabled = false
	_engine.events.write_files = false
	root.add_child(_engine)
	_engine.start(12345)
	_view = SettlementView.new()
	root.add_child(_view)
	_hud = HUD.new()
	root.add_child(_hud)

	var state := _engine.state
	var r := state.root()
	r.tier = int(sc["root_tier"])
	r.pop = 400.0
	for i in Goods.COUNT:
		r.stocks[i] = 1.0e6
	state.refresh_totals()
	var child := TestUtil.found_now(state, r, _engine.params)
	assert(child != null)
	var full: bool = sc["furnish"] == "lleno"
	_furnish(r, 400.0, full)
	_furnish(child, 80.0, full)
	state.refresh_totals()
	_engine.set_speed_index(4)
	_nodes = [r, child]
	_which = 0
	_cpu = PackedFloat64Array()
	_cross_frame = PackedFloat64Array()
	_latency = PackedFloat64Array()
	_waiting = -1
	_view.show_node(r, state)
	_view.warm_up(12.0)


## «lleno»: 10 de cada edificio de su escala y 100 cabañas (como `frame_probe`, que pone 200).
## «realista»: 2 de cada y las cabañas justas para la población (+10 %).
func _furnish(node: SimNode, pop: float, full: bool) -> void:
	for _round in (10 if full else 2):
		for i in Goods.COUNT:
			node.stocks[i] = 1.0e9
		for bi in Content.buildings_for_tier(node.tier):
			Construction.build(node, bi, _engine.state.cycle, _engine.events)
	var hut := Content.building_index("hut")
	var huts := 100 if full else int(ceil(pop * 1.1 / 5.0))
	for _i in huts:
		for i in Goods.COUNT:
			node.stocks[i] = 1.0e9
		Construction.build(node, hut, _engine.state.cycle, _engine.events)
	for i in Goods.COUNT:
		node.stocks[i] = 1.0e6
	node.pop = pop
	node.set_meta("probe_pop", pop)
	var workplaces := 0
	for bi in node.buildings.size():
		if node.buildings[bi] > 0 and Content.building(bi).is_workplace():
			workplaces += 1
	for bi in node.buildings.size():
		node.jobs[bi] = 0.0
		if node.buildings[bi] > 0 and Content.building(bi).is_workplace():
			node.jobs[bi] = pop * 0.8 / float(workplaces)


func _pct(arr: PackedFloat64Array, q: float) -> float:
	if arr.is_empty():
		return -1.0
	var s := arr.duplicate()
	s.sort()
	return s[clampi(int(s.size() * q), 0, s.size() - 1)]


func _report() -> void:
	var sc: Dictionary = _scenarios[_si]
	var r := _nodes[0]
	var c := _nodes[1]
	var over := 0
	for f in _cpu:
		if f > 16.0:
			over += 1
	_results.append("\n=== T%d (%d edificios) ⇄ T%d (%d edificios) · %s · %s · %d cruces medidos ===" % [
		r.tier, r.building_total(), c.tier, c.building_total(), sc["furnish"], sc["variant"],
		_cross_frame.size()])
	_results.append("  todos los fotogramas: peor %.2f ms · p99 %.2f · mediana %.2f · %d por encima de 16 ms" % [
		_pct(_cpu, 1.0), _pct(_cpu, 0.99), _pct(_cpu, 0.5), over])
	_results.append("  fotograma del cruce: peor %.2f ms · mediana %.2f" % [
		_pct(_cross_frame, 1.0), _pct(_cross_frame, 0.5)])
	_results.append("  fotogramas hasta que el destino empieza a verse: mediana %d · peor %d" % [
		int(_pct(_latency, 0.5)), int(_pct(_latency, 1.0))])
