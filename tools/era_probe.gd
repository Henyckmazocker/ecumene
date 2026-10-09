extends SceneTree
## ¿Cuándo pasa cada cosa en una era? Ejecutar con:
##   godot-4 --headless --path . -s res://tools/era_probe.gd
##   godot-4 --headless --path . -s res://tools/era_probe.gd -- --seed=11 --until=h3
##
## Opciones (todas tras el `--`):
##   --seed=N      una sola semilla; por defecto las 4 del primer hito, `[11, 222, 3333, 44444]`
##   --step=N      paso de `tick`; por defecto 25, el del test de primera promoción. M0 vio que
##                 el paso no abarata nada y sí mueve la llegada, así que no se cambia a la ligera
##   --max=N       tope de la era 1, en ciclos; por defecto 260.000, el techo de tolerancia de H4
##   --until=h3    corta la era 1 en H3c, Ciudad (o en 32.400, su techo), y no mide H4: es el
##                 tramo que cabe en la suite. Por defecto `h4`
##   --full=1      no para en Región y recorre el tope entero: da el coste de reloj del tramo
##                 largo aunque el balance de hoy llegue antes
##   --no-proxy    la era 2 sin el proxy (M3 de «Plan - Gobernador por sello»): compra 🎖️ Consejo
##                 antes que nada y **solo** delega la raíz, sellándola con `Shop.use_seal` y el
##                 sello que regala Consejo. Lo demás nace sellado o no se delega. La era 1 sigue
##                 con la primitiva: jugada a mano no se mide
##
## Con el balance de M5 de «Plan - Balance de la era», Región cae en el 175.475 y la sonda tarda
## ~13 s de reloj por semilla (~52 s las 4). Con `--full=1`, hasta los 260.000, ~28 s. Con
## `--until=h3`, ~1 s por semilla.
##
## `ceiling_dump` dice **si** se puede llegar a un umbral; esto dice **cuándo**. Recorre una era
## headless con la raíz delegada en un gobernador equilibrado con todos los permisos y apunta el
## ciclo en que cae cada hito de la curva (Brain: «Plan - Ritmo de la era»):
##
##   H1 Pueblo · H2 primer hijo · H3 1.000 hab de pico · H3c Ciudad · H4 Región
##   H6 Pueblo en la era 2 · H7 1.000 hab de pico en la era 2 · H7c Ciudad en la era 2
##
## H3 y H3c caían juntos mientras Pueblo → Ciudad solo pedía 1.000 hab y 24 edificios. Desde M2
## de «Plan - Balance de la era» Ciudad pide además los 4 hijos (`Content.gd`), así que H3c lo
## marca el reloj de las expediciones y es **la columna con objetivo** (14.400-32.400). H3 queda
## como el momento en que la primera ascensión rinde (`Ascension.MIN_PEAK_POP`): informativo.
## También se apunta el ciclo en que la raíz llega a 1, 2, 3… hijos, y si alguno se pierde.
##
## **La era 2.** Al llegar a H3c (Ciudad) se calcula la ascensión con `Ascension.ascend`: se
## compara la era completa, como en `legacy_test` (en el juego también se puede ascender antes,
## en el pico de 1.000, pero rinde menos legado). `ascend` no toca el estado que deja
## atrás: la era 1 sigue hasta H4 (o H3c con `--until=h3`) y el mundo nuevo espera. Luego
## se gasta todo el legado con la política fija de `TestUtil.spend_legacy` —siempre el nodo
## comprable más barato, en el orden de `Legacy.nodes()` si empatan, y `Primeras piedras` solo
## cuando no queda otro: es el que más acelera H6, y comprarlo primero mediría ese nodo y no el
## árbol—, la misma que usa `legacy_test`, y se delega la raíz nueva igual que la primera. Ascender resiembra con `seed + era`: la era 2 de una semilla es
## otro mundo, así que H6, H7 y H7c se comparan con H1, H3 y H3c **como distribución** sobre las semillas,
## no semilla a semilla. Por eso el resumen da mínimo, máximo y la razón de las medianas.
##
## Va por `SimEngine.tick` a pasos grandes y nunca por la escena: el integrador es O(eventos) y
## lo que cuesta es el gobernador, que decide cada `governor_interval` ciclos. Mide con
## `TestUtil.cycles_until`, el mismo bucle que el test de primera promoción, con un predicado
## que apunta cada hito al pasar: una sola pasada por era, y un hito temprano no tapa a otro.
## El ciclo de llegada tiene una resolución de ±paso.

