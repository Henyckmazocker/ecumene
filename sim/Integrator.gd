class_name Integrator
extends RefCounted

## El corazón de la arquitectura: avanza un nodo agregado `dt` ciclos **en forma cerrada**.
##
## No hay dos caminos "online" y "offline". Hay uno: `advance(node, params, dt, mult)`.
## El tick del juego lo llama con `dt = 1` ciclo; el catch-up al volver de estar cerrado lo
## llama con `dt = 40000`. El resultado es el mismo porque la solución analítica es
## **componible**: avanzar 1+1+1 da lo mismo que avanzar 3 (salvo error de coma flotante).
##
## Cómo puede ser cerrado:
##
##   1. La población sigue una logística hacia el alojamiento `K` (o decae exponencialmente
##      si hay hambruna). Ambas tienen solución exacta.
##   2. La producción es **lineal en la población** (contrato de `BuildingDef`), así que
##      `dR/dt = a·P(t) + b`, y `∫P dt` de una logística también tiene forma cerrada.
##   3. Lo que rompe la linealidad son eventos discretos —un stock que toca su tope o llega
##      a cero, un edificio que se queda sin puestos libres—. En vez de simular, se **resuelve
##      el instante** en que ocurre el primer evento, se avanza exactamente hasta ahí, se
##      recalcula el segmento y se sigue.
##
## Coste: O(nº de eventos), no O(nº de ciclos). Un asentamiento típico resuelve un día
## offline en un puñado de segmentos.

const EPS := 1.0e-9
## Por encima de esto, `exp` desborda: las fórmulas están escritas para no llegar nunca.
const SCAN_SAMPLES := 16


## Multiplicadores externos que entran en el tramo. Son **constantes** dentro de un segmento
## (bonos de legado, eficiencia de gobernador, penalización offline): por eso se pueden meter
## en la solución analítica sin romperla. Cualquier bono que dependiera del tiempo o del
## estado tendría que convertirse en un evento de segmento, no en un factor.
class Modifiers:
	extends RefCounted
	var production: float = 1.0   ## toda la producción y el consumo de los edificios
	var food: float = 1.0         ## extra solo sobre la producción de comida
	var growth: float = 1.0       ## sobre la tasa de crecimiento de población
	var housing: float = 1.0      ## sobre el techo de población
	## Multiplicador de producción por tipo de edificio. Vacío = todo a 1.
	var per_building := PackedFloat64Array()

	static func none() -> Modifiers:
		return Modifiers.new()

	func scaled(factor: float) -> Modifiers:
		var m := Modifiers.new()
		m.production = production * factor
		m.food = food
		m.growth = growth
		m.housing = housing
		m.per_building = per_building.duplicate()
		return m

	## Compone los bonos globales (legado) con las mejoras **de este nodo**. Los efectos que
	## solo pueden venir del nodo —puestos y almacenamiento— no pasan por aquí: los aplican
	## `Construction.capacity_of` y `SimNode.storage_caps` leyendo la caché del nodo.
	func combined(effects: Upgrades.Effects) -> Modifiers:
		var m := Modifiers.new()
		m.production = production * effects.production
		m.food = food * effects.food
		m.growth = growth * effects.growth
		m.housing = housing  # `SimNode.housing()` ya aplica el de las mejoras
		m.per_building = effects.per_building.duplicate()
		if per_building.size() == m.per_building.size():
			for i in m.per_building.size():
				m.per_building[i] *= per_building[i]
		return m

	func for_building(index: int) -> float:
		return per_building[index] if index < per_building.size() else 1.0


## Un tramo de tiempo en el que la dinámica es lineal y tiene solución exacta.
class Segment:
	extends RefCounted
	var housing: float = 0.0        ## techo de población efectivo (K de la logística)
	var raw_housing: float = 0.0    ## techo por alojamiento, antes de mirar la comida
	var food_capacity: float = 0.0  ## a cuánta gente da de comer este reparto de trabajo
	var rate: float = 0.0           ## r > 0 logística hacia K, r < 0 decaimiento exponencial
	var starving: bool = false      ## la comida es el límite Y sobra población
	var food_limited: bool = false  ## la comida manda por encima del alojamiento
	var slope := Goods.zeros()      ## a: parte de dR/dt proporcional a la población
	var offset := Goods.zeros()     ## b: parte constante (edificios saturados)
	var caps := Goods.zeros()
	var pinned := PackedInt32Array()  ## 1 = el stock está fijado (a tope o a cero)
	## Poblaciones a las que un centro de trabajo pasa de tener puestos libres a saturado.
	var thresholds := PackedFloat64Array()

	func _init() -> void:
		pinned.resize(Goods.COUNT)


