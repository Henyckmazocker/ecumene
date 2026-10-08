class_name Promotion
extends RefCounted

## Promoción de escala y fundación de hijos: el eje vertical del juego.
##
## Un nodo **promociona en el sitio** (`tier += 1`): tu asentamiento *se convierte* en pueblo
## conservando población, stocks y edificios. No aparece un padre vacío por encima.
##
## El anidamiento sale de la regla del techo: **un hijo nunca puede alcanzar el tier de su
## padre**. Cuando la raíz sube a región, sus hijos pueden llegar hasta ciudad, y los hijos
## de estos hasta pueblo. Así una región acaba conteniendo varias ciudades, cada una con sus
## pueblos — la estructura fractal que pide el diseño, sin código por escala.


static func can_promote(state: WorldState, node: SimNode) -> bool:
	var tier_def := node.def()
	if not tier_def.can_promote(node.total_pop, node.building_total()):
		return false
	# Los hijos crecidos van aquí y no en `TierDef.can_promote`, que no ve el árbol. Sigue siendo
	# la misma y única lista: el botón, la ⬆️, `Main` y el gobernador la heredan sin cambios.
	if grown_children(state, node) < tier_def.promote_children:
		return false
	# 🎭 La influencia también es del subárbol, así que va aquí por la misma razón. La cultura no
	# se gasta al promocionar: es un marcador, coherente con que no tenga tope.
	if tier_def.promote_influence > 0.0 and state.influence_of(node) < tier_def.promote_influence:
		return false
	# Después del umbral, que ya descarta el tier terminal; aun así `next_tier_playable` mira el
	# rango por su cuenta, porque la UI la llama sin pasar por aquí.
	if not next_tier_playable(node):
		return false
	return node.tier < tier_ceiling(state, node)


## Si la escala siguiente tiene algo que jugar. Es la puerta de las escalas vacías: el botón, la
## ⬆️ de la pestaña, el atajo de `Main` y el gobernador la heredan todos vía `can_promote`, y la
## UI la consulta aparte solo para explicar por qué la caja dice «próximamente».
static func next_tier_playable(node: SimNode) -> bool:
	var next := node.tier + 1
	if next >= Content.TIER_COUNT:
		return false
	return Content.tier(next).is_playable()


## Hijos que ya han llegado a la escala más alta que les permite este nodo (su tier − 1): los que
## cuentan para `TierDef.promote_children`. Una ciudad necesita pueblos, no asentamientos de 7 hab.
static func grown_children(state: WorldState, node: SimNode) -> int:
	var grown := 0
	for child_id in node.children:
		var child: SimNode = state.get_node_by_id(child_id)
		if child != null and child.tier >= node.tier - 1:
			grown += 1
	return grown


## Tier máximo al que puede llegar este nodo: uno menos que su padre (la raíz no tiene techo).
static func tier_ceiling(state: WorldState, node: SimNode) -> int:
	if node.parent_id < 0:
		return Content.TIER_COUNT - 1
	var parent: SimNode = state.get_node_by_id(node.parent_id)
	if parent == null:
		return Content.TIER_COUNT - 1
	return parent.tier - 1


static func promote(state: WorldState, node: SimNode, events: SimEventLog) -> bool:
	if not can_promote(state, node):
		return false
	var from_name := node.def().name
	node.tier += 1
	var to_def := node.def()
	state.peak_tier = maxi(state.peak_tier, node.tier)
	if events != null:
		events.push("promotion", state.cycle, node.id,
			"%s asciende de %s a %s" % [node.name, from_name, to_def.name],
			{"tier": node.tier, "unlocks": to_def.unlocks})
	return true


## Plazas de hijos libres. La expedición en camino ocupa la suya: no puede salir otra hacia una
## plaza que ya tiene colonos de camino.
static func free_slots(state: WorldState, node: SimNode) -> int:
	if node.tier <= Content.SETTLEMENT:
		return 0
	var travelling := 1 if state.expedition_of(node.id) != null else 0
	return maxi(0, node.def().child_slots - node.children.size() - travelling)


static func can_found_child(state: WorldState, node: SimNode, params: SimParams) -> bool:
	return found_child_blocker(state, node, params).is_empty()