const TestUtil := preload("res://tools/TestUtil.gd")

const SEEDS := [11, 222, 3333, 44444]
const DEFAULT_STEP := 25.0
## Techo de tolerancia de H4: más allá ya no se está midiendo la curva, sino un fallo de balance.
const DEFAULT_MAX_CYCLES := 260000.0
## El techo de tolerancia de H3c (Ciudad): el coste hasta aquí es el que decide si cabe en la suite.
const H3_CEILING := 32400.0
## Cada cuántos ciclos se imprime el estado, para ver por dónde va una sonda larga.
const REPORT_EVERY := 20000.0

## Columnas de la tabla. `H3c` y `H7c` son la llegada a Ciudad en cada era; `H3c` es el objetivo.
const COLS := ["H1", "H2", "H3", "H3c", "H4", "H6", "H7", "H7c"]

## **Oro y cultura en la era 1** (M0 de «Plan - Sumidero de oro y cultura»). Solo se leen: ni una
## columna de estas toca el estado, así que los hitos de arriba no se mueven por medirlas.
## Instantáneas de 🪙 y 📜 del **subárbol** (la raíz y todos sus descendientes, como `total_pop`):
##   `H3c`  al llegar a Ciudad
##   `100k` la primera muestra en el ciclo 100.000 o después: a mitad del tramo Ciudad → Región
##   `6p`   la muestra justo **antes** de H4 (un paso antes): la cultura con la que llega el 6.º
##          pueblo, antes de promocionar. Es la que fija `N`, la influencia que pedirá Región
##   `H4`   al llegar a Región
const GOLD_SNAPS := ["H3c", "100k", "6p", "H4"]
## Ciclo de la instantánea `100k`.
const MID_CYCLE := 100000.0
## La 5.ª expedición de la raíz es la primera que sale siendo Ciudad (con el reloj ×7): la que
## calibra cuánto oro hay entre dos llegadas para pagar «⏩ Acelerar».
const CALIBRATION_EXPEDITION := 5
## Ventana de la primera Ciudad con la que se ajustan los precios de `data/Items.gd`: 1,5 h.
const SHOP_WINDOW := 5400.0


func _init() -> void:
	var args := _args()
	var seeds: Array = SEEDS
	if args.has("seed"):
		seeds = [int(args["seed"])]
	var step := float(args.get("step", str(DEFAULT_STEP)))
	var until_h3: bool = args.get("until", "h4") == "h3"
	var max_cycles := H3_CEILING if until_h3 else float(args.get("max", str(DEFAULT_MAX_CYCLES)))
	var full: bool = args.get("full", "0") == "1" and not until_h3
	var no_proxy: bool = args.get("no-proxy", "0") == "1"

	print("=== era_probe · paso %.0f · tope era 1 %.0f ciclos · %s%s ===" % [
		step, max_cycles, "hasta H3" if until_h3 else ("tope entero" if full else "hasta H4"),
		" · era 2 sin proxy" if no_proxy else "",
	])
	var rows: Array = []
	for seed_value in seeds:
		rows.append(_run(seed_value, step, max_cycles, until_h3, full, no_proxy))
	_table(rows)
	_summary(rows)
	_gold_table(rows)
	quit(0)