## Primer instante, dentro de un `advance`, en que cada stock queda **fijado** a cero o a su tope.
## INF si no llega a fijarse. Solo lo pide `Logistics` en sus sondas: una ruta no puede seguir
## sacando de un almacén vacío ni metiendo en uno lleno, y este es el aviso de que va a pasar.
##
## Se anota al construir el tramo y no al resolver el evento: lo que importa no es que el stock
## *toque* el cero, sino que se quede ahí porque la tasa total no le deja salir.
class Pins:
	extends RefCounted
	var empty_at := PackedFloat64Array()
	var full_at := PackedFloat64Array()

	func _init() -> void:
		empty_at.resize(Goods.COUNT)
		empty_at.fill(INF)
		full_at.resize(Goods.COUNT)
		full_at.fill(INF)

	func record(node: SimNode, seg: Segment, elapsed: float) -> void:
		for i in Goods.COUNT:
			if seg.pinned[i] == 0:
				continue
			if node.stocks[i] <= EPS:
				if empty_at[i] == INF:
					empty_at[i] = elapsed
			elif full_at[i] == INF:
				full_at[i] = elapsed


# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------

## Avanza el nodo `dt` ciclos. Devuelve el número de segmentos consumidos, útil para los
## tests y para detectar dinámicas patológicas.
##
## `pins`, si se pasa, anota cuándo se fija cada stock (ver `Pins`). No cambia nada de la cuenta:
## es un testigo, y sin él el camino es el de siempre, bit a bit.
static func advance(
	node: SimNode, params: SimParams, dt: float, mods: Modifiers = null, pins: Pins = null
) -> int:
	if dt <= EPS:
		return 0
	if mods == null:
		mods = Modifiers.none()
	var remaining := dt
	var elapsed := 0.0
	var segments := 0
	while remaining > EPS and segments < params.max_segments:
		segments += 1
		var seg := build_segment(node, params, mods)
		if pins != null:
			pins.record(node, seg, elapsed)
		var step := _next_event_time(node, seg, remaining, params)
		_apply(node, seg, step)
		remaining -= step
		elapsed += step
	if remaining > EPS:
		# Salvaguarda: dinámica que genera eventos sin parar. Se avanza el resto de un tirón;
		# es menos exacto, pero acotado y nunca cuelga el juego.
		var seg := build_segment(node, params, mods)
		_apply(node, seg, remaining)
	return segments


