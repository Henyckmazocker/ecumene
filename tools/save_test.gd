extends SceneTree
## Round-trip de guardado y migración de esquema. Ejecutar con:
##   godot-4 --headless --path . -s res://tools/save_test.gd

const TestUtil := preload("res://tools/TestUtil.gd")


func _init() -> void:
	var failures := 0

	# --- Round-trip: guardar y cargar no puede alterar el estado ---
	var engine := TestUtil.make_engine(808)
	var root := engine.state.root()
	root.governor = Governor.balanced()
	# Una política que no es la de fábrica: lo que se guarda mal es lo que se dejó por defecto.
	root.governor.industry = 0.85
	root.governor.may_expand = false
	root.governor.may_research = false
	# Y una orden que no es `NONE` ni el ordinal 1: si el entero se perdiera o se desplazara,
	# no podría caer aquí por casualidad.
	root.governor.order = Governor.Order.SPECIALIZE
	for _i in 60:
		engine.tick(20.0)
	engine.state.legacy = 12.0
	engine.state.legacy_nodes = PackedStringArray(["fertile_soil", "fertile_soil", "old_crafts"])

	var before := engine.state.state_hash()
	Save.write(engine.state)
	var elapsed := []
	var loaded := Save.read(elapsed)

	failures += TestUtil.check(loaded != null, "save leído de vuelta", "no se pudo leer el save")
	if loaded != null:
		failures += TestUtil.check(
			loaded.state_hash() == before,
			"round-trip exacto: hash %d conservado con %d nodos" % [before, loaded.nodes.size()],
			"el round-trip altera el estado: %d vs %d" % [loaded.state_hash(), before]
		)
		failures += TestUtil.check(
			loaded.legacy == 12.0 and loaded.legacy_nodes.size() == 3,
			"legado persistido: %0.f puntos, %d nodos comprados" % [
				loaded.legacy, loaded.legacy_nodes.size(),
			],
			"el legado no sobrevive al guardado"
		)
		# La política del gobernador **no entra en `state_hash`** —lo que entra es lo que decide,
		# vía jobs, edificios y stocks—, así que el round-trip de arriba pasaría en verde aunque
		# se perdiera entera. Hay que mirarla a los ojos.
		var gov: Governor = loaded.root().governor
		failures += TestUtil.check(
			gov != null and is_equal_approx(gov.industry, 0.85)
				and not gov.may_expand and not gov.may_research
				and gov.may_build and gov.may_promote,
			"la política del gobernador sobrevive al guardado, prioridades y permisos",
			"la política se pierde al guardar: %s" % [
				"sin gobernador" if gov == null else gov.to_dict(),
			]
		)
		# La orden tampoco entra en `state_hash`: se mira aparte, y como enum, no como entero.
		failures += TestUtil.check(
			gov != null and gov.order == Governor.Order.SPECIALIZE,
			"la orden del gobernador sobrevive al guardado (SPECIALIZE)",
			"la orden se pierde al guardar: %s" % [
				"sin gobernador" if gov == null else Governor.Order.keys()[gov.order],
			]
		)
		failures += TestUtil.check(
			not elapsed.is_empty() and elapsed[0] < 5.0,
			"tiempo fuera medido: %0.1f s" % (elapsed[0] if not elapsed.is_empty() else -1.0),
			"no se ha medido el tiempo transcurrido desde el guardado"
		)

	# --- Un gobernador guardado antes de que existieran los permisos ---
	# Con default tolerante en `from_dict` no hace falta subir el esquema: carga con permiso para
	# todo, que es exactamente lo que ese gobernador hacía cuando se guardó.
	var old_gov := Governor.from_dict({
		"food": 0.4, "growth": 0.3, "industry": 0.2, "expansion": 0.1,
	})
	failures += TestUtil.check(
		old_gov.may_build and old_gov.may_research and old_gov.may_promote and old_gov.may_expand,
		"un gobernador de un save anterior a los permisos carga con permiso para todo",
		"un gobernador viejo pierde permisos al cargar: %s" % old_gov.to_dict()
	)
	# Ni orden: ese mismo diccionario no trae `order`, y tiene que caer en `NONE` —el
	# comportamiento de siempre— y no en el ordinal 0 de otra cosa si el enum se reordenara.
	failures += TestUtil.check(
		old_gov.order == Governor.Order.NONE,
		"y sin la clave `order` carga sin orden (NONE)",
		"un gobernador sin `order` carga con la orden %s" % Governor.Order.keys()[old_gov.order]
	)

	# --- Los bonos de legado se aplican de verdad ---
	failures += _legacy_applies()

	# --- Migración v1 → v2: los pesos de oficio pasan a ser trabajadores ---
	failures += _migrates_job_weights()

	# --- Una colonia fundada y delegada sigue delegada al cargar ---
	failures += _delegated_child_survives()

	# --- Rutas (M1): sobreviven bit a bit, y un save v2 carga sin ninguna ---
	failures += _routes_round_trip()
	failures += _v2_loads_without_routes()

	# --- Expediciones (M1): una en camino sobrevive al guardado, y un save v3 carga sin ninguna ---
	failures += _expedition_round_trip()
	failures += _v3_loads_without_expeditions()

	# --- ⏩ Acelerar (M3 del sumidero): una expedición acelerada sobrevive, y un save v4 sin
	# `accelerations` carga con 0 ---
	failures += _accelerated_expedition_round_trip()
	failures += _v4_loads_without_accelerations()

	# --- Región (M2): un save de seis recursos carga con el 🐎 a cero ---
	failures += _six_goods_save_loads()

	# --- Gobernador regional (M4): el permiso de rutas se guarda, y un save sin él carga con él ---
	failures += _route_permission_survives()

	# --- Vista agregada (M1): el foco sobrevive a guardar y cargar, y no cambia `state_hash` ---
	failures += _focus_survives()

	# --- Un save de una versión futura se rechaza en vez de corromper la partida ---
	var future := {"schema": WorldState.SCHEMA_VERSION + 99}
	failures += TestUtil.check(
		Save.migrate(future).is_empty(),
		"un save de esquema futuro se rechaza limpiamente",
		"un save de esquema futuro se acepta y podría corromper la partida"
	)

	Save.erase()
	TestUtil.finish(self, failures)