## Las dos eras de una semilla. Devuelve la fila: ciclo de cada hito (-1 si no llega), legado,
## nodos comprados y segundos de reloj de cada era.
func _run(
	seed_value: int, step: float, max_cycles: float, until_h3: bool, full: bool, no_proxy: bool
) -> Dictionary:
	var row := {
		"seed": seed_value, "legacy": 0.0, "bought": [], "clock1": 0.0, "clock2": 0.0,
		"arrivals": [], "lost": 0,
	}
	for c in COLS:
		row[c] = -1.0
	print("")
	print("--- semilla %d ---" % seed_value)

	# Era 1.
	var engine := TestUtil.make_engine(seed_value)
	var state := engine.state
	var root := state.root()
	# Delegar por la ruta única, para que lo que funde la raíz nazca delegado y crezca: Ciudad
	# pide hijos crecidos, y un hijo huérfano se queda en ~7 hab para siempre.
	GovernorSys.delegate(state, root, Governor.balanced())
	var started := Time.get_ticks_msec()
	var watch := {"next_report": REPORT_EVERY, "fresh": null, "kids": 0}
	# Oro y cultura (ver `GOLD_SNAPS`): la muestra anterior, para `6p`, y la 5.ª expedición.
	var gold_watch := {"prev": null, "rate_sum": 0.0, "trip": {}}
	row["snaps"] = {}
	row["gold_rate"] = -1.0
	row["gold_net"] = -1.0
	row["legacy_h4"] = -1.0
	var era1 := func() -> bool:
		_note(row, "H1", state, root.tier >= Content.TOWN or Promotion.can_promote(state, root))
		_note(row, "H2", state, root.children.size() > 0)
		_note(row, "H3", state, state.peak_pop >= 1000.0)
		_note(row, "H3c", state, root.tier >= Content.CITY)
		_note(row, "H4", state, root.tier >= Content.REGION)
		# Cuándo llega cada hijo (la primera vez que la raíz tiene k), y cuántos se pierden: con
		# 4 hijos obligatorios para Ciudad, un hijo que colapsa la retrasa una expedición entera.
		var kids := root.children.size()
		if kids < watch["kids"]:
			row["lost"] += watch["kids"] - kids
		watch["kids"] = kids
		while row["arrivals"].size() < kids:
			row["arrivals"].append(state.cycle)
		_watch_gold(row, gold_watch, state, root, engine.params)
		if watch["fresh"] == null and row["H3c"] >= 0.0:
			# Se asciende en Ciudad, la era «completa», igual que `legacy_test`: desde que Ciudad pide
			# 4 hijos, el pico de 1.000 hab llega ~10.000 ciclos antes y rinde 10 de legado, no 28.
			# Ascender a 1.000 hab sigue siendo posible en el juego; lo que se compara es la era entera.
			# El mundo nuevo se calcula ya, con el pico y la escala de ahora; `ascend` no toca este.
			watch["fresh"] = Ascension.ascend(state, engine.params, null)
			row["legacy"] = Ascension.reward(state)
			print("  H3c (Ciudad) en %.2f s de reloj: ascender rendiría %.0f de legado (%.0f por cultura; pico %.0f, %s)" % [
				(Time.get_ticks_msec() - started) / 1000.0, row["legacy"],
				Ascension.culture_reward(state), state.peak_pop, root.def().name,
			])
		if state.cycle >= watch["next_report"]:
			watch["next_report"] += REPORT_EVERY
			print("    · ciclo %8.0f: %s, %.0f hab de subárbol, %d hijos, %d nodos, %.1f s" % [
				state.cycle, root.def().name, root.total_pop, root.children.size(),
				state.nodes.size(), (Time.get_ticks_msec() - started) / 1000.0,
			])
		if until_h3:
			return watch["fresh"] != null and row["H3c"] >= 0.0
		return row["H4"] >= 0.0 and not full
	TestUtil.cycles_until(engine, era1, max_cycles, step)
	row["clock1"] = (Time.get_ticks_msec() - started) / 1000.0
	print("  era 1: %.0f ciclos en %.2f s de reloj — %s, %.0f hab de pico, %d nodos" % [
		state.cycle, row["clock1"], root.def().name, state.peak_pop, state.nodes.size(),
	])
	var arrivals := PackedStringArray()
	for at in row["arrivals"]:
		arrivals.append("%.0f" % at)
	print("  hijos de la raíz: llegan en %s · perdidos %d" % [", ".join(arrivals), row["lost"]])
	_release(engine)

	var fresh: WorldState = watch["fresh"]
	if fresh == null or fresh.era < 2:
		print("  sin H3 no hay ascensión: la era 2 no se mide")
		return row

	# Era 2: el mundo nuevo entra por el mismo camino que en el juego (`adopt`), se gasta el
	# legado y se delega la raíz nueva.
	engine = TestUtil.make_engine(seed_value)
	engine.adopt(fresh)
	state = engine.state
	root = state.root()
	if no_proxy:
		# Sin proxy: Consejo primero —sin él no se delega nada—, el resto con la política de
		# siempre, y la raíz por la ruta del jugador (🛒 «Usar aquí»). Sin sello no hay era 2.
		var council := PackedStringArray()
		if Ascension.buy(state, "council", null):
			council.append("council")
		row["bought"] = council + TestUtil.spend_legacy(state)
		var sealed := Shop.use_seal(state, root, false, null)
		print("  era 2 sin proxy: %d 🎖️ en el inventario al empezar, la raíz %s" % [
			Shop.count_of(state, "seal") + sealed,
			"sellada y delegada" if sealed == 1
				else "sin sellar: %s" % Shop.use_blocker(state, root, "seal", false),
		])
		if sealed != 1:
			print("  sin sello en la raíz la era 2 no se mide")
			_release(engine)
			return row
	else:
		row["bought"] = TestUtil.spend_legacy(state)
		GovernorSys.delegate(state, root, Governor.balanced())
	print("  era 2: legado %.0f → %s (sobra %.0f)" % [
		row["legacy"], ", ".join(row["bought"]), state.legacy,
	])
	started = Time.get_ticks_msec()
	var era2 := func() -> bool:
		_note(row, "H6", state, root.tier >= Content.TOWN or Promotion.can_promote(state, root))
		_note(row, "H7", state, state.peak_pop >= 1000.0)
		_note(row, "H7c", state, root.tier >= Content.CITY)
		return row["H6"] >= 0.0 and row["H7"] >= 0.0 and row["H7c"] >= 0.0
	TestUtil.cycles_until(engine, era2, max_cycles, step)
	row["clock2"] = (Time.get_ticks_msec() - started) / 1000.0
	print("  era 2: %.0f ciclos en %.2f s de reloj" % [state.cycle, row["clock2"]])
	_release(engine)
	return row