## Construye el tramo lineal válido a partir del estado actual del nodo.
static func build_segment(node: SimNode, params: SimParams, base_mods: Modifiers) -> Segment:
	# Los bonos globales (legado) se componen aquí con las mejoras propias del nodo: a partir
	# de este punto hay un único juego de multiplicadores y nadie tiene que acordarse de
	# aplicar dos.
	var mods := base_mods.combined(node.effects())
	var seg := Segment.new()
	seg.housing = node.housing(params) * mods.housing
	seg.caps = node.storage_caps(params)

	var pop := maxf(node.pop, 0.0)
	var wanted := requested_workers(node)
	var wanted_total := 0.0
	for w in wanted:
		wanted_total += w

	# a·P + b. Con el reparto manual de oficios hay dos regímenes, y ninguno rompe la
	# linealidad de la que depende la forma cerrada:
	#
	#   - Hay gente de sobra: cada puesto pedido se cubre y la producción es una **constante**
	#     (todo va a `offset`, con pendiente cero). Que sobre población no produce más.
	#   - No llega la gente: se reparte en proporción a lo pedido, y la producción vuelve a
	#     ser **proporcional a la población** (todo va a `slope`).
	var short_handed := wanted_total > pop + EPS and wanted_total > EPS
	for bi in node.buildings.size():
		if wanted[bi] <= 0.0:
			continue
		var b := Content.building(bi)
		var boost := mods.for_building(bi)
		if short_handed:
			var share := wanted[bi] / wanted_total
			for i in Goods.COUNT:
				seg.slope[i] += share * _net(b, i, mods) * boost
		else:
			for i in Goods.COUNT:
				seg.offset[i] += wanted[bi] * _net(b, i, mods) * boost

	# La población a la que se cruza entre los dos regímenes es una frontera de tramo: por
	# debajo del total asignado, los puestos dejan de cubrirse.
	if wanted_total > EPS:
		seg.thresholds.append(wanted_total)

	# Producción bruta de comida antes de descontar lo que come la gente: hace falta aparte
	# para calcular a cuánta población da de comer este reparto de trabajo.
	var food_slope := seg.slope[Goods.FOOD]
	var food_offset := seg.offset[Goods.FOOD]

	# Rutas: un término constante más, −caudal en el origen y +caudal en el destino (y el 🐎 que
	# paga el origen). Lo fija `Logistics` en su checkpoint y no depende de `P`, así que el tramo
	# sigue siendo `a·P + b` y cada nodo sigue avanzando solo. Va **después** de capturar la
	# comida de los edificios a propósito: lo importado no se suma a `food_offset` tal cual, sino
	# aparte y con tope (`_food_capacity`). Sin rutas el array está vacío y no se suma ni un cero.
	var food_imported := 0.0
	if not node.route_offset.is_empty():
		for i in Goods.COUNT:
			seg.offset[i] += node.route_offset[i]
		# Solo la comida que **entra en neto**: exportar no baja el techo, como antes de M2.
		food_imported = maxf(node.route_offset[Goods.FOOD], 0.0)

	# El consumo de comida por habitante NO lo escalan los bonos: comer se come igual
	# offline y con o sin legado. Solo la producción se multiplica.
	seg.slope[Goods.FOOD] -= params.food_per_pop

	# El techo de población es el menor de los dos límites reales: dónde meter a la gente
	# y a cuánta gente da de comer el campo.
	#
	# Que la comida entre como **techo** y no como un modo de hambruna aparte es lo que
	# mantiene la simulación estable: la población se acerca asintóticamente a lo que el
	# campo sostiene y se queda ahí. Si la comida solo frenara al agotarse el almacén, el
	# sistema entraría en un ciclo límite (crecer → hambruna → morir → crecer) que ni el
	# integrador ni el jugador pueden leer, y que hace que un salto largo y muchos pasos
	# cortos den resultados distintos.
	seg.raw_housing = seg.housing
	seg.food_capacity = _food_capacity(food_slope, food_offset, params, food_imported)
	seg.housing = minf(seg.raw_housing, seg.food_capacity)
	seg.food_limited = seg.housing < seg.raw_housing - EPS

	# Stocks fijados: los que están a tope subiendo, o a cero bajando.
	for i in Goods.COUNT:
		var rate := seg.slope[i] * pop + seg.offset[i]
		if node.stocks[i] >= seg.caps[i] - EPS and rate >= 0.0:
			seg.pinned[i] = 1
		elif node.stocks[i] <= EPS and rate <= 0.0:
			seg.pinned[i] = 1

	# Tres regímenes, los tres con solución exacta:
	#   K ≈ 0        → no hay nada que comer: decaimiento exponencial hacia cero.
	#   pop > K      → sobra gente para lo que hay: logística descendente hacia K.
	#   pop ≤ K      → crecimiento logístico normal hacia K.
	if seg.housing <= EPS:
		seg.rate = -params.starvation_rate
	elif node.pop > seg.housing + EPS:
		seg.rate = params.starvation_rate
	else:
		seg.rate = params.growth_rate * mods.growth
	seg.starving = seg.food_limited and node.pop > seg.housing + EPS
	return seg


## A cuánta población da de comer este reparto de trabajo, resolviendo
## `producción(P) = consumo(P)`. INF si la producción crece más rápido que las bocas.
##
## La comida que llega por rutas (`imported`, por ciclo) sube el techo **con tope**: como mucho
## `food_import_cap` (50 %) del `K` que da el campo propio (decisión 3 del plan de región). Una
## ciudad puede vivir en parte del campo de otra, pero cortar la ruta la devuelve a su `K` propio
## con una caída logística, no la extingue. El caudal es constante por tramo, así que este `K`
## también lo es y la forma cerrada se mantiene. Con el tope, lo importado de más llena el almacén.
static func _food_capacity(
	slope: float, offset: float, params: SimParams, imported := 0.0
) -> float:
	var margin := params.food_per_pop - slope
	if margin <= EPS:
		return INF
	var own := maxf(offset / margin, 0.0)
	if imported <= 0.0:
		return own
	return own + minf(imported / margin, params.food_import_cap * own)


## Producción neta de un recurso por trabajador, con los multiplicadores ya aplicados.
static func _net(b: BuildingDef, good: int, mods: Modifiers) -> float:
	var factor := mods.production
	if good == Goods.FOOD:
		factor *= mods.food
	return (b.produces[good] - b.consumes[good]) * factor


