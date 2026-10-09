class_name Shop
extends RefCounted

## 🛒 Compra y uso de objetos (plan «Objetos de tiempo»). Mismo reparto que `Upgrading` con
## `data/Upgrades.gd`: el catálogo (`Items`) son datos, aquí está la lógica, estática y pura.
##
## Se compra con 🪙 o 📜 **del almacén del nodo enfocado** (`good` elige), y lo comprado va al
## inventario global (`WorldState.items`), que no es de ningún nodo y sobrevive a la ascensión.
##
## Los ⌛ saltos **no se aplican aquí**: mueven el tiempo, y el tiempo solo avanza por
## `SimEngine.tick` (regla 4). `use_blocker` los valida, `spend_skip` los gasta y quien conduce
## —`SimEngine.use_skip`, que llama `Main`— trocea el salto con `begin_skip`.
##
## Cada `*_blocker` es **la única lista** de condiciones, como `Promotion.found_child_blocker`: el
## botón la enseña de tooltip y la acción la vuelve a mirar antes de hacer nada.
##
## No habla con `Analytics` (regla 10): anota en el log (`item_*`, ver `SimEventLog`) y la
## analítica escucha el log como escucha todo lo demás.


## Por qué no se puede comprar `id` pagando con `good` del almacén de `node`; vacío si se puede.
static func buy_blocker(_state: WorldState, node: SimNode, id: String, good: int) -> String:
	var def := Items.get_def(id)
	if def == null:
		return "objeto desconocido"
	if node == null:
		return "no hay ningún nodo enfocado"
	if good < 0 or good >= Goods.COUNT or def.price[good] <= 0.0:
		return "no se paga con %s" % (Goods.ICONS[good] if good >= 0 and good < Goods.COUNT else "eso")
	var price := def.price[good]
	var have := float(node.stocks[good])
	if have < price:
		return "faltan %.0f %s" % [ceilf(price - have), Goods.ICONS[good]]
	return ""


## Compra un `id` pagando el precio entero en `good` del almacén de `node`. `false` si hay motivo
## para no hacerlo (`buy_blocker`). Es una acción discreta entre ticks, como construir: el
## integrador no la ve. Gastar 📜 baja la 🎭 influencia (es raíz de la cultura del subárbol), y se
## deja así a propósito: la tienda lo avisa.
static func buy(
	state: WorldState, node: SimNode, id: String, good: int, events: SimEventLog
) -> bool:
	if not buy_blocker(state, node, id, good).is_empty():
		return false
	var def := Items.get_def(id)
	var price := def.price[good]
	node.stocks[good] -= price
	_add(state, id, 1)
	if events != null:
		events.push(SimEventLog.ITEM_BOUGHT, state.cycle, node.id,
			"%s compra %s %s por %.0f %s" % [node.name, def.icon, def.name, price,
				Goods.ICONS[good]],
			{"item": id, "good": Goods.id_of(good), "price": price})
	return true


## Mete `count` objetos `id` en el inventario sin cobrar nada. Es la **única** entrada de crédito
## que no pasa por `buy`: la usa el goteo (`reason = "drip"`, `drip`) y, más adelante, un proveedor
## de pago. Solo el goteo se anota (`item_dripped`), y con el actor `system`, porque no lo decide
## nadie; el resto lo anotará quien lo llame cuando exista. No toca `drip_held`: eso es del goteo.
static func grant(
	state: WorldState, id: String, count: int, events: SimEventLog, reason: String
) -> void:
	if Items.get_def(id) == null or count <= 0:
		return
	_add(state, id, count)
	if events != null and reason == "drip":
		var prev := events.actor
		events.actor = "system"
		events.push(SimEventLog.ITEM_DRIPPED, state.cycle, state.root_id,
			"Cae %s %s" % [Items.get_def(id).icon, Items.get_def(id).name], {"item": id})
		events.actor = prev


