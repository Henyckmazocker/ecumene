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

	# --- Migración v1 → v2: los pesos de oficio pasan a ser trabajadores ---
	failures += _migrates_job_weights()

	# --- Un save de una versión futura se rechaza en vez de corromper la partida ---
	var future := {"schema": WorldState.SCHEMA_VERSION + 99}
	failures += TestUtil.check(
		Save.migrate(future).is_empty(),
		"un save de esquema futuro se rechaza limpiamente",
		"un save de esquema futuro se acepta y podría corromper la partida"
	)

	Save.erase()
	TestUtil.finish(self, failures)


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
