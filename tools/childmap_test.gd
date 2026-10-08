extends SceneTree
## La vista agregada, sin pantalla: `ChildMapRenderer` sobre un estado de prueba. Ejecutar con:
##   godot-4 --headless --path . -s res://tools/childmap_test.gd
##
## Comprueba lo que sostiene M2 del plan «Vista agregada y zoom continuo»:
## - el picking: el centro de cada mancha devuelve su hijo, y un punto vacío, -1;
## - la mancha cae en `world_pos_of(hijo) − world_pos_of(padre)`, en píxeles de la vista;
## - la expedición viaja hacia donde **de verdad** nacerá la colonia (`predicted_child_pos` ==
##   `world_pos_of` tras la llegada), y a mitad de viaje está a mitad de camino;
## - pintar no escribe: el `state_hash` es el mismo antes y después;
## - la regla de visibilidad (`alpha_at`, `shows_at`): un fundido continuo desde M3;
## - M3c: la mancha a la que está anclado el zoom no se desvanece aunque las demás sí, `blob_of`
##   da su sitio y su radio, y al entrar queda de fantasma en el origen hasta que se enciende el hijo.

const TestUtil := preload("res://tools/TestUtil.gd")


func _initialize() -> void:
	var failures := 0
	var engine := TestUtil.make_engine(4242)
	var state := engine.state
	var town := state.root()
	town.tier = Content.TOWN
	# Fundar se lleva colonos y comida: se repone antes de cada una para que el escenario no
	# dependa de cuánto da de sí el pueblo.
	var refill := func() -> void:
		town.pop = 500.0
		town.stocks[Goods.FOOD] = 500.0
		state.refresh_totals()
	refill.call()
	engine.tick(7.0)
	refill.call()
	var a := TestUtil.found_now(state, town, engine.params)
	refill.call()
	var b := TestUtil.found_now(state, town, engine.params)
	refill.call()
	failures += TestUtil.check(a != null and b != null, "dos hijos fundados para el escenario",
		"no se pudieron fundar los hijos del escenario")
	if a == null or b == null:
		TestUtil.finish(self, failures)
		return

	# Una expedición en camino, a mitad de viaje.
	var sent := Promotion.launch_expedition(state, town, engine.params, null)
	failures += TestUtil.check(sent != null, "una expedición sale de la raíz",
		"la raíz no puede lanzar la expedición del escenario")
	if sent == null:
		TestUtil.finish(self, failures)
		return
	var half_cycle := (sent.depart_cycle + sent.arrive_cycle) * 0.5

	var renderer := ChildMapRenderer.new()
	renderer.cell_size = SettlementView.TILE
	get_root().add_child(renderer)
	await process_frame

	var hash_before := state.state_hash()
	var saved_cycle := state.cycle
	state.cycle = half_cycle
	renderer.refresh(town, state, engine.params, engine.current_modifiers())
	state.cycle = saved_cycle
	var hash_after := state.state_hash()

	# --- Picking ---
	var origin := state.world_pos_of(town)
	var center_a := Vector2(state.world_pos_of(a) - origin) * SettlementView.TILE
	var center_b := Vector2(state.world_pos_of(b) - origin) * SettlementView.TILE
	var edge_a := center_a + Vector2(renderer._radii[0] * 0.9, 0.0)
	var empty := Vector2.ZERO
	failures += TestUtil.check(
		renderer.child_at(center_a) == a.id and renderer.child_at(center_b) == b.id
			and renderer.child_at(edge_a) == a.id,
		"el punto de cada mancha devuelve su hijo (%d en %s, %d en %s)" % [a.id, center_a, b.id, center_b],
		"el picking no devuelve el hijo: %d y %d, esperados %d y %d" % [
			renderer.child_at(center_a), renderer.child_at(center_b), a.id, b.id,
		]
	)
	failures += TestUtil.check(
		renderer.child_at(empty) == -1 and renderer.child_at(Vector2(1e6, 1e6)) == -1,
		"un punto vacío (el centro del padre, o lejos) devuelve -1",
		"el picking ve un hijo donde no hay ninguno: %d" % renderer.child_at(empty)
	)

	# --- La mancha está donde está el hijo ---
	failures += TestUtil.check(
		renderer._centers.size() == 2 and renderer._centers[0] == center_a
			and renderer._blob_mesh.multimesh.instance_count == 2,
		"una mancha por hijo, en world_pos_of(hijo) − world_pos_of(padre), en un solo MultiMesh",
		"manchas mal puestas: %s (esperado %s)" % [renderer._centers, center_a]
	)

	# --- La expedición: a mitad de camino hacia su sitio de verdad ---
	var predicted := state.predicted_child_pos(town, state.next_id)
	var mark := renderer._exp_positions[0] if renderer._exp_positions.size() == 1 else Vector2.INF
	var target := Vector2(predicted - origin) * SettlementView.TILE
	failures += TestUtil.check(
		renderer._expedition_mesh.multimesh.instance_count == 1
			and mark.distance_to(target * 0.5) < 0.01,
		"a mitad de viaje, la marca está a mitad de camino (%s de %s)" % [mark, target],
		"la marca de la expedición no está a mitad: %s, destino %s" % [mark, target]
	)
	failures += TestUtil.check(hash_before == hash_after,
		"refrescar la vista agregada no toca el estado (mismo state_hash)",
		"refrescar la vista agregada cambia el state_hash")

	# Llega: el hijo nace justo donde se había previsto.
	engine.tick(sent.arrive_cycle - state.cycle + 1.0)
	var born := state.get_node_by_id(town.children[town.children.size() - 1])
	failures += TestUtil.check(
		born != null and born.id != b.id and state.world_pos_of(born) == predicted,
		"la colonia nace donde iba la expedición (%s)" % predicted,
		"la colonia nace en %s y la expedición iba a %s" % [
			state.world_pos_of(born) if born != null else Vector2i(-1, -1), predicted,
		]
	)
	renderer.refresh(town, state, engine.params, engine.current_modifiers())
	failures += TestUtil.check(
		renderer._exp_positions.is_empty() and renderer.child_at(target) == born.id,
		"al llegar, la marca desaparece y en su sitio hay una mancha que se puede tocar",
		"tras llegar quedan %d marcas, y en el destino el picking da %d" % [
			renderer._exp_positions.size(), renderer.child_at(target),
		]
	)

	# --- Visibilidad ---
	# Desde M3 es un fundido continuo centrado en la mitad alejada del zoom, no un corte.
	var low := ChildMapRenderer.SHOW_FROM_DEPTH - ChildMapRenderer.FADE_DEPTH * 0.5
	var high := ChildMapRenderer.SHOW_FROM_DEPTH + ChildMapRenderer.FADE_DEPTH * 0.5
	failures += TestUtil.check(
		not ChildMapRenderer.shows_at(2.0) and not ChildMapRenderer.shows_at(2.0 + low - 0.01)
			and ChildMapRenderer.shows_at(2.5) and ChildMapRenderer.alpha_at(2.0 + high) == 1.0
			and ChildMapRenderer.alpha_at(2.95) == 1.0,
		"de cerca no se ve, de lejos se ve entera, y entre %.2f y %.2f se funde" % [low, high],
		"la regla de visibilidad no es la documentada"
	)
	var worst_step := 0.0
	var monotonic := true
	var previous := 0.0
	for i in 1001:
		var alpha := ChildMapRenderer.alpha_at(2.0 + 0.999 * float(i) / 1000.0)
		monotonic = monotonic and alpha >= previous - 1e-9
		worst_step = maxf(worst_step, absf(alpha - previous))
		previous = alpha
	failures += TestUtil.check(monotonic and worst_step < 0.02,
		"el fundido por profundidad es continuo y monótono (salto máximo %.4f por milésima)" % worst_step,
		"el fundido por profundidad salta %.4f o no es monótono" % worst_step)

	# --- M3c: la mancha anclada no se desvanece ---
	renderer.refresh(town, state, engine.params, engine.current_modifiers())
	var ia := renderer._ids.find(a.id)
	var ib := renderer._ids.find(b.id)
	renderer.set_fade(0.0, a.id, 1.0)
	# Lo que se escribe en el color de cada instancia (`_write_blob_colors`). El `MultiMesh` en sí no
	# se puede leer: sin pantalla, el servidor de render de mentira no guarda los colores.
	var drawn := renderer
	failures += TestUtil.check(
		drawn._blob_alpha(ia) == 1.0 and drawn._blob_alpha(ib) == 0.0
			and renderer.shows_anything(),
		"con la vista agregada apagada, la mancha anclada sigue entera y las demás se apagan",
		"la mancha anclada se apaga (%.2f) o las demás no (%.2f)" % [
			drawn._blob_alpha(ia), drawn._blob_alpha(ib),
		])
	renderer.set_fade(0.0)
	failures += TestUtil.check(drawn._blob_alpha(ia) == 0.0 and not renderer.shows_anything(),
		"sin ancla, la misma mancha se desvanece como las demás",
		"sin ancla la mancha sigue a %.2f" % drawn._blob_alpha(ia))
	var blob := renderer.blob_of(a.id)
	failures += TestUtil.check(
		Vector2(blob.x, blob.y) == center_a and blob.z == renderer._radii[ia]
			and renderer.blob_of(9999).z < 0.0,
		"blob_of da el centro y el radio de la mancha, y radio negativo si no hay",
		"blob_of da %s para la mancha de %s" % [blob, center_a])
	# Al entrar: la mancha anclada se queda de fantasma en el origen y se apaga con el fundido.
	renderer.set_fade(0.0, a.id, 1.0)
	renderer.hand_off(a.id)
	renderer.refresh(a, state, engine.params, engine.current_modifiers())
	renderer.set_fade(0.0, -1, 1.0, 1.0)
	var ghost_full := renderer._ghost.visible and renderer._ghost.self_modulate.a == 1.0 \
			and renderer._ghost.position == Vector2.ZERO and renderer.shows_anything()
	renderer.set_fade(0.0, -1, 1.0, 0.5)
	var ghost_half := is_equal_approx(renderer._ghost.self_modulate.a, 0.5)
	renderer.set_fade(0.0, -1, 1.0, 0.0)
	failures += TestUtil.check(ghost_full and ghost_half and not renderer._ghost.visible,
		"al entrar, la mancha anclada queda de fantasma en el origen y se apaga con el fundido",
		"el fantasma no sigue el fundido: entero %s, a medias %s, al final visible %s" % [
			ghost_full, ghost_half, renderer._ghost.visible,
		])

	renderer.queue_free()
	TestUtil.finish(self, failures)