## **El foco sobrevive a guardar y cargar, y no cambia `state_hash`.** Va en el save fuera de
## `WorldState` (`payload["view"]`), así que el mismo estado guardado con dos focos distintos
## carga con la misma huella, y cada uno devuelve el suyo. Y un save de antes, sin `view`, carga
## sin foco: `Main` cae entonces en la raíz.
func _focus_survives() -> int:
	var engine := TestUtil.make_engine(860)
	var state := engine.state
	var root := state.root()
	root.tier = Content.TOWN
	root.pop = 500.0
	root.stocks[Goods.FOOD] = 500.0
	state.refresh_totals()
	engine.tick(7.0)
	var child := TestUtil.found_now(state, root, engine.params)
	if child == null:
		return TestUtil.check(false, "", "el pueblo de prueba no ha podido fundar")
	var before := state.state_hash()

	Save.write(state, {"focus": child.id})
	var view_child := {}
	var loaded_child := Save.read([], view_child)
	Save.write(state, {"focus": root.id})
	var view_root := {}
	var loaded_root := Save.read([], view_root)
	var failures := TestUtil.check(
		loaded_child != null and loaded_root != null
			and int(view_child.get("focus", -1)) == child.id
			and int(view_root.get("focus", -1)) == root.id
			and loaded_child.get_node_by_id(child.id) != null
			and loaded_child.state_hash() == before and loaded_root.state_hash() == before,
		"el foco sobrevive a guardar y cargar (hijo %d, raíz %d), y no cambia `state_hash` (%d)" % [
			child.id, root.id, before,
		],
		"el foco no vuelve del guardado o altera el estado: %s / %s, hash %d / %d (era %d)" % [
			view_child, view_root,
			loaded_child.state_hash() if loaded_child != null else 0,
			loaded_root.state_hash() if loaded_root != null else 0, before,
		]
	)

	# Un save sin `view` —el v4 de verdad, escrito antes de esto— carga sin foco.
	var bytes := FileAccess.get_file_as_bytes(V4_FIXTURE)
	var file := FileAccess.open(Save.PATH, FileAccess.WRITE)
	file.store_buffer(bytes)
	file.close()
	var view_old := {}
	var loaded_old := Save.read([], view_old)
	failures += TestUtil.check(
		loaded_old != null and view_old.is_empty(),
		"y un save sin `view` carga sin foco guardado (Main enfoca la raíz)",
		"un save sin `view` carga con foco %s" % view_old
	)
	return failures


