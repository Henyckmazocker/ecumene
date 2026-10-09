extends SceneTree
## Acreditar la ausencia repartida entre fotogramas no puede cambiar el resultado. Ejecutar con:
##   godot-4 --headless --path . -s res://tools/catchup_test.gd
##
## Al volver a una partida, la acreditación se reparte entre varios fotogramas para poder
## enseñar una barra en vez de colgar el juego. Eso solo es aceptable si el estado final es
## **exactamente** el mismo que el del bucle de un tirón: si un día alguien mete el presupuesto
## de tiempo dentro del troceado —partiendo un paso para que quepa en el fotograma—, el progreso
## offline empezaría a depender de los FPS de la máquina y este test se pone en rojo.
##
## Aquí no hay tolerancia, al revés que en `offline_test.gd`: no se comparan dos formas distintas
## de avanzar el tiempo, sino la misma lista de pasos consumida a distinto ritmo. La igualdad es
## bit a bit.

const TestUtil := preload("res://tools/TestUtil.gd")


func _init() -> void:
	var failures := 0

	failures += _same_state("delegado", true, 24.0 * 3600.0)
	failures += _same_state("sin delegar", false, 24.0 * 3600.0)
	failures += _same_state("ausencia corta", true, 90.0)
	# Con una orden puesta el troceado tampoco puede mover nada: la orden solo se lee en el
	# checkpoint del gobernador, y los checkpoints son los mismos se consuman al ritmo que sea.
	for order in [Governor.Order.STOCKPILE, Governor.Order.EXPAND, Governor.Order.SPECIALIZE]:
		failures += _same_state(
			"orden %s" % Governor.Order.keys()[order], true, 6.0 * 3600.0, order
		)
	# Con una ruta y sin delegar nada: tiene que trocear igual, y el troceado no puede mover nada.
	failures += _same_state_with_route("ruta, un día fuera", 24.0 * 3600.0)
	failures += _same_state_with_route("ruta, ausencia corta", 90.0)
	# Con el gobernador regional creando y ajustando rutas en sus checkpoints (M4).
	failures += _same_state_with_route("gobernador regional, un día fuera", 24.0 * 3600.0, true)
	# Con una expedición en camino que llega a mitad de un paso (Expediciones M1).
	failures += _same_state_with_expedition("expedición, padre delegado", true)
	failures += _same_state_with_expedition("expedición, sin delegar", false)
	# ⚡ Con boosts que expiran a mitad de un paso (M0 de Objetos de tiempo).
	failures += _boost_chunked_equals_whole()
	# ⌛ Un salto va por la misma barra que una ausencia (M3 de Objetos de tiempo).
	failures += _skip_chunked_equals_whole()
	failures += _the_report_is_the_same()
	failures += _closing_twice_reports_once()
	failures += _a_step_always_happens()

	TestUtil.finish(self, failures)


## De un tirón o paso a paso, el mismo `state_hash()`.
func _same_state(
	label: String, delegated: bool, away: float, order := Governor.Order.NONE
) -> int:
	var jump := _engine(delegated, order)
	var framed := _engine(delegated, order)

	jump.catch_up(away)

	# Paso a paso, con el presupuesto más tacaño posible: un paso por fotograma.
	var job := framed.begin_catch_up(away)
	var frames := 0
	while not framed.advance_catch_up(job, 0.001):
		frames += 1
		if frames > 1000:
			break

	var a := jump.state.state_hash()
	var b := framed.state.state_hash()
	return TestUtil.check(
		a == b,
		"%s: acreditar en %d fotogramas da el mismo estado que de un salto (hash %d)" % [
			label, frames + 1, b,
		],
		"%s: acreditar por fotogramas ha cambiado el estado (%d != %d)" % [label, b, a]
	)