## Una muestra de 🪙 y 📜, sin tocar el estado:
##   `gold`, `culture`  stock del subárbol (raíz + descendientes, el recorrido de `subtree_pop`)
##   `root_gold`        oro de la raíz, que es la que pagaría «⏩ Acelerar» su expedición
##   `cap`              su tope de oro (`storage_caps`): el oro sí lo tiene, la cultura no
##   `rate`             su tasa de oro **sin fijar**: la de `Integrator.build_segment`, la misma
##                      que integra la simulación, sin el cero que `snapshot` pone a un stock a
##                      tope. Es lo que la raíz produciría si tuviera dónde guardarlo y no gastase
##                      en mejoras: el ingreso con el que se calibra el precio de acelerar
static func _gold_sample(state: WorldState, root: SimNode, params: SimParams) -> Dictionary:
	var mods := SimEngine.delegated_modifiers(state, params) if root.is_delegated() \
			else Integrator.Modifiers.none()
	var seg := Integrator.build_segment(root, params, mods)
	return {
		"cycle": state.cycle,
		"gold": _subtree_stock(state, root.id, Goods.GOLD),
		"culture": _subtree_stock(state, root.id, Goods.CULTURE),
		"root_gold": root.stocks[Goods.GOLD],
		"cap": root.storage_caps(params)[Goods.GOLD],
		"rate": seg.slope[Goods.GOLD] * root.pop + seg.offset[Goods.GOLD],
		"culture_rate": seg.slope[Goods.CULTURE] * root.pop + seg.offset[Goods.CULTURE],
	}


## Stock de un recurso en un subárbol, con el mismo recorrido que `WorldState.subtree_pop`.
static func _subtree_stock(state: WorldState, id: int, good: int) -> float:
	var node: SimNode = state.nodes.get(id)
	if node == null:
		return 0.0
	var total := node.stocks[good]
	for child in node.children:
		total += _subtree_stock(state, child, good)
	return total


