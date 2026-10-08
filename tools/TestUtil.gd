extends RefCounted
## Utilidades compartidas por los tests headless.
##
## Los tests **tienen que vivir en `tools/` dentro del proyecto**: el snap de Godot no puede
## leer `/tmp`, así que un script de test fuera del proyecto no se carga.


## Motores creados por el test, para liberarlos al final: `SimEngine` es un `Node` y aquí
## nunca entra en el árbol de escena, así que nadie lo libera por nosotros.
static var _engines: Array[SimEngine] = []


## Motor listo para test: sin log de eventos (ni ring buffer ni JSONL) y con params limpios.
static func make_engine(seed_value: int, params: SimParams = null) -> SimEngine:
	var engine := SimEngine.new()
	if params != null:
		engine.params = params
	engine.events.enabled = false
	engine.events.write_files = false
	engine.start(seed_value)
	_engines.append(engine)
	return engine


## **Un hijo ya fundado, para montar un escenario**: lanza la expedición por la ruta de siempre
## (`Promotion.launch_expedition`, con su lista de condiciones) y la hace llegar en el acto, sin
## avanzar el reloj. Es lo que hacía `found_child` antes de que fundar tardara. Para los tests que
## necesitan la colonia como punto de partida; los que miden fundar esperan a la llegada de verdad.
## `null` si no se puede fundar.
static func found_now(
	state: WorldState, node: SimNode, params: SimParams, events: SimEventLog = null,
	policy: Governor = null
) -> SimNode:
	var sent := Promotion.launch_expedition(state, node, params, events, policy)
	if sent == null:
		return null
	state.cancel_expedition_of(node.id)
	return Promotion.arrive(state, sent, events)


## El escenario del spike de rutas (M1): un pueblo y la colonia que funda, con una ruta de comida
## de 0,5/ciclo del pueblo a la colonia. El pueblo come más de lo que su campo da, así que su
## almacén se vacía y la ruta se corta y vuelve en cada checkpoint: es el caso que decide si una
## ruta crea comida de la nada.
static func make_routed_engine(seed_value: int, good := Goods.FOOD, rate := 0.5) -> SimEngine:
	var engine := make_engine(seed_value)
	var state := engine.state
	var root := state.root()
	root.tier = Content.TOWN
	root.pop = 500.0
	root.stocks[Goods.FOOD] = 500.0
	# Desde M2 una ruta gasta 🐎 por cada unidad de caudal (`Logistics.TRANSPORT_PER_FLOW`), y sin
	# transporte se cortaría en el instante cero: el spike mediría una ruta que no circula. Desde
	# M3 lo paga el **padre** y no el origen; aquí la ruta baja de la raíz al hijo, así que la raíz
	# es las dos cosas y el almacén lleno sigue haciendo falta, ahora porque es el padre.
	# Un pueblo no tiene establos, así que el almacén de 🐎 empieza lleno: a 0,25/ciclo da para
	# 6.400 ciclos, de sobra para los tests de M1 salvo el día fuera de `catchup_test`, donde se
	# acaba a mitad y la ruta pasa a cortarse en cada checkpoint, que también tiene que dar el
	# mismo estado troceado que de un tirón. Sin establos con mozos a propósito: en un pueblo de
	# 10 de alojamiento le quitarían brazos a la granja y el pueblo se moriría de hambre.
	root.stocks[Goods.TRANSPORT] = root.storage_caps(engine.params)[Goods.TRANSPORT]
	state.refresh_totals()
	var child := found_now(state, root, engine.params)
	if child != null:
		Logistics.set_route(state, root.id, child.id, good, rate)
	return engine