## ⌛ Goteo: un `skip_15m` por cada `params.drip_interval` ciclos del mundo desde el último
## (`drip_cycle`), mientras los goteados que quedan (`drip_held`) no lleguen a `params.drip_cap`.
## Lo llama `SimEngine.tick` al final, una vez por tick: como mira `state.cycle` y el reloj del
## goteo avanza a saltos fijos de `drip_interval`, 10.800 `tick(1)`, un `tick(10800)` y un
## catch-up troceado dejan el mismo `drip_cycle` y los mismos ⌛. El intervalo corre aunque el tope
## esté lleno (se pierde lo que caería), así que un ⌛ +4 h no se autoalimenta: deja como mucho
## los `drip_cap` de reserva. El `while` es por si un tick enorme cruza varios intervalos.
static func drip(state: WorldState, params: SimParams, events: SimEventLog) -> void:
	if params.drip_interval <= 0.0:
		return
	while state.cycle - state.drip_cycle >= params.drip_interval:
		state.drip_cycle += params.drip_interval
		if state.drip_held < params.drip_cap:
			grant(state, "skip_15m", 1, events, "drip")
			state.drip_held += 1


## Por qué no se puede usar `id` sobre `node` (o sobre su subárbol con `all`); vacío si se puede.
##
## `busy`: hay una acreditación a medias (`SimEngine` lo sabe, el estado no). Mientras dura no se
## usa nada: un ⌛ abriría un segundo troceado, y un ⚡ cambiaría a mitad los pasos ya decididos.
## «En todos» es todo o nada: si no hay un objeto por nodo, se dice cuántos faltan.
static func use_blocker(
	state: WorldState, node: SimNode, id: String, all: bool, busy := false
) -> String:
	var def := Items.get_def(id)
	if def == null:
		return "objeto desconocido"
	# 🎖️ Sin Consejo el sello no sirve de nada: es el primer paso de `GovernorSys.delegate_blocker`.
	if def.kind == Items.Kind.SEAL and not Ascension.governor_open(state):
		return GovernorSys.NEEDS_COUNCIL
	if busy:
		return "espera a que termine la acreditación"
	var need := 1
	if def.kind == Items.Kind.BOOST:
		if node == null:
			return "no hay ningún nodo enfocado"
		need = targets(state, node, all).size()
	elif def.kind == Items.Kind.SEAL:
		if node == null:
			return "no hay ningún nodo enfocado"
		need = seal_targets(state, node, all).size()
		if need == 0:
			return "ya están todos sellados" if all else "ya está sellado"
	var have := count_of(state, id)
	if have < need:
		return "faltan %d %s" % [need - have, def.icon]
	return ""


## ⚡ Usa un boost `id` sobre `node`, o uno por cada nodo de su subárbol con `all`. Devuelve los
## nodos afectados (0 si hay motivo para no hacerlo, `use_blocker`). Cada uno pasa por
## `SimEngine.apply_boost`, que no apila (`max(factor)`, renueva la duración) y recalcula la
## expedición en camino. Un objeto por nodo, también si el nodo ya iba acelerado.
static func use_boost(
	state: WorldState, node: SimNode, id: String, all: bool, events: SimEventLog
) -> int:
	var def := Items.get_def(id)
	if def == null or def.kind != Items.Kind.BOOST:
		return 0
	if not use_blocker(state, node, id, all).is_empty():
		return 0
	var hit := targets(state, node, all)
	for t in hit:
		SimEngine.apply_boost(state, t, def.factor, def.cycles)
	_add(state, id, -hit.size())
	if events != null:
		events.push(SimEventLog.ITEM_USED, state.cycle, node.id,
			"%s %s: ×%d durante %d ciclos en %s" % [def.icon, def.name, int(def.factor),
				int(def.cycles), node.name if not all else "%d nodos" % hit.size()],
			{"item": id, "nodes": hit.size(), "all": all})
	return hit.size()


## 🎖️ Sella `node`, o con `all` cada nodo **sin sellar** de su subárbol, uno por nodo. Devuelve los
## nodos sellados (0 si hay motivo para no hacerlo, `use_blocker`: sin Consejo, ya sellado o «faltan
## N 🎖️», y entonces no se gasta nada). Cada uno pasa por `GovernorSys.seal` en el orden de
## `ordered_ids()`, así que **sellar delega**.
static func use_seal(
	state: WorldState, node: SimNode, all: bool, events: SimEventLog
) -> int:
	var def := Items.get_def("seal")
	if def == null or not use_blocker(state, node, "seal", all).is_empty():
		return 0
	var hit := seal_targets(state, node, all)
	for t in hit:
		GovernorSys.seal(state, t, events)
	_add(state, "seal", -hit.size())
	if events != null:
		events.push(SimEventLog.ITEM_USED, state.cycle, node.id,
			"%s %s en %s" % [def.icon, def.name,
				node.name if not all else "%d nodos" % hit.size()],
			{"item": "seal", "nodes": hit.size(), "all": all})
	return hit.size()