## Lleva las columnas de oro y cultura de la era 1. Solo mira desde Ciudad: antes no hay mercado
## ni templo. Se llama tras cada `tick` del bucle de `cycles_until`, así que la resolución es el
## paso, como la de los hitos.
static func _watch_gold(
	row: Dictionary, gw: Dictionary, state: WorldState, root: SimNode, params: SimParams
) -> void:
	if row["H3c"] < 0.0:
		return
	var s := _gold_sample(state, root, params)
	var prev = gw["prev"]
	var dt: float = s["cycle"] - prev["cycle"] if prev != null else 0.0
	var snaps: Dictionary = row["snaps"]
	if not snaps.has("H3c"):
		snaps["H3c"] = s
	if s["cycle"] >= MID_CYCLE and not snaps.has("100k"):
		snaps["100k"] = s
	# 🛒 Precios de la tienda (M5 de «Plan - Objetos de tiempo»): el oro sin fijar que produce la
	# raíz en su primera hora y media como Ciudad, y su tasa al cerrarla.
	if not snaps.has("shop"):
		gw["shop_income"] = gw.get("shop_income", 0.0) + s["rate"] * dt
		gw["shop_culture"] = gw.get("shop_culture", 0.0) + s["culture_rate"] * dt
		if s["cycle"] >= row["H3c"] + SHOP_WINDOW:
			snaps["shop"] = s
			row["shop_income"] = gw["shop_income"]
			row["shop_culture"] = gw["shop_culture"]
	# Ritmo de oro de la raíz entre Ciudad y Región: la tasa sin fijar, integrada muestra a muestra.
	if row["H4"] < 0.0:
		gw["rate_sum"] += s["rate"] * dt
	elif not snaps.has("H4"):
		snaps["H4"] = s
		# H4 cae en el mismo tick que el 6.º pueblo: la muestra anterior es el «justo antes».
		snaps["6p"] = prev if prev != null else s
		gw["rate_sum"] += s["rate"] * dt
		var span: float = row["H4"] - row["H3c"]
		row["gold_rate"] = gw["rate_sum"] / span
		row["gold_net"] = (s["root_gold"] - snaps["H3c"]["root_gold"]) / span
		# El legado por población si se ascendiera ahora, en Región: pico y escala de entonces.
		# Solo la parte de población: desde M2 `reward` suma también la cultura, y la cuenta de
		# CPL de `_gold_table` la compara contra la población sola.
		row["legacy_h4"] = Ascension.pop_reward(state)
		row["culture_h4"] = Ascension.culture_reward(state)
	# La 5.ª expedición de la raíz: sale con 4 hijos y llega con el 5.º.
	var trip: Dictionary = gw["trip"]
	var e := state.expedition_of(root.id)
	if trip.is_empty() and e != null and row["arrivals"].size() == CALIBRATION_EXPEDITION - 1:
		trip.merge({
			"depart": e.depart_cycle, "arrive": e.arrive_cycle, "gold0": s["root_gold"],
			"income": 0.0, "income_half": 0.0, "steps": 0, "full_steps": 0, "max_gold": 0.0,
			"cap_max": 0.0, "done": false,
		})
		row["trip"] = trip
	elif not trip.is_empty() and not trip["done"]:
		trip["income"] += s["rate"] * dt
		if s["cycle"] <= (trip["depart"] + trip["arrive"]) / 2.0:
			trip["income_half"] += s["rate"] * dt
		trip["steps"] += 1
		if s["root_gold"] >= s["cap"] * 0.999:
			trip["full_steps"] += 1
		trip["max_gold"] = maxf(trip["max_gold"], s["root_gold"])
		trip["cap_max"] = maxf(trip["cap_max"], s["cap"])
		if row["arrivals"].size() >= CALIBRATION_EXPEDITION:
			trip["done"] = true
			trip["gold1"] = s["root_gold"]
	gw["prev"] = s


## Apunta el ciclo de un hito la primera vez que su predicado pasa.
static func _note(row: Dictionary, col: String, state: WorldState, passed: bool) -> void:
	if passed and row[col] < 0.0:
		row[col] = state.cycle


