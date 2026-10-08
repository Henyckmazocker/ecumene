extends SceneTree

## Sonda de picos: cronometra por separado lo que se hace **una vez por ciclo** en
## `Main._on_cycle_advanced`, y lo que se hace **cada fotograma** en `Main._process`.
##
##   godot-4 --headless --path . -s res://tools/spike_probe.gd
##
## No es un test: no afirma nada, solo mide. Vive en `tools/` porque el snap de Godot no lee
## `/tmp` y porque el HUD necesita un árbol de escena de verdad. Se mide en el primer
## fotograma, no en `_initialize`: los nodos añadidos ahí no han pasado por `_ready` todavía.

const SAMPLES := 30
const WARM_CYCLES := 400
## Población forzada: es lo que hace que se midan las rutas que escalan con la multitud.
const POP := 400

var _engine: SimEngine
var _view: SettlementView
var _hud: HUD
var _done := false


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
	# Un pueblo con cosas dentro: el coste del refresco depende de cuántos edificios, oficios y
	# mejoras hay a la vista. Se construye a pulso, con almacén infinito, para llegar a un HUD
	# lleno sin esperar media hora de simulación.
	for _i in WARM_CYCLES:
		_engine.tick(1.0)
	for _round in 12:
		for i in Goods.COUNT:
			node.stocks[i] = 1.0e9
		for bi in Content.buildings_for_tier(node.tier):
			Construction.build(node, bi, _engine.state.cycle, _engine.events)
	for i in Goods.COUNT:
		node.stocks[i] = 1.0e9
	# Un pueblo **poblado**: sin destinar a nadie no crece (regla 3), y con siete habitantes no
	# se mide nada de lo que escala con la multitud.
	node.pop = float(POP)
	var workplaces := 0
	for bi in node.buildings.size():
		if node.buildings[bi] > 0 and Content.building(bi).is_workplace():
			workplaces += 1
	for bi in node.buildings.size():
		node.jobs[bi] = 0.0
		if node.buildings[bi] > 0 and Content.building(bi).is_workplace():
			node.jobs[bi] = node.pop * 0.8 / float(workplaces)
	_engine.tick(1.0)

	_view.show_node(node, _engine.state)
	_view.refresh(node)
	_view.warm_up(4.0)

	var built := 0
	for bi in node.buildings.size():
		built += node.buildings[bi]
	print("pop=%.1f  edificios=%d  gente dibujada=%d  botones de árbol=%d" % [
		node.pop, built, _view.agent_count(), _tree_buttons()])

	var acc := {}
	var order := PackedStringArray()
	for _s in SAMPLES:
		_engine.tick(1.0)
		var snap := Integrator.snapshot(node, _engine.params, _engine.current_modifiers())

		_time(acc, order, "engine.tick(1)", func() -> void: _engine.tick(1.0))
		_time(acc, order, "Integrator.snapshot", func() -> void:
			Integrator.snapshot(node, _engine.params, _engine.current_modifiers()))
		_time(acc, order, "view.refresh", func() -> void: _view.refresh(node))
		_time(acc, order, "view.advance (frame)", func() -> void: _view.advance(0.016))
		_time(acc, order, "hud.refresh TOTAL", func() -> void:
			_hud.refresh(node, _engine.state, _engine.params, snap, 1, _view.agent_count(),
				_view.represents()))
		_time(acc, order, "  _refresh_resources", func() -> void:
			_hud._refresh_resources(node, _engine.params, snap))
		_time(acc, order, "  _refresh_promotion", func() -> void:
			_hud._refresh_promotion(node, _engine.state))
		_time(acc, order, "  _refresh_upgrades", func() -> void: _hud._refresh_upgrades(node))
		_time(acc, order, "  _refresh_legacy", func() -> void:
			_hud._refresh_legacy(_engine.state))
		_time(acc, order, "  _refresh_jobs", func() -> void:
			_hud._refresh_jobs(node, _engine.params))
		_time(acc, order, "  _refresh_builds", func() -> void: _hud._refresh_builds(node))
		_time(acc, order, "Save.write", func() -> void: Save.write(_engine.state))

	print("\n--- media de %d muestras (ms) ---" % SAMPLES)
	for key in order:
		print("%-24s %8.3f" % [key, float(acc[key]) / float(SAMPLES) / 1000.0])

	_switch(node)
	_churn(node)
	_dissect(node)
	quit()