## `may_route` no entra en `state_hash`, igual que el resto de la política: se mira a los ojos tras
## un guardado de verdad. Y un gobernador guardado antes de M4 carga con permiso, como los demás.
func _route_permission_survives() -> int:
	var engine := TestUtil.make_engine(818)
	var root := engine.state.root()
	root.governor = Governor.balanced()
	root.governor.may_route = false
	Save.write(engine.state)
	var loaded := Save.read([])
	var gov: Governor = loaded.root().governor if loaded != null else null
	var old_gov := Governor.from_dict({
		"food": 0.4, "growth": 0.3, "industry": 0.2, "expansion": 0.1,
		"may_build": true, "may_research": true, "may_promote": true, "may_expand": true,
	})
	return TestUtil.check(
		gov != null and not gov.may_route and gov.may_build and old_gov.may_route
			and not root.governor.duplicate_governor().may_route,
		"🛣️ Rutas apagado sobrevive al guardado y a la copia; un save sin la clave carga con él",
		"el permiso de rutas se pierde: %s, viejo %s" % [
			"sin gobernador" if gov == null else gov.to_dict(), old_gov.to_dict(),
		]
	)


## Una ruta es estado: entra en el hash y vuelve del guardado con su caudal pedido y el que
## circula, que no tienen por qué coincidir (cortada hasta el próximo checkpoint). `route_offset`
## no se guarda; se deriva al cargar, y tiene que salir el mismo.
func _routes_round_trip() -> int:
	var engine := TestUtil.make_routed_engine(810)
	for _i in 45:
		engine.tick(1.0)
	var state := engine.state
	var before := state.state_hash()
	Save.write(state)
	var loaded := Save.read([])
	if loaded == null or loaded.routes.size() != 1:
		return TestUtil.check(false, "", "las rutas no vuelven del guardado")
	var a: Route = state.routes[0]
	var b: Route = loaded.routes[0]
	var same_route := a.id == b.id and a.from_id == b.from_id and a.to_id == b.to_id \
		and a.good == b.good and a.rate == b.rate and a.flow == b.flow \
		and loaded.next_route_id == state.next_route_id \
		and loaded.routes_cycle == state.routes_cycle
	var same_offsets := true
	for id in state.ordered_ids():
		if (state.nodes[id] as SimNode).route_offset != (loaded.nodes[id] as SimNode).route_offset:
			same_offsets = false
	var failures := TestUtil.check(
		loaded.state_hash() == before and same_route and same_offsets,
		"una ruta sobrevive al guardado bit a bit: hash %d, caudal %.2f de %.2f" % [
			before, b.flow, b.rate,
		],
		"el guardado altera la ruta: hash %d vs %d, ruta %s vs %s" % [
			loaded.state_hash(), before, b.to_dict(), a.to_dict(),
		]
	)
	# Y la partida cargada sigue igual que la que no se guardó.
	var twin := TestUtil.make_engine(810)
	twin.adopt(loaded)
	for _i in 60:
		engine.tick(1.0)
		twin.tick(1.0)
	failures += TestUtil.check(
		engine.state.state_hash() == twin.state.state_hash(),
		"y con la ruta, la partida cargada sigue igual que la original 60 ciclos después",
		"cargar una partida con ruta la desvía de la original"
	)
	return failures