## `SimEngine` es un `Node` fuera del árbol: nadie lo libera por nosotros.
static func _release(engine: SimEngine) -> void:
	TestUtil._engines.erase(engine)
	engine.free()


## Una fila por semilla, una columna por hito, en ciclos.
static func _table(rows: Array) -> void:
	print("")
	var header := "semilla "
	for c in COLS:
		header += "%9s" % c
	header += "  legado  reloj1  reloj2  nodos"
	print(header)
	for row in rows:
		var line := "%7d " % row["seed"]
		for c in COLS:
			line += "%9s" % (("%.0f" % row[c]) if row[c] >= 0.0 else "—")
		line += "  %6.0f  %5.2fs  %5.2fs  %s" % [
			row["legacy"], row["clock1"], row["clock2"], ",".join(row["bought"]),
		]
		print(line)


## Mínimo y máximo de cada hito sobre las semillas, y cuánto acorta la era 2: razón de las
## medianas (y de las medias) de H6/H1, H7/H3 y H7c/H3c. Por debajo de 0,5 es «≥ 50 % antes».
static func _summary(rows: Array) -> void:
	print("")
	var stats := {}
	for c in COLS:
		var values: Array = []
		for row in rows:
			if row[c] >= 0.0:
				values.append(row[c])
		values.sort()
		stats[c] = values
		if values.is_empty():
			print("  %-4s no llega en ninguna semilla" % c)
			continue
		print("  %-4s mín %8.0f  máx %8.0f  mediana %8.0f  (%d/%d semillas)" % [
			c, values[0], values[-1], _median(values), values.size(), rows.size(),
		])
	for pair in [["H6", "H1"], ["H7", "H3"], ["H7c", "H3c"]]:
		var era2: Array = stats[pair[0]]
		var era1: Array = stats[pair[1]]
		if era2.is_empty() or era1.is_empty():
			print("  %s/%s sin datos" % pair)
			continue
		print("  %s/%s: razón de medianas %.2f · de medias %.2f" % [
			pair[0], pair[1], _median(era2) / _median(era1), _mean(era2) / _mean(era1),
		])


## Lo que recorta y encarece «⏩ Acelerar» según el plan (M3 los vuelve `SimParams`): cada vez
## quita este tanto de lo que queda, y la siguiente cuesta ×`ACCEL_GROWTH`.
const ACCEL_FRACTION := 0.25
const ACCEL_GROWTH := 1.5


## Ciclos·precio de las `n` primeras aceleraciones seguidas al salir, en unidades de `k × T` (T,
## la duración del viaje): Σ f·(1−f)^i·g^i. Con 3 da 0,848 y con 4, 1,204.
static func _accel_units(n: int) -> float:
	var total := 0.0
	for i in n:
		total += ACCEL_FRACTION * pow(1.0 - ACCEL_FRACTION, i) * pow(ACCEL_GROWTH, i)
	return total


