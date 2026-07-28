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
		failures += TestUtil.check(
			not elapsed.is_empty() and elapsed[0] < 5.0,
			"tiempo fuera medido: %0.1f s" % (elapsed[0] if not elapsed.is_empty() else -1.0),
			"no se ha medido el tiempo transcurrido desde el guardado"
		)

	# --- Los bonos de legado se aplican de verdad ---
	failures += _legacy_applies()

	# --- Un save de una versión futura se rechaza en vez de corromper la partida ---
	var future := {"schema": WorldState.SCHEMA_VERSION + 99}
	failures += TestUtil.check(
		Save.migrate(future).is_empty(),
		"un save de esquema futuro se rechaza limpiamente",
		"un save de esquema futuro se acepta y podría corromper la partida"
	)

	Save.erase()
	TestUtil.finish(self, failures)


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