## El escenario del gobernador regional (M4): una región delegada con dos hijos sin delegar, uno
## con granjas de sobra (`children[0]`) y otro con más casas de las que su campo alimenta
## (`children[1]`). Hay además una ruta de 🪵 hecha a mano, que con `may_route` el gobernador tiene
## que quitar: delegar es entregarle **todas** las rutas. Los hijos no están delegados: su reparto
## no cambia, así que lo único que puede sacar al hambriento del hambre es la comida que le llega.
static func make_regional_engine(seed_value: int, may_route := true) -> SimEngine:
	var engine := make_engine(seed_value)
	var state := engine.state
	var params := engine.params
	var root := state.root()
	var farm := Content.building_index("farm")
	var hut := Content.building_index("hut")
	var woodcutter := Content.building_index("woodcutter")
	var stables := Content.building_index("stables")
	root.tier = Content.REGION
	root.pop = 200.0
	root.stocks[Goods.FOOD] = 1.0e4
	root.buildings[hut] = 40
	root.buildings[farm] = 30
	root.buildings[stables] = 4
	state.refresh_totals()
	# La región se alimenta sola, con poco de sobra (1,5 🌾/ciclo en su techo de 210), y paga 4
	# 🐎/ciclo: 8 de caudal. Le sobra menos que al rico, así que la comida tiene que pasar por ella.
	Construction.set_workers(root, farm, 90.0)
	Construction.set_workers(root, stables, 16.0)
	var rich := found_now(state, root, params)
	var hungry := found_now(state, root, params)
	# El rico: 30 granjeros (18 🌾/ciclo) para un techo de 50; le sobran 5,5 🌾/ciclo.
	rich.pop = 40.0
	rich.buildings[hut] = 8
	rich.buildings[farm] = 10
	rich.jobs[farm] = 30.0
	rich.jobs[woodcutter] = 0.0
	# El hambriento: 10 granjeros dan de comer a 24 y hay 30 bajo un techo de 50. Con el tope de
	# dependencia (50 %) lo importado le sube el techo hasta 36, que ya basta.
	hungry.pop = 30.0
	hungry.buildings[hut] = 8
	hungry.buildings[farm] = 4
	hungry.jobs[farm] = 10.0
	hungry.jobs[woodcutter] = 0.0
	state.refresh_totals()
	Logistics.set_route(state, rich.id, root.id, Goods.WOOD, 0.5)

	# Solo repartir y, si se le deja, las rutas: lo demás movería el escenario.
	var g := Governor.balanced()
	g.may_build = false
	g.may_research = false
	g.may_promote = false
	g.may_expand = false
	g.may_route = may_route
	GovernorSys.delegate(state, root, g)
	return engine


## **El ciclo en que algo pasa**, midiendo como mide el ritmo: `engine.tick(step)` a pasos fijos
## y mirando `predicate` al final de cada uno. Lo usan `_first_promotion_pacing` y `era_probe`, y
## tienen que seguir usando este mismo bucle: si la sonda y los tests midieran por separado, la
## curva que se ajusta con una dejaría de ser la que vigilan los otros.
##
## Devuelve `engine.state.cycle` tras el `tick` en que el predicado pasa, así que la resolución
## es de ±`step`. Si ya se cumple al llamar, devuelve el ciclo actual **sin tickear**: se puede
## encadenar (un hito, luego el siguiente desde donde va el motor) sin perder pasos. Si llega a
## `max_cycles` (ciclo absoluto, no relativo a la llamada) sin cumplirse, devuelve -1.
##
## El predicado se evalúa una vez por paso y puede apuntar cosas por el camino: es como la sonda
## mide varios hitos en una sola pasada sin que uno temprano tape a otro.
static func cycles_until(
	engine: SimEngine, predicate: Callable, max_cycles: float, step: float
) -> float:
	if predicate.call():
		return engine.state.cycle
	while engine.state.cycle < max_cycles:
		engine.tick(step)
		if predicate.call():
			return engine.state.cycle
	return -1.0


## **La política fija de gasto del legado**: el nodo comprable más barato, en el orden de
## `Legacy.nodes()` si empatan, y `Primeras piedras` solo cuando es lo único que queda —regala
## stock al empezar y es el que más acelera la era 2: comprarlo primero mediría ese nodo y no el
## árbol—. Gasta hasta que no llega para nada y devuelve los ids comprados, en orden.
##
## La usan `era_probe` y `_the_second_era_is_faster` (`legacy_test.gd`), y tienen que seguir
## usando esta: es el mismo argumento que `cycles_until`. Si la sonda gastara de una forma y el
## test de otra, la era 2 que se ajusta con una dejaría de ser la que vigila el otro.
static func spend_legacy(state: WorldState) -> PackedStringArray:
	var bought := PackedStringArray()
	while true:
		var best: Legacy.Node_ = null
		var best_cost := INF
		var stones: Legacy.Node_ = null
		for def: Legacy.Node_ in Legacy.nodes():
			if not Ascension.can_buy(state, def.id):
				continue
			if def.id == "first_stones":
				stones = def
				continue
			var cost := def.cost_for(Ascension.rank_of(state, def.id))
			if cost < best_cost:
				best = def
				best_cost = cost
		if best == null:
			best = stones
		if best == null:
			break
		Ascension.buy(state, best.id, null)
		bought.append(best.id)
	return bought


## Notación científica: el `%` de GDScript no tiene `%e`.
static func sci(value: float) -> String:
	return String.num_scientific(value)


## Error relativo entre dos magnitudes, tolerante al cero.
static func rel_error(a: float, b: float) -> float:
	var scale := maxf(absf(a), absf(b))
	if scale < 1.0e-9:
		return 0.0
	return absf(a - b) / scale


static func check(condition: bool, ok_message: String, fail_message: String) -> int:
	if condition:
		print("OK  " + ok_message)
		return 0
	print("FALLO: " + fail_message)
	return 1


static func finish(tree: SceneTree, failures: int) -> void:
	for engine in _engines:
		engine.free()
	_engines.clear()
	print("")
	if failures == 0:
		print("=== TODO EN VERDE ===")
	else:
		print("=== %d COMPROBACIÓN(ES) EN ROJO ===" % failures)
	tree.quit(0 if failures == 0 else 1)