## Por qué este nodo no puede fundar un hijo, en una frase para la UI; vacío si puede.
##
## Es la **única** lista de condiciones: `can_found_child` no es más que esto vacío, así que el
## botón y el gobernador no pueden discrepar. El orden importa: un asentamiento tiene 0 plazas,
## y sin comprobar el tier antes diría «0 de 0 hijos fundados». La expedición en camino va justo
## después: con una en camino, lo que hay que decir es cuándo llega, no cuántas plazas quedan.
static func found_child_blocker(state: WorldState, node: SimNode, params: SimParams) -> String:
	if node.tier - 1 < Content.SETTLEMENT:
		return "un %s no puede tener hijos" % node.def().name.to_lower()
	var travelling := state.expedition_of(node.id)
	if travelling != null:
		var left := maxf(travelling.arrive_cycle - state.cycle, 0.0) * params.seconds_per_cycle
		return "expedición en camino: llega en %s" % OfflineReport.span(left)
	if free_slots(state, node) <= 0:
		return "%d de %d hijos fundados" % [node.children.size(), node.def().child_slots]
	# Fundar cuesta colonos y provisiones: sale del núcleo, no de la nada. Se exige el doble de
	# los colonos que se llevan para que fundar no vacíe al padre.
	var min_pop := settler_pop(params) * 2.0
	if node.pop < min_pop:
		return "necesitas %.0f habitantes" % min_pop
	var food := settler_food(params)
	if node.stocks[Goods.FOOD] < food:
		return "necesitas %.0f 🌾" % food
	return ""


## Ciclos que tardará la próxima expedición de este nodo: cada hijo que ya tiene alarga la
## siguiente, y la acortan 🧭 Caminos antiguos (legado) y 🛤️ Carreteras (mejora del nodo).
## Se fija al salir: es una constante del segmento, no una tasa, así que comprar cualquiera de
## los dos con una expedición en camino no la acelera. La escala del que funda la multiplica
## (`TierDef.expedition_scale`): una ciudad tarda más en fundar un pueblo que un pueblo una aldea.
static func expedition_cycles(state: WorldState, node: SimNode, params: SimParams) -> float:
	return params.expedition_base * pow(params.expedition_growth, node.children.size()) \
		* node.def().expedition_scale \
		* Ascension.bonuses(state).expedition * node.effects().expedition


## Lanza una expedición para fundar un hijo un tier por debajo del padre. Los colonos y la comida
## salen **ya** del padre; el hijo nace al llegar (`arrive`, que llama `SimEngine.tick` en el
## ciclo exacto). `null` si hay motivo para no fundar (`found_child_blocker`).
##
## Es la única ruta para fundar, la misma para el jugador y para el gobernador. Con
## `delegate_policy` la colonia nacerá delegada con esa política; quién la pone es cosa de quien
## funda, no de esta función.
static func launch_expedition(
	state: WorldState, node: SimNode, params: SimParams, events: SimEventLog,
	delegate_policy: Governor = null
) -> Expedition:
	if not can_found_child(state, node, params):
		return null
	var e := Expedition.new()
	e.parent_id = node.id
	e.tier = node.tier - 1
	e.depart_cycle = state.cycle
	e.arrive_cycle = state.cycle + expedition_cycles(state, node, params)
	e.pop = settler_pop(params)
	e.food = settler_food(params)
	e.delegate_policy = delegate_policy
	if events != null:
		e.actor = events.actor
	node.pop -= e.pop
	node.stocks[Goods.FOOD] -= e.food
	state.add_expedition(e)
	if events != null:
		# Con el actor de ahora, que es quien la manda. El diario la cuenta al salir para que la
		# espera tenga un principio; `Analytics` no la mapea y la ignora.
		events.push("expedition", state.cycle, node.id,
			"%s envía colonos: llegan en %s" % [node.name,
				OfflineReport.span((e.arrive_cycle - e.depart_cycle) * params.seconds_per_cycle)],
			{"parent": node.id, "tier": e.tier, "arrive": e.arrive_cycle})
	return e


## ⏩ Oro que cuesta la **siguiente** aceleración de la expedición en camino de `node`; 0 si no hay
## ninguna. Se paga por ciclo recortado, así que acelerar pronto (con mucho viaje por delante)
## cuesta más que acelerar al final, y cada aceleración ya hecha la encarece ×`accelerate_growth`:
## el oro de una ciudad entre dos expediciones paga unas pocas, no todas (M0 fijó k con eso).
static func accelerate_cost(state: WorldState, node: SimNode, params: SimParams) -> float:
	var e := state.expedition_of(node.id)
	if e == null:
		return 0.0
	var cut := maxf(e.arrive_cycle - state.cycle, 0.0) * params.accelerate_fraction
	return params.accelerate_gold_per_cycle * cut \
		* pow(params.accelerate_growth, e.accelerations)


## ⏩ Por qué `node` no puede acelerar su expedición, en una frase para la UI; vacío si puede.
##
## La **única** lista, como `found_child_blocker`: el botón y `accelerate_expedition` la leen igual.
## El orden importa: sin expedición no hay nada que contar del oro, y un pueblo no tiene que oír
## cuánto le falta para algo que su escala no puede hacer.
static func accelerate_blocker(state: WorldState, node: SimNode, params: SimParams) -> String:
	if state.expedition_of(node.id) == null:
		return "no hay ninguna expedición en camino"
	if node.tier < Content.CITY:
		return "solo una ciudad tiene oro para esto"
	var cost := accelerate_cost(state, node, params)
	var gold := float(node.stocks[Goods.GOLD])
	if gold < cost:
		return "faltan %.0f 🪙" % ceilf(cost - gold)
	return ""