## Un save v2 no trae rutas. Tiene que cargar sin ninguna y con el mismo estado que guardó.
func _v2_loads_without_routes() -> int:
	var engine := TestUtil.make_engine(811)
	for _i in 30:
		engine.tick(1.0)
	var old := engine.state.to_dict()
	old["schema"] = 2
	old.erase("routes")
	old.erase("next_route_id")
	old.erase("routes_cycle")
	var migrated := Save.migrate(old)
	if migrated.is_empty():
		return TestUtil.check(false, "", "un save v2 se rechaza en vez de migrarse")
	var loaded := WorldState.from_dict(migrated)
	return TestUtil.check(
		int(migrated["schema"]) == WorldState.SCHEMA_VERSION and loaded.routes.is_empty()
			and loaded.next_route_id == 1 and loaded.state_hash() == engine.state.state_hash(),
		"un save v2 carga como v%d sin rutas y con el mismo hash (%d)" % [
			WorldState.SCHEMA_VERSION, loaded.state_hash(),
		],
		"un save v2 no carga limpio: esquema %d, %d rutas" % [
			int(migrated["schema"]), loaded.routes.size(),
		]
	)


## Los saves de antes del transporte traen `stocks` de seis elementos. No se sube el esquema: el
## recurso nuevo va al final de `Goods`, así que `SimNode.from_dict` rellena con un cero y ningún
## índice se mueve. Tiene que cargar con el 🐎 a cero y los otros seis bit a bit, y seguir jugando.
func _six_goods_save_loads() -> int:
	var engine := TestUtil.make_engine(812)
	engine.state.root().governor = Governor.balanced()
	for _i in 40:
		engine.tick(20.0)
	var old := engine.state.to_dict()
	for nd in old["nodes"]:
		nd["stocks"] = (nd["stocks"] as Array).slice(0, 6)
	Save.write(engine.state)  # el fichero de verdad, para que el recorrido sea el del juego
	var file := FileAccess.open(Save.PATH, FileAccess.WRITE)
	old["saved_at"] = Time.get_unix_time_from_system()
	file.store_var(old)
	file.close()
	var loaded := Save.read([])
	if loaded == null:
		return TestUtil.check(false, "", "un save de seis recursos no carga")
	var same := true
	for id in engine.state.ordered_ids():
		var a: SimNode = engine.state.nodes[id]
		var b: SimNode = loaded.nodes[id]
		if b.stocks.size() != Goods.COUNT or b.stocks[Goods.TRANSPORT] != 0.0:
			same = false
		for i in Goods.TRANSPORT:
			if a.stocks[i] != b.stocks[i]:
				same = false
	var failures := TestUtil.check(
		same and loaded.state_hash() == engine.state.state_hash(),
		"un save de 6 recursos carga con 🐎 a 0 y el resto bit a bit, sin subir el esquema (v%d)" \
			% WorldState.SCHEMA_VERSION,
		"un save de 6 recursos no carga limpio: %s" % [
			Array((loaded.root() as SimNode).stocks),
		]
	)
	var twin := TestUtil.make_engine(812)
	twin.adopt(loaded)
	for _i in 30:
		engine.tick(1.0)
		twin.tick(1.0)
	failures += TestUtil.check(
		engine.state.state_hash() == twin.state.state_hash(),
		"y la partida cargada sigue igual que la original 30 ciclos después",
		"cargar un save de 6 recursos desvía la partida"
	)
	return failures