## Cambiar de foco: el HUD pasa a gestionar otro nodo. Es la ruta de `Main._focus` y la de las migas
## de pan, que se reconstruyen solo aquí. Raíz ⇄ nieto (tres eslabones) frente al mismo foco.
func _switch(node: SimNode) -> void:
	var state := _engine.state
	var child := state.add_node(node.tier, node.id)
	var grandchild := state.add_node(node.tier, child.id)
	var acc := {}
	var order := PackedStringArray()
	var nodes: Array[SimNode] = [node, grandchild]
	for s in SAMPLES * 2:
		var target: SimNode = nodes[s % 2]
		var snap := Integrator.snapshot(target, _engine.params, _engine.current_modifiers())
		_time(acc, order, "cambio de foco", func() -> void:
			_hud.refresh(target, state, _engine.params, snap, 1, _view.agent_count(),
				_view.represents()))
		_time(acc, order, "mismo foco", func() -> void:
			_hud.refresh(target, state, _engine.params, snap, 1, _view.agent_count(),
				_view.represents()))
	print("\n--- hud.refresh al cambiar de foco, media de %d muestras (ms) ---" % (SAMPLES * 2))
	for key in order:
		print("%-24s %8.3f" % [key, float(acc[key]) / float(SAMPLES * 2) / 1000.0])
	state.nodes.erase(grandchild.id)
	state.nodes.erase(child.id)
	node.children.erase(child.id)


## La ruta de cambio, que es la que no arregla saltarse el repintado: comprar una mejora baja los
## recursos y apaga varios nodos **a la vez**, así que el peor caso es un refresco en el que todos
## los nodos cambian de aspecto, y cae justo al pulsar.
func _churn(node: SimNode) -> void:
	var tree: UpgradeTreeView = _hud._upgrade_tree
	var on := _items_for(node, true)
	var off := _items_for(node, false)
	var acc := {}
	var order := PackedStringArray()
	for _s in SAMPLES:
		tree.set_items(on)  # sin cronometrar: deja el árbol en un estado conocido
		_time(acc, order, "nada cambia", func() -> void: tree.set_items(on))
		_time(acc, order, "todo cambia", func() -> void: tree.set_items(off))

	print("\n--- refrescar el árbol (%d nodos), media de %d muestras (ms) ---" % [
		on.size(), SAMPLES])
	for key in order:
		print("%-24s %8.3f" % [key, float(acc[key]) / float(SAMPLES) / 1000.0])


static func _items_for(node: SimNode, enabled: bool) -> Array:
	var items := []
	for def in Upgrading.tree_for(node):
		var d: Upgrades.Def = def
		items.append(UpgradeTreeView.Item.make(d.id, d.icon, d.name, "x", d.describe(),
			d.requires, UpgradeTreeView.State.AVAILABLE, enabled,
			Content.tier(d.tier_min).name))
	return items