## Oro y cultura de la era 1 por semilla, y lo que se deduce para los tres valores de M0:
##   `N`    = 60-80 % de √(📜 del subárbol en `6p`)
##   `CPL`  (`CULTURE_PER_LEGACY`) = 📜 en H4 / (legado por población en H4)²: así
##          ⌊√(📜/CPL)⌋ iguala al legado por población
##   `k`    (`accelerate_gold_per_cycle`): el oro sin fijar de la raíz en la primera mitad de la
##          5.ª expedición, G½, paga 3 aceleraciones al salir y no 4 ⇒ G½/(1,204·T) < k ≤ G½/(0,848·T)
static func _gold_table(rows: Array) -> void:
	print("")
	print("oro (🪙) y cultura (📜) del subárbol, era 1:")
	var header := "semilla "
	for snap in GOLD_SNAPS:
		header += "%22s" % ("%s 🪙/📜" % snap)
	print(header + "  ciclo 6p")
	for row in rows:
		var line := "%7d " % row["seed"]
		var snaps: Dictionary = row.get("snaps", {})
		for snap in GOLD_SNAPS:
			line += "%22s" % (("%.0f/%.0f" % [snaps[snap]["gold"], snaps[snap]["culture"]])
					if snaps.has(snap) else "—")
		line += "  %s" % (("%.0f" % snaps["6p"]["cycle"]) if snaps.has("6p") else "—")
		print(line)
	print("")
	print("🛒 la primera Ciudad, de H3c a H3c + %.0f ciclos (precios de data/Items.gd):" % SHOP_WINDOW)
	for row in rows:
		var snaps: Dictionary = row.get("snaps", {})
		if not snaps.has("shop"):
			print("  %d: sin datos" % row["seed"])
			continue
		print("  %d: 🪙 sin fijar %.0f en la ventana (%.3f 🪙/ciclo de media) · tasa al cerrarla %.3f · 🪙 raíz %.0f (tope %.0f) · 📜 %.0f (%.3f/ciclo)" % [
			row["seed"], row["shop_income"], row["shop_income"] / SHOP_WINDOW,
			snaps["shop"]["rate"], snaps["shop"]["root_gold"], snaps["shop"]["cap"],
			row["shop_culture"], row["shop_culture"] / SHOP_WINDOW,
		])
	print("")
	print("raíz entre Ciudad y Región, y la 5.ª expedición (la 1.ª como Ciudad):")
	for row in rows:
		var snaps: Dictionary = row.get("snaps", {})
		if not snaps.has("H4"):
			print("  %d: sin H4, sin ritmo" % row["seed"])
			continue
		print("  %d: tope 🪙 %.0f en H3c → %.0f en H4 · ritmo sin fijar %.3f 🪙/ciclo · neto %.3f · legado por población en H4 %.0f (+%.0f por cultura)" % [
			row["seed"], snaps["H3c"]["cap"], snaps["H4"]["cap"], row["gold_rate"],
			row["gold_net"], row["legacy_h4"], row.get("culture_h4", 0.0),
		])
		var c6: float = snaps["6p"]["culture"]
		var cpl: float = snaps["H4"]["culture"] / pow(row["legacy_h4"], 2.0) if row["legacy_h4"] > 0.0 else INF
		print("      N 60-80 %% de √%.0f = %.1f-%.1f · CPL ≈ %.1f" % [
			c6, 0.6 * sqrt(c6), 0.8 * sqrt(c6), cpl,
		])
		var trip: Dictionary = row.get("trip", {})
		if trip.is_empty() or not trip.get("done", false):
			print("      5.ª expedición no medida")
			continue
		var t: float = trip["arrive"] - trip["depart"]
		print("      viaje %.0f→%.0f (T %.0f) · 🪙 raíz %.0f al salir, %.0f al llegar, máx %.0f, tope %.0f, a tope %.0f %% del viaje" % [
			trip["depart"], trip["arrive"], t, trip["gold0"], trip["gold1"], trip["max_gold"],
			trip["cap_max"], 100.0 * trip["full_steps"] / maxf(trip["steps"], 1.0),
		])
		print("      ingreso sin fijar %.0f (G½ %.0f) · k para 3 sí y 4 no: %.4f < k ≤ %.4f · 3 aceleraciones cuestan %.3f·k·T" % [
			trip["income"], trip["income_half"], trip["income_half"] / (_accel_units(4) * t),
			trip["income_half"] / (_accel_units(3) * t), _accel_units(3),
		])


static func _median(sorted_values: Array) -> float:
	var n := sorted_values.size()
	if n % 2 == 1:
		return sorted_values[n / 2]
	return (sorted_values[n / 2 - 1] + sorted_values[n / 2]) / 2.0


static func _mean(values: Array) -> float:
	var total := 0.0
	for v in values:
		total += v
	return total / values.size()


## `--clave=valor` tras el `--` de la línea de órdenes.
static func _args() -> Dictionary:
	var out := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and a.contains("="):
			var kv := a.substr(2).split("=", true, 1)
			out[kv[0]] = kv[1]
		elif a.begins_with("--"):
			out[a.substr(2)] = "1"  # interruptor sin valor, como `--no-proxy`
	return out
