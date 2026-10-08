class_name Logistics
extends RefCounted

## Rutas de reparto entre un nodo y su padre. Sistema puro y estático, como `Construction`.
##
## Una ruta es un **caudal constante por tramo**: `−flow` en el origen y `+flow` en el destino,
## sumados al `offset` del segmento (`Integrator.build_segment`). Es lineal, no depende de `P`, y
## cada nodo sigue avanzando por su cuenta con el mismo `Integrator.advance` de siempre: lo único
## que sabe de la ruta es un número. El caudal se fija en un checkpoint —cada `governor_interval`
## ciclos y al crear o cambiar la ruta— y entre checkpoints no se mueve.
##
## **El único acople: un extremo que no puede seguir.** Si el origen se queda sin el recurso, o el
## destino se llena, el integrador fija ese stock (`pinned`) y deja de moverlo. Si el otro extremo
## siguiera a lo suyo, la ruta crearía recursos de la nada (el destino recibe lo que el origen ya
## no paga) o los tiraría (el origen paga lo que el destino ya no cabe). Así que en ese instante la
## ruta **se corta en los dos extremos a la vez**, y vuelve en el siguiente checkpoint.
##
## El instante se encuentra con sondas: una copia de cada nodo con rutas avanza el resto del tick
## y anota cuándo se le fija un stock (`Integrator.Pins`). El primero de todos es donde se corta;
## hasta ahí avanzan los nodos de verdad, se quita la ruta y se sondea otra vez. Cada corte se
## lleva al menos una ruta, así que son como mucho tantas vueltas como rutas, y sin ningún corte
## es una sola sonda por nodo. Todo en orden de id: el resultado no depende del `Dictionary`.
##
## Lo que entra en el destino es exactamente lo que sale del origen —`flow × t` por los dos lados,
## con el mismo `t`—, salvo el error del instante de corte, que el integrador resuelve por
## bisección (orden 1e-12 ciclos).

const EPS := Integrator.EPS

## 🐎 que paga el **padre** por cada unidad de caudal y ciclo (decisión 1 del plan de región, ya
## enmendada). Es un término constante más del mismo `offset`, así que el tramo sigue siendo
## `a·P + b`. Con 0,5, un establo lleno (1 🐎/ciclo) sostiene 2 unidades de caudal. Si el
## transporte se agota, se cortan **todas** las rutas que paga ese padre, igual que cuando se agota
## el bien, y vuelven en el siguiente checkpoint.
##
## Paga el padre en los dos sentidos, baje la ruta o suba: solo la región tiene establos, y si
## pagara el origen una ciudad no podría mandar nada hacia arriba sin que antes le bajaran 🐎. Como
## las rutas son solo entre padre e hijo directo (`route_blocker`), siempre hay un padre que pague.
const TRANSPORT_PER_FLOW := 0.5


## Por qué no se puede crear esta ruta, o "" si se puede. Una sola lista de condiciones, la misma
## para el jugador y, en M4, para el gobernador regional.
static func route_blocker(state: WorldState, from_id: int, to_id: int, good: int) -> String:
	var from: SimNode = state.nodes.get(from_id)
	var to: SimNode = state.nodes.get(to_id)
	if from == null or to == null:
		return "un extremo de la ruta no existe"
	if from_id == to_id:
		return "una ruta necesita dos nodos"
	# Solo entre padre e hijo directo (decisión 6 del plan de región): es O(hijos) y se lee en
	# una lista. Entre cualquier par haría falta la vista agregada para entenderlo.
	if from.parent_id != to_id and to.parent_id != from_id:
		return "solo hay rutas entre un nodo y su padre"
	if good < 0 or good >= Goods.COUNT:
		return "recurso desconocido"
	# Ni oro ni cultura (decisión 4): son del plan del sumidero.
	if good == Goods.GOLD or good == Goods.CULTURE:
		return "%s no viaja por rutas" % Goods.NAMES[good].to_lower()
	return ""