## El árbol de mejoras por dentro: qué parte de `set_items` se lleva el tiempo.
func _dissect(node: SimNode) -> void:
	var tree: UpgradeTreeView = _hud._upgrade_tree
	var buttons: Array = tree._buttons.values()
	var one: Button = buttons[0]
	var acc := {}
	var order := PackedStringArray()
	var _themes: Array[Theme] = [Theme.new(), Theme.new()]
	_themes[0].set_font_size("font_size", "Button", 11)
	_themes[1].set_font_size("font_size", "Button", 12)

	for s in SAMPLES:
		# Alternando la variante a propósito: `Control.set_theme` sale antes si le das el que ya
		# tenía, así que repitiendo el mismo se cronometraría un no-op.
		var flip := s % 2 == 0
		_time(acc, order, "items[] (datos)", func() -> void:
			var items := []
			for def in Upgrading.tree_for(node):
				var d: Upgrades.Def = def
				items.append(UpgradeTreeView.Item.make(d.id, d.icon, d.name, "x",
					d.describe(), d.requires, 1,
					Upgrading.can_buy(node, d.id), Content.tier(d.tier_min).name))
			)
		_time(acc, order, "tree._rows()", func() -> void: tree._rows())
		_time(acc, order, "tree._relayout()", func() -> void: tree._relayout())
		_time(acc, order, "1× modulate (lo de ahora)", func() -> void:
			one.modulate = UpgradeTreeView._text_color(UpgradeTreeView.State.AVAILABLE, flip))
		# Lo que se hacía antes, para que la comparación siga a la vista: dos temas distintos
		# alternándose, porque `Control.set_theme` sale antes si le das el que ya tenía.
		_time(acc, order, "1× theme= (lo de antes)", func() -> void:
			one.theme = _themes[int(flip)])
		_time(acc, order, "1× stylebox_override", func() -> void:
			one.add_theme_stylebox_override("normal", StyleBoxFlat.new()))
		_time(acc, order, "1× color_override", func() -> void:
			one.add_theme_color_override("font_color", Color.WHITE))
		_time(acc, order, "1× button.text=", func() -> void:
			one.text = "✓ 🏛️\nAlgo largo aquí\n120 🪵 80 🪨")
		_time(acc, order, "1× button.text= (igual)", func() -> void:
			one.text = "✓ 🏛️\nAlgo largo aquí\n120 🪵 80 🪨")

	print("\n--- por dentro (%d botones), media de %d muestras (ms) ---" % [
		buttons.size(), SAMPLES])
	for key in order:
		print("%-24s %8.3f" % [key, float(acc[key]) / float(SAMPLES) / 1000.0])

	# ¿Es el emoji, es estar dentro del árbol, o es el override en sí?
	#
	# «3 líneas sin emoji» está para no confundir las dos cosas: el botón con emoji tiene además
	# tres líneas, así que sin esta fila no se sabe si lo caro es resolver la fuente de reserva del
	# emoji o simplemente re-conformar tres líneas de texto.
	var acc2 := {}
	var order2 := PackedStringArray()
	var loose := Button.new()
	loose.text = "Plano sin emoji"
	var loose_emoji := Button.new()
	loose_emoji.text = "✓ 🏛️\nCon emoji\n120 🪵"
	var in_tree := Button.new()
	in_tree.text = "Plano sin emoji"
	root.add_child(in_tree)
	var in_tree_lines := Button.new()
	in_tree_lines.text = "Marca\nSin emoji, tres lineas\n120 madera"
	root.add_child(in_tree_lines)
	var in_tree_emoji := Button.new()
	in_tree_emoji.text = "✓ 🏛️\nCon emoji\n120 🪵"
	root.add_child(in_tree_emoji)
	for _s in SAMPLES:
		_time(acc2, order2, "suelto, sin emoji", func() -> void:
			loose.add_theme_color_override("font_color", Color.WHITE))
		_time(acc2, order2, "suelto, con emoji", func() -> void:
			loose_emoji.add_theme_color_override("font_color", Color.WHITE))
		_time(acc2, order2, "en árbol, sin emoji", func() -> void:
			in_tree.add_theme_color_override("font_color", Color.WHITE))
		_time(acc2, order2, "en árbol, 3 líneas", func() -> void:
			in_tree_lines.add_theme_color_override("font_color", Color.WHITE))
		_time(acc2, order2, "en árbol, con emoji", func() -> void:
			in_tree_emoji.add_theme_color_override("font_color", Color.WHITE))
		_time(acc2, order2, "nodo del árbol (dock)", func() -> void:
			one.add_theme_color_override("font_color", Color.WHITE))
	print("\n--- coste de UN override, media de %d muestras (ms) ---" % SAMPLES)
	for key in order2:
		print("%-24s %8.3f" % [key, float(acc2[key]) / float(SAMPLES) / 1000.0])


func _tree_buttons() -> int:
	var n := 0
	for child in _hud.find_children("*", "Button", true, false):
		n += 1
	return n


func _time(acc: Dictionary, order: PackedStringArray, key: String, fn: Callable) -> void:
	if not acc.has(key):
		order.append(key)
	var t0 := Time.get_ticks_usec()
	fn.call()
	acc[key] = float(acc.get(key, 0.0)) + float(Time.get_ticks_usec() - t0)