## «Fundar y delegar»: el gobernador del hijo y su reloj de checkpoints vuelven del guardado.
## Ni uno ni otro entran en `state_hash`, así que se miran a los ojos.
func _delegated_child_survives() -> int:
	var engine := TestUtil.make_engine(809)
	var state := engine.state
	var root := state.root()
	root.tier = Content.TOWN
	root.pop = 500.0
	root.stocks[Goods.FOOD] = 500.0
	state.refresh_totals()
	engine.tick(7.0)
	var child := TestUtil.found_now(state, root, engine.params)
	if child == null:
		return TestUtil.check(false, "", "el pueblo de prueba no ha podido fundar")
	var policy := Governor.balanced()
	policy.expansion = 0.7
	GovernorSys.delegate(state, child, policy)

	Save.write(state)
	var loaded := Save.read([])
	var back: SimNode = loaded.nodes.get(child.id) if loaded != null else null
	return TestUtil.check(
		back != null and back.governor != null
			and is_equal_approx(back.governor.expansion, 0.7)
			and back.governor_last_cycle == state.cycle,
		"una colonia fundada y delegada sigue delegada al cargar, con su política y su reloj",
		"la colonia delegada pierde su gobernador al guardar: %s" % [
			"sin nodo" if back == null else back.to_dict().get("governor"),
		]
	)


## Un save de antes del cambio de oficios tiene que seguir abriéndose.
##
## En v1 `jobs` era un peso relativo que el motor normalizaba al vuelo; en v2 es el número de
## trabajadores destinados. Sin migrar, un save viejo con pesos `[1, 1]` se leería como «un
## granjero y un leñador» en un pueblo de 200 habitantes, y la partida se hundiría al abrirla.
func _migrates_job_weights() -> int:
	var farm := Content.building_index("farm")
	var woodcutter := Content.building_index("woodcutter")
	var jobs := []
	jobs.resize(Content.building_count())
	jobs.fill(0.0)
	jobs[farm] = 3.0        # 75 % del peso
	jobs[woodcutter] = 1.0  # 25 %

	var old_save := {
		"schema": 1,
		"nodes": [{"pop": 100.0, "jobs": jobs}],
	}
	var migrated := Save.migrate(old_save)
	if migrated.is_empty():
		return TestUtil.check(false, "", "un save v1 se rechaza en vez de migrarse")

	var result: Array = migrated["nodes"][0]["jobs"]
	var failures := TestUtil.check(
		int(migrated["schema"]) == WorldState.SCHEMA_VERSION,
		"el save migrado queda marcado como esquema %d" % WorldState.SCHEMA_VERSION,
		"la migración no actualiza el número de esquema"
	)
	failures += TestUtil.check(
		int(result[farm]) == 75 and int(result[woodcutter]) == 25,
		"pesos 3:1 con 100 habitantes → %d granjeros y %d leñadores" % [
			int(result[farm]), int(result[woodcutter]),
		],
		"la migración reparte mal: %d granjeros y %d leñadores de 100 habitantes" % [
			int(result[farm]), int(result[woodcutter]),
		]
	)
	return failures


func _legacy_applies() -> int:
	var plain := TestUtil.make_engine(99)
	var blessed := TestUtil.make_engine(99)
	for _i in 5:
		blessed.state.legacy_nodes.append("fertile_soil")

	plain.tick(300.0)
	blessed.tick(300.0)

	var a := plain.state.root().stocks[Goods.FOOD]
	var b := blessed.state.root().stocks[Goods.FOOD]
	return TestUtil.check(
		b > a,
		"legado efectivo: Tierra fértil ×5 da %0.1f de comida frente a %0.1f" % [b, a],
		"los nodos de legado no cambian nada: %0.1f vs %0.1f" % [b, a]
	)