## Lo que la UI necesita saber del estado ahora mismo, sin avanzar el tiempo.
##
## Se calcula con el mismo `build_segment` que usa la simulación: el HUD no puede enseñar una
## tasa distinta de la que se está aplicando, y la única forma de garantizarlo es que salga
## del mismo sitio.
class Snapshot:
	extends RefCounted
	var housing: float = 0.0        ## techo por alojamiento
	var food_capacity: float = 0.0  ## techo por comida (INF si la comida no limita)
	var cap: float = 0.0            ## el que manda de los dos
	var food_limited: bool = false
	var starving: bool = false
	var rates := Goods.zeros()      ## variación por ciclo de cada recurso, ahora mismo


static func snapshot(node: SimNode, params: SimParams, mods: Modifiers = null) -> Snapshot:
	if mods == null:
		mods = Modifiers.none()
	var seg := build_segment(node, params, mods)
	var snap := Snapshot.new()
	snap.housing = seg.raw_housing
	snap.food_capacity = seg.food_capacity
	snap.cap = seg.housing
	snap.food_limited = seg.food_limited
	snap.starving = seg.starving
	for i in Goods.COUNT:
		# Un stock fijado (a tope o a cero) no se mueve: enseñar su tasa teórica sería mentir.
		snap.rates[i] = 0.0 if seg.pinned[i] == 1 else seg.slope[i] * node.pop + seg.offset[i]
	return snap


## Puestos que el jugador ha pedido cubrir en cada edificio, ya recortados por los puestos que
## realmente existen. Pedir 20 granjeros con 2 granjas construidas da 6, no 20.
static func requested_workers(node: SimNode) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(node.buildings.size())
	for bi in node.buildings.size():
		if node.buildings[bi] <= 0:
			continue
		if not Content.building(bi).is_workplace():
			continue
		out[bi] = clampf(node.jobs[bi], 0.0, node.capacity_of(bi))
	return out


## Trabajadores efectivos por edificio: lo que el agregado usa de verdad.
##
## `node.jobs[b]` es el número de personas que **el jugador ha destinado** a ese oficio, no un
## peso relativo. Esa es la diferencia con el modelo anterior, donde el motor normalizaba los
## pesos y repartía toda la población automáticamente: aquí quien no está asignado a nada
## está ocioso, y quedarse sin granjeros por descuido es una decisión del jugador.
##
## Dos regímenes, los dos lineales en la población (que es lo que el integrador necesita):
##
##   - **Normal** (`asignados ≤ población`): cada oficio recibe justo lo pedido. La producción
##     es una **constante**, independiente de cuánta gente haya de más.
##   - **Sobreasignado** (la población ha caído por debajo de lo asignado): se reparte lo que
##     hay en proporción a lo pedido. La producción vuelve a ser proporcional a la población.
static func effective_workers(node: SimNode) -> PackedFloat64Array:
	var wanted := requested_workers(node)
	var total := 0.0
	for w in wanted:
		total += w
	var pop := maxf(node.pop, 0.0)
	if total <= pop or total <= EPS:
		return wanted
	var factor := pop / total
	for i in wanted.size():
		wanted[i] *= factor
	return wanted


## Personas sin oficio asignado. En pantalla se ven deambulando, y es información de juego:
## significa que tienes brazos de sobra para los puestos que has construido.
static func idle_population(node: SimNode) -> float:
	var wanted := effective_workers(node)
	var working := 0.0
	for w in wanted:
		working += w
	return maxf(node.pop - working, 0.0)


# ---------------------------------------------------------------------------
# Soluciones exactas de la población
# ---------------------------------------------------------------------------

## P(t). Escrita con `exp(-r·t)` para que no desborde por muy grande que sea `t`.
static func pop_at(p0: float, k: float, r: float, t: float) -> float:
	if p0 <= EPS:
		return 0.0
	if absf(r) <= EPS:
		return p0
	if r < 0.0:
		return p0 * exp(r * t)
	if k <= EPS:
		return 0.0
	var decay := exp(-r * t)
	return k / (1.0 + ((k - p0) / p0) * decay)


## ∫₀ᵗ P(s) ds — lo que permite integrar los stocks sin simular ciclos.
static func pop_integral(p0: float, k: float, r: float, t: float) -> float:
	if p0 <= EPS:
		return 0.0
	if absf(r) <= EPS:
		return p0 * t
	if r < 0.0:
		return p0 * (1.0 - exp(r * t)) / -r
	if k <= EPS:
		return 0.0
	# ∫ = (K/r)·[ r·t + ln((P0 + (K−P0)·e^{−rt}) / K) ], reordenada para no desbordar.
	var decay := exp(-r * t)
	return (k / r) * (r * t + log((p0 + (k - p0) * decay) / k))


