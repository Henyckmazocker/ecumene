extends SceneTree
## Las migas de pan del HUD (M4 del plan de vista agregada). Ejecutar con:
##   godot-4 --headless --path . -s res://tools/crumbs_test.gd
##
## Comprueba que:
## - la cadena es la del nodo enfocado, de la raíz a él, y el eslabón activo va resaltado;
## - pulsar un ancestro pide ese nodo por `focus_requested` (la ruta de `Main._focus`), y pulsar el
##   enfocado no pide nada;
## - refrescar sin cambiar de foco no reconstruye nada, y una promoción sí actualiza el eslabón;
## - si no cabe a lo ancho se recorta por la izquierda con «… ›», y el padre y el enfocado se ven.

const TestUtil := preload("res://tools/TestUtil.gd")

var _requested: Array[int] = []


func _initialize() -> void:
	var engine := TestUtil.make_engine(4242)
	var state := engine.state
	var hud := HUD.new()
	root.add_child(hud)
	await process_frame
	hud.focus_requested.connect(func(id: int) -> void: _requested.append(id))

	# Raíz › hijo › nieto › bisnieto › tataranieto: más hondo de lo que cabe en un dock estrecho.
	var chain: Array[SimNode] = [state.root()]
	for _i in 4:
		chain.append(state.add_node(chain[-1].tier, chain[-1].id))
	var failures := 0

	# --- La cadena y el resaltado ---
	var focus: SimNode = chain[2]
	_refresh(hud, engine, focus)
	await process_frame
	var expected := " › ".join(PackedStringArray([chain[0].name, chain[1].name, chain[2].name]))
	failures += TestUtil.check(hud.crumbs_text() == expected,
		"la cadena es la del foco, de la raíz a él: %s" % expected,
		"migas «%s», se esperaba «%s»" % [hud.crumbs_text(), expected])
	var active := hud.crumb_button(2)
	var ancestor := hud.crumb_button(0)
	failures += TestUtil.check(
		active.modulate == HUD.CRUMB_ACTIVE_COLOR and ancestor.modulate == HUD.CRUMB_COLOR
			and hud.crumb_button(3) == null,
		"el eslabón activo se resalta con `modulate` y los ancestros no",
		"modulate activo %s, ancestro %s" % [active.modulate, ancestor.modulate])

	# --- Pulsar ---
	_requested.clear()
	ancestor.pressed.emit()
	hud.crumb_button(1).pressed.emit()
	active.pressed.emit()
	failures += TestUtil.check(_requested == [chain[0].id, chain[1].id],
		"pulsar un ancestro pide ese nodo, y pulsar el enfocado no pide nada",
		"pulsar raíz, padre y enfocado pidió %s" % [_requested])

	# --- Solo se reconstruye cuando cambia la cadena ---
	var children_before := hud._crumbs.get_child_count()
	active.text = "centinela"
	_refresh(hud, engine, focus)
	failures += TestUtil.check(active.text == "centinela",
		"refrescar sin cambiar de foco no toca las migas",
		"un refresco con el mismo foco ha reescrito el eslabón activo")
	chain[1].tier += 1
	_refresh(hud, engine, focus)
	failures += TestUtil.check(
		hud.crumb_button(1).tooltip_text == chain[1].def().name
			and active.text == chain[2].name,
		"si un ancestro cambia de escala, su eslabón se actualiza (%s)" % chain[1].def().name,
		"tras promocionar al padre: tooltip «%s», activo «%s»" % [
			hud.crumb_button(1).tooltip_text, active.text])
	chain[1].tier -= 1

	# Volver a la raíz y bajar otra vez reutiliza los mismos botones: ni uno nuevo en el árbol.
	_refresh(hud, engine, chain[0])
	var root_text := hud.crumbs_text()
	_refresh(hud, engine, chain[2])
	failures += TestUtil.check(
		root_text == chain[0].name and hud._crumbs.get_child_count() == children_before
			and hud.crumb_button(2) == active,
		"subir a la raíz deja un solo eslabón, y volver a bajar reutiliza los botones",
		"en la raíz «%s»; hijos de la fila %d → %d" % [
			root_text, children_before, hud._crumbs.get_child_count()])

	# --- Recorte por la izquierda ---
	var deepest: SimNode = chain[4]
	_refresh(hud, engine, deepest)
	var tight: float = float(hud._crumb_links[3][2]) + float(hud._crumb_links[4][2]) \
		+ hud._crumbs_more.get_combined_minimum_size().x + 8.0
	hud._crumbs_clip.size = Vector2(tight, hud._crumbs_clip.size.y)
	hud._fit_crumbs()
	var cut := " › ".join(PackedStringArray(["…", chain[3].name, chain[4].name]))
	failures += TestUtil.check(hud.crumbs_text() == cut,
		"sin sitio se recorta por la izquierda y quedan el padre y el enfocado: %s" % cut,
		"con %.0f px las migas son «%s», se esperaba «%s»" % [tight, hud.crumbs_text(), cut])
	hud._crumbs_clip.size = Vector2(4000.0, hud._crumbs_clip.size.y)
	hud._fit_crumbs()
	failures += TestUtil.check(not hud.crumbs_text().begins_with("…")
			and hud.crumbs_text().begins_with(chain[0].name),
		"con sitio de sobra se ve la cadena entera",
		"con 4000 px las migas son «%s»" % hud.crumbs_text())

	TestUtil.finish(self, failures)


func _refresh(hud: HUD, engine: SimEngine, node: SimNode) -> void:
	var snap := Integrator.snapshot(node, engine.params, engine.current_modifiers())
	hud.refresh(node, engine.state, engine.params, snap, engine.speed_index, 0, 1.0)