## Una expedición en camino es estado: entra en el hash, vuelve del guardado con su reloj, su carga
## y la política con la que nacerá el hijo, y la partida cargada sigue igual que la original hasta
## después de la llegada.
func _expedition_round_trip() -> int:
	var engine := TestUtil.make_engine(820)
	var state := engine.state
	var root := state.root()
	root.tier = Content.TOWN
	root.pop = 500.0
	root.stocks[Goods.FOOD] = 500.0
	state.refresh_totals()
	var policy := Governor.balanced()
	policy.expansion = 0.7
	engine.events.actor = "governor"
	var sent := Promotion.launch_expedition(state, root, engine.params, engine.events, policy)
	engine.events.actor = "player"
	engine.tick(513.0)
	var before := state.state_hash()
	Save.write(state)
	var loaded := Save.read([])
	var back: Expedition = loaded.expedition_of(root.id) if loaded != null else null
	var failures := TestUtil.check(
		sent != null and back != null and loaded.state_hash() == before
			and back.depart_cycle == sent.depart_cycle and back.arrive_cycle == sent.arrive_cycle
			and back.tier == sent.tier and back.pop == sent.pop and back.food == sent.food
			and back.actor == "governor" and back.delegate_policy != null
			and is_equal_approx(back.delegate_policy.expansion, 0.7),
		"una expedición en camino sobrevive al guardado: hash %d, llega en el ciclo %.0f" % [
			before, back.arrive_cycle if back != null else -1.0,
		],
		"el guardado altera la expedición: hash %d vs %d, %s vs %s" % [
			loaded.state_hash() if loaded != null else 0, before,
			back.to_dict() if back != null else "ninguna",
			sent.to_dict() if sent != null else "ninguna",
		]
	)
	var twin := TestUtil.make_engine(820)
	twin.adopt(loaded)
	for _i in 4:
		engine.tick(600.0)
		twin.tick(600.0)
	var child: SimNode = twin.state.nodes.get(twin.state.root().children[0]) \
		if twin.state.root().children.size() == 1 else null
	failures += TestUtil.check(
		engine.state.state_hash() == twin.state.state_hash() and child != null
			and child.governor != null and is_equal_approx(child.governor.expansion, 0.7),
		"y la partida cargada llega igual que la original: mismo hash y el hijo nace delegado",
		"cargar con una expedición en camino desvía la partida o pierde al hijo"
	)
	return failures


## **Un save v3 de verdad**, escrito por `Save.write` con el código de antes de las expediciones
## (`tools/fixtures/save_v3.save`: semilla 830, raíz delegada, 740 ciclos, la raíz y dos hijos
## fundados). Se carga por el mismo camino que el juego, sin ninguna expedición, con sus nodos, y
## con la huella que tenía al guardarse: sin expediciones, el hash no cambia.
const V3_FIXTURE := "res://tools/fixtures/save_v3.save"
const V3_HASH := -596555895483109750


func _v3_loads_without_expeditions() -> int:
	var bytes := FileAccess.get_file_as_bytes(V3_FIXTURE)
	if bytes.is_empty():
		return TestUtil.check(false, "", "no se encuentra el save v3 de prueba %s" % V3_FIXTURE)
	var file := FileAccess.open(Save.PATH, FileAccess.WRITE)
	file.store_buffer(bytes)
	file.close()
	var fixture := FileAccess.open(V3_FIXTURE, FileAccess.READ)
	var raw: Dictionary = fixture.get_var()
	fixture.close()
	var loaded := Save.read([])
	if loaded == null:
		return TestUtil.check(false, "", "el save v3 no carga")
	var failures := TestUtil.check(
		int(raw.get("schema", 0)) == 3 and loaded.expeditions.is_empty()
			and loaded.nodes.size() == 3 and loaded.root().children.size() == 2
			and loaded.state_hash() == V3_HASH,
		"un save v3 carga sin ninguna expedición, con sus %d nodos y el hash de entonces (%d)" % [
			loaded.nodes.size(), loaded.state_hash(),
		],
		"el save v3 no carga limpio: esquema %s, %d expediciones, %d nodos, hash %d (era %d)" % [
			raw.get("schema"), loaded.expeditions.size(), loaded.nodes.size(),
			loaded.state_hash(), V3_HASH,
		]
	)
	# Y se sigue jugando: el gobernador de la raíz vuelve a mandar colonos, ahora con reloj.
	var engine := TestUtil.make_engine(830)
	engine.adopt(loaded)
	for _i in 100:
		engine.tick(30.0)
	failures += TestUtil.check(
		not engine.state.expeditions.is_empty() or engine.state.root().children.size() > 2,
		"y la partida v3 sigue: su gobernador ya manda expediciones",
		"la partida v3 cargada no vuelve a fundar en 3.000 ciclos"
	)
	return failures