## **M1, criterio 3.** Con una ruta de comida a 0,5/ciclo, acreditar por fotogramas da el mismo
## `state_hash()` que de un tirón. Y la ausencia larga se trocea aunque no haya nada delegado: un
## salto con el caudal del primer checkpoint regalaría o robaría comida.
##
## Con `regional`, el escenario es el del gobernador regional (`TestUtil.make_regional_engine`):
## las rutas las crea y las ajusta él en sus checkpoints, y el troceado no puede notarlo.
func _same_state_with_route(label: String, away: float, regional := false) -> int:
	var jump := TestUtil.make_regional_engine(90210) if regional \
		else TestUtil.make_routed_engine(90210)
	var framed := TestUtil.make_regional_engine(90210) if regional \
		else TestUtil.make_routed_engine(90210)
	var jump_job := jump.begin_catch_up(away)
	while not jump.advance_catch_up(jump_job, 0.0):
		pass
	var job := framed.begin_catch_up(away)
	var frames := 0
	while not framed.advance_catch_up(job, 0.001):
		frames += 1
		if frames > 1000:
			break

	var a := jump.state.state_hash()
	var b := framed.state.state_hash()
	var interval := framed.params.governor_interval
	var should_split := job.cycles >= 2.0 * interval
	var failures := TestUtil.check(
		job.steps > 1 or not should_split,
		"%s: con una ruta la ausencia se trocea en %d pasos de %.1f ciclos" % [
			label, job.steps, job.chunk,
		],
		"%s: con una ruta la ausencia de %.0f ciclos va de un salto" % [label, job.cycles]
	)
	failures += TestUtil.check(
		a == b and not jump.state.routes.is_empty(),
		"%s: acreditar en %d fotogramas da el mismo estado que de un tirón (hash %d)" % [
			label, frames + 1, b,
		],
		"%s: con una ruta, acreditar por fotogramas cambia el estado (%d != %d)" % [label, b, a]
	)
	return failures


## Y el mismo informe de vuelta: es lo que el jugador lee, así que también tiene que cuadrar.
func _the_report_is_the_same() -> int:
	var jump := _engine(true)
	var framed := _engine(true)
	var away := 12.0 * 3600.0

	jump.catch_up(away)
	var job := framed.begin_catch_up(away)
	while not framed.advance_catch_up(job, 0.001):
		pass

	var a := jump.last_offline
	var b := framed.last_offline
	var same := a != null and b != null \
		and is_equal_approx(a.seconds_credited, b.seconds_credited) \
		and is_equal_approx(a.cycles, b.cycles) \
		and a.capped == b.capped \
		and is_equal_approx(a.pop_after, b.pop_after) \
		and a.buildings_built == b.buildings_built \
		and a.upgrades_bought == b.upgrades_bought
	return TestUtil.check(
		same,
		"el informe de vuelta es el mismo por fotogramas (+%d edificios, %.1f hab)" % [
			b.buildings_built if b != null else -1, b.pop_after if b != null else -1.0,
		],
		"el informe de vuelta cambia según cómo se acredite"
	)


## Quien conduce la barra la mantiene un mínimo en pantalla, así que llama de más después de
## haber terminado. Eso no puede dejar dos anuncios de vuelta en el diario.
func _closing_twice_reports_once() -> int:
	var engine := _engine(true)
	engine.events.enabled = true
	var job := engine.begin_catch_up(4.0 * 3600.0)
	while not engine.advance_catch_up(job, 0.001):
		pass
	var cycle_after := engine.state.cycle
	for _i in 5:
		engine.advance_catch_up(job, 8.0)

	var announcements := 0
	for entry in engine.events.recent(64):
		if String((entry as Dictionary).get("category", "")) == "offline":
			announcements += 1
	return TestUtil.check(
		announcements == 1 and is_equal_approx(engine.state.cycle, cycle_after),
		"cerrar la acreditación de más no acredita más tiempo ni repite el anuncio",
		"cerrar la acreditación de más deja %d anuncios y el ciclo en %.3f (era %.3f)" % [
			announcements, engine.state.cycle, cycle_after,
		]
	)


## Con un presupuesto imposible tiene que darse **un** paso, no ninguno: si no, la barra se
## queda quieta para siempre y el juego no arranca nunca.
func _a_step_always_happens() -> int:
	var engine := _engine(true)
	var job := engine.begin_catch_up(24.0 * 3600.0)
	engine.advance_catch_up(job, 0.000001)
	return TestUtil.check(
		job.done >= 1,
		"un presupuesto imposible aún da un paso (%d de %d)" % [job.done, job.steps],
		"con un presupuesto imposible no se da ningún paso: la acreditación no avanzaría"
	)