## Instante en que la población alcanza `target`, o INF si no lo alcanza.
##
## Sirve en los dos sentidos: la logística sube hacia K si `p0 < K` y baja hacia K si
## `p0 > K`, y la misma inversión vale para ambos. Objetivos que la curva no alcanza
## (o que ya dejó atrás) devuelven INF de forma natural al mirar el signo del cociente.
static func time_to_pop(p0: float, k: float, r: float, target: float) -> float:
	if p0 <= EPS or absf(r) <= EPS or target <= 0.0:
		return INF
	if r < 0.0:
		if target >= p0:
			return INF
		return log(target / p0) / r
	if k <= EPS or absf(target - k) <= EPS:
		return INF  # K es asíntota: no se alcanza en tiempo finito
	# t = −(1/r)·ln[ P0·(K−target) / (target·(K−P0)) ]
	var num := p0 * (k - target)
	var den := target * (k - p0)
	if absf(den) <= EPS or num / den <= 0.0:
		return INF
	var t := -log(num / den) / r
	return t if t > EPS else INF


# ---------------------------------------------------------------------------
# Eventos y aplicación
# ---------------------------------------------------------------------------

static func _next_event_time(node: SimNode, seg: Segment, max_t: float, params: SimParams) -> float:
	var best := max_t

	# 1. La población satura (o desatura) un centro de trabajo.
	for target in seg.thresholds:
		var t := time_to_pop(node.pop, seg.housing, seg.rate, target)
		if t > EPS and t < best:
			best = t

	# 2. Un stock libre toca su tope o se agota.
	#
	# Hay que mirar los **dos** extremos, no solo el que sugiere el signo de la tasa ahora
	# mismo: la tasa es `a·P + b` y P se mueve dentro del tramo, así que un stock que ahora
	# sube puede darse la vuelta y agotarse antes de que acabe el segmento. Comprobar solo
	# el extremo "hacia el que va" fue exactamente el fallo que hacía que un salto largo
	# se saltase la hambruna que sí veía el paso a paso.
	for i in Goods.COUNT:
		if seg.pinned[i] == 1:
			continue
		for target in [0.0, seg.caps[i]]:
			if target == INF:
				continue
			var t := _time_to_stock(node, seg, i, target, best, params)
			if t > EPS and t < best:
				best = t

	# 3. Un stock fijado se libera porque su tasa cambia de signo al moverse la población.
	for i in Goods.COUNT:
		if seg.pinned[i] == 0:
			continue
		if absf(seg.slope[i]) <= EPS:
			continue
		var flip := -seg.offset[i] / seg.slope[i]
		var t := time_to_pop(node.pop, seg.housing, seg.rate, flip)
		if t > EPS and t < best:
			best = t

	return best


## Resuelve `R_i(t) = target` por barrido grueso + bisección. La forma cerrada hace que esto
## cueste lo mismo tanto si el tramo dura 1 ciclo como si dura 40.000.
static func _time_to_stock(
	node: SimNode, seg: Segment, good: int, target: float, max_t: float, params: SimParams
) -> float:
	var start := node.stocks[good] - target
	var lo := 0.0
	var lo_val := start
	var hi := -1.0
	for s in range(1, SCAN_SAMPLES + 1):
		var t := max_t * float(s) / float(SCAN_SAMPLES)
		var val := _stock_at(node, seg, good, t) - target
		if signf(val) != signf(lo_val) or absf(val) <= EPS:
			hi = t
			break
		lo = t
		lo_val = val
	if hi < 0.0:
		return INF
	for _i in params.solver_iterations:
		var mid := (lo + hi) * 0.5
		var val := _stock_at(node, seg, good, mid) - target
		if signf(val) == signf(lo_val):
			lo = mid
			lo_val = val
		else:
			hi = mid
	return hi


static func _stock_at(node: SimNode, seg: Segment, good: int, t: float) -> float:
	var integral := pop_integral(node.pop, seg.housing, seg.rate, t)
	return node.stocks[good] + seg.slope[good] * integral + seg.offset[good] * t


static func _apply(node: SimNode, seg: Segment, t: float) -> void:
	var integral := pop_integral(node.pop, seg.housing, seg.rate, t)
	for i in Goods.COUNT:
		if seg.pinned[i] == 1:
			continue
		var value := node.stocks[i] + seg.slope[i] * integral + seg.offset[i] * t
		node.stocks[i] = clampf(value, 0.0, seg.caps[i])
	node.pop = pop_at(node.pop, seg.housing, seg.rate, t)
	node.starving = seg.starving