## Quién paga el 🐎 de una ruta: el extremo que es padre del otro (`TRANSPORT_PER_FLOW`). Con un
## extremo que ya no existe devuelve -1, y nadie paga.
static func payer_of(state: WorldState, r: Route) -> int:
	var from: SimNode = state.nodes.get(r.from_id)
	var to: SimNode = state.nodes.get(r.to_id)
	if from == null or to == null:
		return -1
	return r.to_id if from.parent_id == r.to_id else r.from_id


## Por qué una ruta circula por debajo de lo pedido (`flow < rate`), o "" si va a su caudal. Solo
## lee: es la frase que enseña la lista de rutas del HUD, igual que `route_blocker` es la de crear.
##
## La ruta cortada se queda a cero hasta el siguiente checkpoint, así que lo que se mira es **por
## qué no podría volver ahora**, en el mismo orden en que `_first_breach` la habría cortado: el
## 🐎 del padre, el bien del origen y el almacén del destino. Si ya no le falta nada, es que está
## esperando al checkpoint.
static func cut_reason(state: WorldState, params: SimParams, r: Route) -> String:
	if r.flow >= r.rate:
		return ""
	var from: SimNode = state.nodes.get(r.from_id)
	var to: SimNode = state.nodes.get(r.to_id)
	var payer: SimNode = state.nodes.get(payer_of(state, r))
	if from == null or to == null or payer == null:
		return "un extremo de la ruta ya no existe"
	if payer.stocks[Goods.TRANSPORT] <= EPS:
		return "falta 🐎 en %s" % payer.name
	if from.stocks[r.good] <= EPS:
		return "falta %s %s en %s" % [Goods.ICONS[r.good], Goods.NAMES[r.good].to_lower(),
			from.name]
	if to.stocks[r.good] >= to.storage_caps(params)[r.good] - EPS:
		return "%s tiene el almacén de %s lleno" % [to.name, Goods.ICONS[r.good]]
	return "cortada hasta el próximo reparto"


## Crea la ruta, o le cambia el caudal si ya existe una con el mismo origen, destino y recurso.
## Con `rate <= 0` la borra. Es la **ruta única** para tocar rutas: nada se reparte solo.
##
## Crear o cambiar una ruta es un checkpoint para ella: circula al caudal pedido desde ya.
static func set_route(
	state: WorldState, from_id: int, to_id: int, good: int, rate: float
) -> Route:
	if not route_blocker(state, from_id, to_id, good).is_empty():
		return null
	var route: Route = null
	for r in state.routes:
		if r.from_id == from_id and r.to_id == to_id and r.good == good:
			route = r
			break
	if rate <= 0.0:
		if route != null:
			state.routes.erase(route)
			compute_offsets(state)
		return null
	if route == null:
		route = Route.new()
		route.id = state.next_route_id
		state.next_route_id += 1
		route.from_id = from_id
		route.to_id = to_id
		route.good = good
		# Al final: los ids crecen, así que la lista sigue en orden de id.
		state.routes.append(route)
	route.rate = rate
	route.flow = rate
	compute_offsets(state)
	return route


## Borra las rutas que tocan un nodo. La llama `SimEngine._prune` **en el mismo paso** en que
## retira el nodo: una ruta colgando haría que el siguiente checkpoint desreferenciase un nulo.
static func drop_routes_of(state: WorldState, node_id: int) -> int:
	var kept: Array[Route] = []
	for r in state.routes:
		if not r.touches(node_id):
			kept.append(r)
	var dropped := state.routes.size() - kept.size()
	if dropped > 0:
		state.routes = kept
		compute_offsets(state)
	return dropped


## Recalcula `route_offset` de todos los nodos a partir de los caudales. Es lo único que el
## integrador ve de las rutas.
static func compute_offsets(state: WorldState) -> void:
	for id in state.ordered_ids():
		var node: SimNode = state.nodes[id]
		if not node.route_offset.is_empty():
			node.route_offset = PackedFloat64Array()
	for r in state.routes:
		_add_flow(state, r, r.flow)