## 🚩🎖️ **Fundar y delegar** (`Main._on_found(true)`). Sin 🎖️ Consejo no hace nada. Con al menos un
## 🎖️ en el inventario, la expedición sale con `Governor.balanced()` y la colonia nacerá sellada y
## delegada (`Promotion.arrive`); el sello se gasta **después** de que salga, así que una expedición
## rechazada no lo cuesta. Sin sellos sale sin política: es un «Fundar» normal y la colonia nace a
## mano, hasta que se la selle. `null` si no sale.
static func found_and_delegate(
	state: WorldState, node: SimNode, params: SimParams, events: SimEventLog
) -> Expedition:
	if not Ascension.governor_open(state):
		return null
	var sealed := count_of(state, "seal") >= 1
	var sent := Promotion.launch_expedition(state, node, params, events,
		Governor.balanced() if sealed else null)
	if sent == null or not sealed:
		return sent
	_add(state, "seal", -1)
	if events != null:
		var def := Items.get_def("seal")
		events.push(SimEventLog.ITEM_USED, state.cycle, node.id,
			"%s %s para la colonia que sale de %s" % [def.icon, def.name, node.name],
			{"item": "seal", "nodes": 1, "all": false})
	return sent


## ⌛ Gasta un salto `id` y devuelve los ciclos que hay que avanzar; 0 si no se puede. **No avanza
## nada**: el salto lo trocea y lo da `SimEngine.begin_skip`, por el mismo `tick` de siempre.
## El ⌛ es del mundo entero, así que el evento cuenta todos los nodos; `node` solo es dónde se
## anota (el enfocado, para que salga en su diario).
##
## Un `skip_15m` gasta primero de lo goteado (`drip_held`), para que el goteo vuelva a correr
## cuanto antes: comprar ⌛ no apaga el goteo.
static func spend_skip(
	state: WorldState, node: SimNode, id: String, events: SimEventLog, busy := false
) -> float:
	var def := Items.get_def(id)
	if def == null or def.kind != Items.Kind.SKIP:
		return 0.0
	if not use_blocker(state, node, id, false, busy).is_empty():
		return 0.0
	_add(state, id, -1)
	if id == "skip_15m" and state.drip_held > 0:
		state.drip_held -= 1
	if events != null:
		var where := node.id if node != null else state.root_id
		events.push(SimEventLog.ITEM_USED, state.cycle, where,
			"%s %s: el mundo avanza %d ciclos" % [def.icon, def.name, int(def.cycles)],
			{"item": id, "nodes": state.nodes.size(), "all": true})
	return def.cycles


## A quién llega un objeto usado sobre `node`: él solo, o con `all` su subárbol entero (él
## incluido) en el orden de `ordered_ids()`, que es el del contrato.
static func targets(state: WorldState, node: SimNode, all: bool) -> Array[SimNode]:
	var out: Array[SimNode] = []
	if node == null:
		return out
	if not all:
		out.append(node)
		return out
	var inside := {}
	var stack: Array[int] = [node.id]
	while not stack.is_empty():
		var id: int = stack.pop_back()
		inside[id] = true
		var n: SimNode = state.nodes.get(id)
		if n != null:
			for c in n.children:
				stack.append(c)
	for id in state.ordered_ids():
		if inside.has(id):
			out.append(state.nodes[id])
	return out


## A quién llega un 🎖️ usado sobre `node`: como `targets`, pero solo los que no están sellados.
## Sobre un nodo ya sellado no llega a nadie.
static func seal_targets(state: WorldState, node: SimNode, all: bool) -> Array[SimNode]:
	var out: Array[SimNode] = []
	for t in targets(state, node, all):
		if not t.governor_unlocked:
			out.append(t)
	return out


## Cuántos `id` hay en el inventario.
static func count_of(state: WorldState, id: String) -> int:
	return int(state.items.get(id, 0))


## Suma (o resta) al inventario. Lo que llega a cero se borra: el inventario vacío es el neutro de
## `state_hash` y del save, y una clave a cero no puede distinguirse de una que no está.
static func _add(state: WorldState, id: String, delta: int) -> void:
	var n := count_of(state, id) + delta
	if n > 0:
		state.items[id] = n
	else:
		state.items.erase(id)