## La orden se fija igual en los dos motores y antes de avanzar nada.
func _engine(delegated: bool, order := Governor.Order.NONE) -> SimEngine:
	var engine := TestUtil.make_engine(90210)
	if delegated:
		engine.state.root().governor = Governor.balanced()
		engine.state.root().governor.order = order
	return engine


## **Troceado = de un tirón, con una expedición en camino.** El hijo nace dentro de un paso del
## troceado (`SimEngine.tick` parte el paso en la llegada), y consumir los pasos a otro ritmo no
## puede cambiar ni cuándo nace ni cómo crece. Con el padre delegado la colonia nace delegada y el
## troceado es de 64 pasos; sin delegar, de un salto.
func _same_state_with_expedition(label: String, delegated: bool) -> int:
	var jump := _expedition_engine(delegated)
	var framed := _expedition_engine(delegated)
	var parent_id := jump.state.root_id
	var arrive := jump.state.expedition_of(parent_id).arrive_cycle
	var away := 12.0 * 3600.0
	jump.catch_up(away)
	var job := framed.begin_catch_up(away)
	var frames := 0
	while not framed.advance_catch_up(job, 0.001):
		frames += 1
		if frames > 1000:
			break
	var a := jump.state.state_hash()
	var b := framed.state.state_hash()
	# El hijo de la expedición es el primer id que se reparte después de lanzarla.
	var child: SimNode = framed.state.nodes.get(framed.state.root().children[0]) \
		if not framed.state.root().children.is_empty() else null
	return TestUtil.check(
		a == b and child != null and child.parent_id == parent_id
			and arrive < job.cycles and (child.is_delegated() == delegated),
		"%s: llega en el ciclo %.0f de %.0f, y %d fotogramas dan lo mismo que de un tirón (hash %d)"
			% [label, arrive, job.cycles, frames + 1, b],
		"%s: con una expedición, acreditar por fotogramas cambia el estado (%d != %d) o no llega (hijo %s)"
			% [label, b, a, child != null]
	)


## Un pueblo con una expedición recién lanzada. Con `delegated`, el padre está delegado sin permiso
## de expandirse (para que solo haya esta expedición) y la colonia lleva su política.
func _expedition_engine(delegated: bool) -> SimEngine:
	var engine := TestUtil.make_engine(90211)
	var root := engine.state.root()
	root.tier = Content.TOWN
	root.buildings[Content.building_index("hut")] = 20
	root.buildings[Content.building_index("farm")] = 8
	root.pop = 60.0
	for i in Goods.COUNT:
		root.stocks[i] = 400.0
	engine.state.refresh_totals()
	var policy: Governor = null
	if delegated:
		root.governor = Governor.balanced()
		root.governor.may_expand = false
		policy = root.governor.duplicate_governor()
	Promotion.launch_expedition(engine.state, root, engine.params, null, policy)
	# Un poco de juego antes de cerrar, para que la llegada no caiga en el borde de un paso.
	engine.tick(7.3)
	return engine


## **⚡ Troceado = de un tirón, con nodos a otro ritmo.** Dos escenarios: la ruta del spike con el
## hijo a ×4 y el padre delegado a ×2, y el pueblo delegado con su expedición en camino y él a ×2
## (la llegada se recalcula al usar el boost). Los boosts acaban a mitad de un paso del troceado
## —`SimEngine.tick` parte el paso ahí— y consumir los pasos a otro ritmo no puede mover nada: ni
## el `state_hash` ni lo que aún no entra en él (ritmo, relojes y gobernador de cada nodo).
func _boost_chunked_equals_whole() -> int:
	var failures := 0
	for with_expedition in [false, true]:
		var label: String = "⚡ expedición, padre delegado a ×2" if with_expedition \
			else "⚡ ruta, hijo a ×4 y padre delegado a ×2"
		var jump := _boosted_engine(with_expedition)
		var framed := _boosted_engine(with_expedition)
		var away := 12.0 * 3600.0
		jump.catch_up(away)
		var job := framed.begin_catch_up(away)
		var frames := 0
		while not framed.advance_catch_up(job, 0.001):
			frames += 1
			if frames > 1000:
				break
		var a := jump.state.state_hash()
		var b := framed.state.state_hash()
		var same_clocks := _clocks(jump) == _clocks(framed)
		var expired := framed.state.min_boost_until == INF
		failures += TestUtil.check(
			a == b and same_clocks and expired and job.steps > 1,
			"%s: %d pasos en %d fotogramas dan lo mismo que de un tirón (hash %d), y los boosts se han apagado"
				% [label, job.steps, frames + 1, b],
			"%s: troceado ≠ de un tirón (%d != %d), relojes iguales %s, boosts apagados %s, %d pasos"
				% [label, b, a, same_clocks, expired, job.steps]
		)
	return failures