## ⏩ Gasta oro para recortar el `accelerate_fraction` de lo que le queda de viaje a la expedición
## de `node`. `false` si hay motivo para no hacerlo (`accelerate_blocker`).
##
## Es una acción discreta entre ticks, como construir: no toca el integrador. `SimEngine.tick` ya
## parte el tramo en `next_arrival()`, así que la llegada adelantada se resuelve en su ciclo exacto
## y N×1 sigue dando lo mismo que N (regla 4). Solo la llama el jugador: el gobernador no acelera.
static func accelerate_expedition(
	state: WorldState, node: SimNode, params: SimParams, events: SimEventLog
) -> bool:
	if not accelerate_blocker(state, node, params).is_empty():
		return false
	var cost := accelerate_cost(state, node, params)
	node.stocks[Goods.GOLD] -= cost
	# Se saca y se vuelve a meter: `expeditions` va en orden de llegada (`pop_arrivals` lee la
	# cabeza), y adelantar una puede ponerla por delante de otra.
	var e := state.cancel_expedition_of(node.id)
	var left := maxf(e.arrive_cycle - state.cycle, 0.0)
	# Acotada a ≥ ahora: si el recorte la dejara en el pasado, llega en el siguiente tick
	# (`pop_arrivals` recoge todo lo que tenga `arrive_cycle ≤` el final del tramo), no se pierde.
	e.arrive_cycle = maxf(e.arrive_cycle - left * params.accelerate_fraction, state.cycle)
	e.accelerations += 1
	state.add_expedition(e)
	if events != null:
		# Como `expedition`, `Analytics` no lo mapea: el diario lo cuenta y Augur lo ignora.
		events.push("accelerate", state.cycle, node.id,
			"%s acelera su expedición: llega en %s" % [node.name,
				OfflineReport.span((e.arrive_cycle - state.cycle) * params.seconds_per_cycle)],
			{"parent": node.id, "arrive": e.arrive_cycle, "cost": cost,
				"accelerations": e.accelerations})
	return true


## Funda el hijo con lo que traía la expedición. Ya tiene que estar fuera de
## `state.expeditions` (`WorldState.pop_arrivals`). `null` si el padre ya no existe, que no debería
## pasar: `SimEngine._prune` cancela la expedición del nodo que borra.
static func arrive(state: WorldState, e: Expedition, events: SimEventLog) -> SimNode:
	var node: SimNode = state.get_node_by_id(e.parent_id)
	if node == null:
		return null
	var child := state.add_node(e.tier, node.id)
	var settlers := e.pop
	child.pop = settlers
	child.stocks[Goods.FOOD] = e.food
	child.buildings[Content.building_index("farm")] = 1
	child.buildings[Content.building_index("woodcutter")] = 1
	# Los colonos llegan con su oficio puesto, como los fundadores de la partida. A partir de
	# ahí el reparto de la colonia es cosa de quien la lleve.
	child.jobs[Content.building_index("farm")] = ceil(settlers * 0.6)
	child.jobs[Content.building_index("woodcutter")] = floor(settlers * 0.4)
	# La política se copió al salir: no se vuelve a mirar al padre.
	if e.delegate_policy != null:
		GovernorSys.delegate(state, child, e.delegate_policy)
	if events != null:
		# Con el actor de quien la mandó, como salía al fundar al instante.
		var prev := events.actor
		events.actor = e.actor
		events.push("found", state.cycle, child.id,
			"%s funda %s" % [node.name, child.name],
			{"parent": node.id, "tier": child.tier})
		# «🚩🎖️ Fundar y delegar» es delegar, y el evento de delegación sale aquí, cuando el nodo
		# existe y se le pone el gobernador: antes de la expedición lo emitía `Main` al pulsar, con
		# el hijo ya creado. Solo si lo decidió el jugador: lo que funda un gobernador nace
		# delegado por herencia, no porque nadie lo decida, y `delegation` en Augur es una decisión
		# del jugador (como la emite `Main._on_delegation_toggled`).
		if e.delegate_policy != null and e.actor == "player":
			events.push("governor", state.cycle, child.id,
				"%s pasa a manos de un gobernador" % child.name, {"delegated": true})
		events.actor = prev
	return child


## Colonos que se lleva cada fundación. Público porque el botón de fundar enseña el coste y no
## debe tener su propia copia de la cifra.
static func settler_pop(params: SimParams) -> float:
	return params.initial_pop * 2.0


## Comida que se lleva cada fundación (y con la que nace el hijo).
static func settler_food(params: SimParams) -> float:
	return 50.0