## Checkpoint de rutas, al principio del tick y antes de avanzar. Si toca, las rutas cortadas
## vuelven a su caudal pedido. Devuelve los ids de los nodos con alguna ruta circulando, en orden:
## esos avanzan por `advance_routed`, el resto por `Integrator.advance` como siempre.
##
## Mismo reloj que el gobernador (`governor_interval`). En el catch-up troceado cada paso dura al
## menos eso, así que cada paso empieza con un checkpoint.
static func prepare(state: WorldState, params: SimParams) -> PackedInt32Array:
	var routed := PackedInt32Array()
	if state.routes.is_empty():
		return routed
	var interval := maxf(params.governor_interval, 1.0)
	var due := int(floor((state.cycle - state.routes_cycle) / interval))
	if due > 0:
		# Igual que el reloj del gobernador (`GovernorSys.run`): se avanzan los checkpoints que
		# tocaban y se guarda el resto del intervalo, o con `tick(25)` el checkpoint caería cada
		# 50 ciclos y no cada 30. Con un atraso de 64 o más —una ausencia larga, o las primeras
		# rutas tras mucho tiempo sin ninguna— se descarta y el reloj arranca ahora.
		if due >= 64:
			state.routes_cycle = state.cycle
		else:
			state.routes_cycle += float(due) * interval
		for r in state.routes:
			r.flow = r.rate
	compute_offsets(state)
	for id in state.ordered_ids():
		for r in state.routes:
			if r.flow > 0.0 and r.touches(id):
				routed.append(id)
				break
	return routed


## Avanza `dt` ciclos los nodos con rutas, cortando cada ruta en el instante en que uno de sus
## extremos no puede seguir. Es el mismo `Integrator.advance`, troceado en los instantes de corte.
static func advance_routed(
	state: WorldState, params: SimParams, dt: float, routed: PackedInt32Array,
	base: Integrator.Modifiers, delegated: Integrator.Modifiers
) -> void:
	var cut := {}  # id de ruta → true: cortadas en este tick
	var t := 0.0
	# Cada corte se lleva al menos una ruta que circulaba: no puede haber más vueltas que rutas.
	for _round in state.routes.size() + 1:
		if dt - t <= EPS:
			break
		var breach := _first_breach(state, params, dt - t, routed, cut, base, delegated)
		var step := minf(breach.at, dt - t)
		for id in routed:
			var node: SimNode = state.nodes[id]
			node.route_offset = _offset_of(state, id, cut)
			Integrator.advance(node, params, step, delegated if node.is_delegated() else base)
		t += step
		if breach.node < 0:
			break
		_cut(state, breach, cut)
	# Salvaguarda, como la de `Integrator.advance`: no debería quedar tiempo, pero si quedara se
	# avanza de un tirón con lo que siga abierto antes que perderlo.
	if dt - t > EPS:
		for id in routed:
			var node: SimNode = state.nodes[id]
			node.route_offset = _offset_of(state, id, cut)
			Integrator.advance(node, params, dt - t, delegated if node.is_delegated() else base)
	# Las cortadas se quedan cortadas hasta el próximo checkpoint, en los dos extremos.
	for r in state.routes:
		if cut.has(r.id):
			r.flow = 0.0
	compute_offsets(state)


# ---------------------------------------------------------------------------
# Internos
# ---------------------------------------------------------------------------

## Dónde y cuándo un extremo deja de poder seguir con su ruta.
class Breach:
	extends RefCounted
	var at: float = INF
	var node: int = -1
	var good: int = -1
	var empty: bool = true  ## true: el origen se vacía · false: el destino se llena