func _boosted_engine(with_expedition: bool) -> SimEngine:
	var engine: SimEngine
	if with_expedition:
		engine = _expedition_engine(true)
		SimEngine.apply_boost(engine.state, engine.state.root(), 2.0, 700.0)
	else:
		engine = TestUtil.make_routed_engine(90212)
		var root := engine.state.root()
		root.governor = Governor.balanced()
		root.governor.may_expand = false
		SimEngine.apply_boost(engine.state, engine.state.nodes[root.children[0]], 4.0, 1250.0)
		SimEngine.apply_boost(engine.state, root, 2.0, 2000.0)
	return engine


## Ritmo, fin del boost, reloj propio y del gobernador de cada nodo, y llegada de cada expedición.
func _clocks(engine: SimEngine) -> String:
	var parts := PackedStringArray()
	for id in engine.state.ordered_ids():
		var n: SimNode = engine.state.nodes[id]
		parts.append("%d:%s:%s:%s:%s" % [id, var_to_str(n.boost_factor), var_to_str(n.boost_until),
			var_to_str(n.local_cycle), var_to_str(n.governor_last_cycle)])
	for e in engine.state.expeditions:
		parts.append("e%d:%s" % [e.parent_id, var_to_str(e.arrive_cycle)])
	return ",".join(parts)


## **⌛ Un salto troceado da lo mismo que de un tirón.** `begin_skip` usa el troceado de la ausencia
## (`_job_for`), así que con nodos delegados un `skip_4h` son 64 pasos que la barra consume a lo
## largo de los fotogramas; a qué ritmo, no puede notarse. Dos escenarios: el pueblo delegado y la
## ruta con nodos a ×2 y ×4 cuyos boosts acaban a mitad del salto. Y un salto no deja informe de
## vuelta: el de la última ausencia no se pisa ni se inventa uno.
func _skip_chunked_equals_whole() -> int:
	var failures := 0
	for boosted in [false, true]:
		var label: String = "⌛ ruta con ⚡ ×2 y ×4" if boosted else "⌛ pueblo delegado"
		var jump := _boosted_engine(false) if boosted else _engine(true)
		var framed := _boosted_engine(false) if boosted else _engine(true)
		for e in [jump, framed]:
			Shop.grant(e.state, "skip_4h", 1, null, "test")
		var whole := jump.use_skip("skip_4h")
		while not jump.advance_catch_up(whole, 0.0):
			pass
		var job := framed.use_skip("skip_4h")
		var frames := 0
		while not framed.advance_catch_up(job, 0.001):
			frames += 1
			if frames > 1000:
				break
		var a := jump.state.state_hash()
		var b := framed.state.state_hash()
		var same_clocks := _clocks(jump) == _clocks(framed)
		var online := job.is_skip and job.cycles == 14400.0 and framed.state.cycle == 14400.0 \
			and framed.last_offline == null and Shop.count_of(framed.state, "skip_4h") == 0
		failures += TestUtil.check(
			a == b and same_clocks and online and job.steps > 1,
			"%s: %d pasos en %d fotogramas dan lo mismo que de un tirón (hash %d), 14.400 ciclos y sin informe"
				% [label, job.steps, frames + 1, b],
			"%s: troceado ≠ de un tirón (%d != %d), relojes iguales %s, salto online %s, %d pasos"
				% [label, b, a, same_clocks, online, job.steps]
		)
	return failures