## **Una expedición acelerada sobrevive al guardado**: su llegada adelantada y cuántas veces se
## aceleró, que decide el precio de la siguiente. `accelerations` entra en el hash, así que el hash
## igual ya lo cubre; se mira también a los ojos, y el precio de la siguiente tras cargar.
func _accelerated_expedition_round_trip() -> int:
	var engine := TestUtil.make_engine(850)
	var state := engine.state
	var root := state.root()
	root.tier = Content.CITY
	root.pop = 500.0
	root.stocks[Goods.FOOD] = 500.0
	state.refresh_totals()
	Promotion.launch_expedition(state, root, engine.params, engine.events)
	engine.tick(700.0)
	root.stocks[Goods.GOLD] = 1.0e9
	var ok := Promotion.accelerate_expedition(state, root, engine.params, engine.events) \
		and Promotion.accelerate_expedition(state, root, engine.params, engine.events)
	var sent := state.expedition_of(root.id)
	var next_cost := Promotion.accelerate_cost(state, root, engine.params)
	var before := state.state_hash()
	Save.write(state)
	var loaded := Save.read([])
	var back: Expedition = loaded.expedition_of(root.id) if loaded != null else null
	return TestUtil.check(
		ok and back != null and back.accelerations == 2 and back.arrive_cycle == sent.arrive_cycle
			and loaded.state_hash() == before
			and Promotion.accelerate_cost(loaded, loaded.root(), engine.params) == next_cost,
		"⏩ una expedición acelerada dos veces sobrevive al guardado: llega en %.2f, la siguiente cuesta %.0f 🪙" % [
			back.arrive_cycle if back != null else -1.0, next_cost,
		],
		"⏩ el guardado pierde la aceleración: %s vs %s, hash %d vs %d" % [
			back.to_dict() if back != null else "ninguna",
			sent.to_dict() if sent != null else "ninguna",
			loaded.state_hash() if loaded != null else 0, before,
		]
	)


## **Un save v4 de verdad**, escrito por `Save.write` con el código de antes de ⏩ acelerar
## (`tools/fixtures/save_v4.save`: semilla 840, raíz Pueblo con 500 hab, una expedición sin
## gobernador que sale en el 0 y llega en el 2.400, guardado en el ciclo 300). Su diccionario no
## trae `accelerations`: carga por el mismo camino que el juego con 0, y con la huella con que se
## guardó, porque una expedición sin acelerar no añade nada al hash.
const V4_FIXTURE := "res://tools/fixtures/save_v4.save"
const V4_HASH := 700119564342920892


func _v4_loads_without_accelerations() -> int:
	var bytes := FileAccess.get_file_as_bytes(V4_FIXTURE)
	if bytes.is_empty():
		return TestUtil.check(false, "", "no se encuentra el save v4 de prueba %s" % V4_FIXTURE)
	var file := FileAccess.open(Save.PATH, FileAccess.WRITE)
	file.store_buffer(bytes)
	file.close()
	var fixture := FileAccess.open(V4_FIXTURE, FileAccess.READ)
	var raw: Dictionary = fixture.get_var()
	fixture.close()
	var raw_expeditions: Array = raw.get("expeditions", [])
	var loaded := Save.read([])
	if loaded == null:
		return TestUtil.check(false, "", "el save v4 no carga")
	var e: Expedition = loaded.expedition_of(loaded.root_id)
	return TestUtil.check(
		int(raw.get("schema", 0)) == 4 and raw_expeditions.size() == 1
			and not (raw_expeditions[0] as Dictionary).has("accelerations")
			and e != null and e.accelerations == 0 and e.arrive_cycle == 2400.0
			and loaded.state_hash() == V4_HASH,
		"⏩ un save v4 sin `accelerations` carga con 0, llegada en %.0f y el hash de entonces (%d)" % [
			e.arrive_cycle if e != null else -1.0, loaded.state_hash(),
		],
		"⏩ el save v4 no carga limpio: esquema %s, expedición %s, hash %d (era %d)" % [
			raw.get("schema"), e.to_dict() if e != null else "ninguna",
			loaded.state_hash(), V4_HASH,
		]
	)