## Sonda: cada nodo con rutas avanza **una copia** el resto del tick con las rutas que siguen
## abiertas, y se busca el primer stock que se fija con una ruta que dependa de él.
static func _first_breach(
	state: WorldState, params: SimParams, remaining: float, routed: PackedInt32Array,
	cut: Dictionary, base: Integrator.Modifiers, delegated: Integrator.Modifiers
) -> Breach:
	var best := Breach.new()
	for id in routed:
		var node: SimNode = state.nodes[id]
		var probe := node.duplicate_node()
		probe.route_offset = _offset_of(state, id, cut)
		if probe.route_offset.is_empty():
			continue  # ya no le queda ninguna ruta abierta: no puede romper nada
		var pins := Integrator.Pins.new()
		Integrator.advance(probe, params, remaining, delegated if node.is_delegated() else base,
			pins)
		for r in state.routes:
			if r.flow <= 0.0 or cut.has(r.id):
				continue
			# Solo cuentan los dos fijados que rompen la cuenta: un origen vacío del que la ruta
			# sigue sacando y un destino lleno en el que sigue metiendo. Un origen a tope o un
			# destino a cero no pierden ni crean nada.
			if r.from_id == id and pins.empty_at[r.good] < best.at:
				best.at = pins.empty_at[r.good]
				best.node = id
				best.good = r.good
				best.empty = true
			elif r.to_id == id and pins.full_at[r.good] < best.at:
				best.at = pins.full_at[r.good]
				best.node = id
				best.good = r.good
				best.empty = false
			# El padre se queda sin 🐎 con que pagar el caudal: se cortan todas las rutas que paga,
			# bajen o suban. Aparte del bien: un padre puede ser destino y pagar a la vez.
			if payer_of(state, r) == id and pins.empty_at[Goods.TRANSPORT] < best.at:
				best.at = pins.empty_at[Goods.TRANSPORT]
				best.node = id
				best.good = Goods.TRANSPORT
				best.empty = true
	return best


## Corta, en los dos extremos, las rutas abiertas que el fijado de `breach` no deja seguir.
static func _cut(state: WorldState, breach: Breach, cut: Dictionary) -> void:
	for r in state.routes:
		if r.flow <= 0.0 or cut.has(r.id):
			continue
		# Un padre sin transporte no puede pagar ninguna de sus rutas, lleven lo que lleven.
		if breach.empty and breach.good == Goods.TRANSPORT \
				and payer_of(state, r) == breach.node:
			cut[r.id] = true
			continue
		if r.good != breach.good:
			continue
		var end := r.from_id if breach.empty else r.to_id
		if end == breach.node:
			cut[r.id] = true


## Suma de caudales abiertos de un nodo, en orden de id de ruta. Vacío si no le queda ninguna.
static func _offset_of(state: WorldState, node_id: int, cut: Dictionary) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for r in state.routes:
		if r.flow <= 0.0 or cut.has(r.id) or not r.touches(node_id):
			continue
		if out.is_empty():
			out = Goods.zeros()
		if r.from_id == node_id:
			out[r.good] -= r.flow
		else:
			out[r.good] += r.flow
		# El padre paga además el transporte, otro término constante del mismo `offset`.
		if payer_of(state, r) == node_id:
			out[Goods.TRANSPORT] -= r.flow * TRANSPORT_PER_FLOW
	return out


static func _add_flow(state: WorldState, r: Route, amount: float) -> void:
	if amount <= 0.0:
		return
	var from: SimNode = state.nodes.get(r.from_id)
	var to: SimNode = state.nodes.get(r.to_id)
	if from == null or to == null:
		return
	if from.route_offset.is_empty():
		from.route_offset = Goods.zeros()
	if to.route_offset.is_empty():
		to.route_offset = Goods.zeros()
	from.route_offset[r.good] -= amount
	to.route_offset[r.good] += amount
	var payer := to if from.parent_id == r.to_id else from
	payer.route_offset[Goods.TRANSPORT] -= amount * TRANSPORT_PER_FLOW
