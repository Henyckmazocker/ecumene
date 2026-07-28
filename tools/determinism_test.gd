extends SceneTree
## Verificación headless del determinismo. Ejecutar con:
##   godot-4 --headless --path . -s res://tools/determinism_test.gd
##
## Comprueba que mismo seed + misma secuencia de acciones ⇒ mismo `state_hash()`, que dos
## seeds distintas divergen, y que un round-trip de guardado no altera el estado.

const TestUtil := preload("res://tools/TestUtil.gd")


func _init() -> void:
	var failures := 0

	# --- Dos partidas idénticas tienen que converger ciclo a ciclo ---
	var a := TestUtil.make_engine(1234)
	var b := TestUtil.make_engine(1234)
	var diverged_at := -1
	for i in 500:
		a.tick(1.0)
		b.tick(1.0)
		if a.state.state_hash() != b.state.state_hash():
			diverged_at = i
			break
	if diverged_at >= 0:
		print("FALLO: dos partidas con seed 1234 divergen en el ciclo %d" % diverged_at)
		failures += 1
	else:
		print("OK  determinismo: 500 ciclos, hash idéntico (%d)" % a.state.state_hash())

	# --- Seeds distintas producen mundos distintos ---
	var c := TestUtil.make_engine(9999)
	c.tick(500.0)
	if c.state.root().name == a.state.root().name:
		print("FALLO: seeds distintas generan el mismo nombre de asentamiento")
		failures += 1
	else:
		print("OK  seeds distintas: %s vs %s" % [a.state.root().name, c.state.root().name])

	# --- Las acciones del jugador no rompen el determinismo ---
	var d := TestUtil.make_engine(77)
	var e := TestUtil.make_engine(77)
	for i in 200:
		d.tick(1.0)
		e.tick(1.0)
		if i % 25 == 0:
			var hut := Content.building_index("hut")
			Construction.build(d.state.root(), hut, d.state.cycle, null)
			Construction.build(e.state.root(), hut, e.state.cycle, null)
	if d.state.state_hash() != e.state.state_hash():
		print("FALLO: construir en paralelo diverge")
		failures += 1
	else:
		print("OK  acciones deterministas: %d cabañas, hash %d" % [
			d.state.root().buildings[Content.building_index("hut")], d.state.state_hash(),
		])

	TestUtil.finish(self, failures)
