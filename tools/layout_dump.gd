extends SceneTree
## Mapa de la colocación en texto. Ejecutar con:
##   godot-4 --headless --path . -s res://tools/layout_dump.gd
##
## Existe porque **las capturas no sirven para juzgar el espaciado**: la semilla de una partida
## nueva es la hora del sistema, así que dos ejecuciones son dos mundos distintos y no hay
## comparación posible. Aquí la semilla es fija, y cambiar `Layout.GAP` o la búsqueda se ve al
## instante en el mismo asentamiento.
##
## Cada letra es la inicial del edificio; `·` es suelo libre y `~` lo no edificable.

const TestUtil := preload("res://tools/TestUtil.gd")

const SEED := 555
const TICKS := 80
const RADIUS := 22


func _init() -> void:
	for tier in [Content.SETTLEMENT, Content.TOWN]:
		_dump(tier)
	quit(0)


func _dump(tier: int) -> void:
	var engine := TestUtil.make_engine(SEED)
	var node := engine.state.root()
	node.governor = Governor.balanced()
	for _i in TICKS:
		engine.tick(25.0)
	node.tier = tier

	var terrain := TerrainGen.generate(
		engine.state.terrain_seed(), engine.state.world_pos_of(node), node.tier)
	var layout := Layout.build(node, terrain, Layout.core_radius(0))

	var mark := {}
	for p in layout.placements:
		mark[p.cell] = Content.building(p.building).name.substr(0, 1)

	print("")
	print("=== %s · %d edificios · GAP=%d ===" % [
		Content.tier(tier).name, layout.placements.size(), Layout.GAP,
	])
	for y in range(-RADIUS, RADIUS + 1):
		var line := ""
		for x in range(-RADIUS, RADIUS + 1):
			var cell := Vector2i(x, y)
			if mark.has(cell):
				line += String(mark[cell])
			elif not terrain.is_buildable(cell):
				line += "~"
			else:
				line += "·"
		print(line)

	# El radio y la densidad son los dos números que dicen si el pueblo está apretado o
	# desperdigado, sin depender de que alguien mire un dibujo.
	var far := 0
	var sum := 0.0
	for p in layout.placements:
		var r: int = maxi(absi(p.cell.x), absi(p.cell.y))
		far = maxi(far, r)
		sum += float(r)
	var mean := sum / maxf(float(layout.placements.size()), 1.0)
	print("radio máximo %d · radio medio %.1f · densidad %.2f edificios/celda²" % [
		far, mean, float(layout.placements.size()) / maxf(float(far * far * 4), 1.0),
	])
