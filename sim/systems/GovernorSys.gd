class_name GovernorSys
extends RefCounted

## Evaluación de gobernadores. Se ejecuta en **checkpoints** (cada `governor_interval`
## ciclos), no en cada tick: así el catch-up offline de un imperio delegado sigue costando
## un número acotado de decisiones en vez de una por ciclo.
##
## Todas las decisiones salen por `Construction`, `Upgrading` y `Promotion`, las mismas
## funciones que usa el jugador.

## Prioridades del gobernador, en el orden de `Governor.normalized()`.
const P_FOOD := 0
const P_GROWTH := 1
const P_INDUSTRY := 2
const P_EXPANSION := 3

const EPS := 1.0e-9
## Margen para dar un stock por lleno. Los topes se recalculan a cada paso y no conviene que un
## almacén lleno deje de parecerlo por el último bit.
const FULL_EPS := 0.001

## Urgencia que se suma al peso de la política cuando algo es **el cuello de botella real**.
## Tiene que dominar a las prioridades: un gobernador puede ser mediocre, no puede construir
## casas para gente a la que no da de comer.
const URGENT := 1.5

## Cuánto baja el interés por un recurso cuyo almacén ya está lleno: seguir produciéndolo es
## tirar gente a la basura, pero no es exactamente cero — en cuanto el tope suba o el stock
## baje, el oficio vuelve solo.
const SATURATED := 0.15

## Cuánto baja el interés por un oficio al que le falta su materia prima. Tampoco es cero: el
## taller se vuelve a llenar en cuanto entra madera, sin necesitar un caso especial.
const STARVED := 0.1

## Cuánto vale ampliar los puestos de un edificio que todavía tiene sitio libre.
const IDLE_SLOTS := 0.25

## Fracción de población ociosa a la que alojar deja de urgir del todo. Sin esto el gobernador
## entra en bucle: alojar sube la población, la población nueva no tiene dónde trabajar, y como
## el techo vuelve a estar al 85 % levanta otra cabaña. El resultado eran pueblos de 109
## habitantes con 61 sin destinar y sin una sola cantera.
##
## La urgencia se desvanece en rampa y no de golpe: un puñado de ociosos por el redondeo del
## reparto es normal y no puede congelar la construcción de casas.
const IDLE_SHARE_OK := 0.5

## A qué prioridad de la política responde cada recurso. Es **la** tabla que hay que ampliar al
## añadir un recurso a `Goods`: si se olvida, el recurso nuevo cae en industria por defecto,
## pero nunca desaparece del reparto ni de la puntuación.
##
## El 🐎 transporte va a industria: es lo que produce un oficio (los establos) para que otra cosa
## funcione, como las herramientas.
const GOOD_AXIS := [
	P_FOOD, P_GROWTH, P_INDUSTRY, P_INDUSTRY, P_INDUSTRY, P_INDUSTRY, P_INDUSTRY,
]

## Fracción del techo a la que funda un gobernador sin orden. Por debajo, el núcleo todavía
## crece solo y colonizar le quita colonos que le harían falta.
const FOUND_AT_CAP := 0.9
## Lo mismo con `Order.EXPAND`: fundar antes es justo lo que pide la orden. Sigue sin ser cero:
## cada colonia se lleva colonos del padre, y un núcleo vaciado del todo deja de crecer.
const FOUND_AT_CAP_EXPAND := 0.6

## Con `Order.STOCKPILE`, un recurso solo se gasta si su almacén está a esta fracción del tope o
## más: lo que se paga entonces es lo que, de no gastarse, iba a desbordar. No es el 100 % porque
## un almacén lleno se vacía un poco con cada consumo y no volvería a contar como lleno.
const STOCKPILE_SPEND_AT := 0.95


static func _axis_of(good: int) -> int:
	return GOOD_AXIS[good] if good < GOOD_AXIS.size() else P_INDUSTRY


## Lo que el gobernador mira **una vez** por checkpoint y comparten las tres decisiones.
##
## Vive en un objeto y no en seis parámetros sueltos por dos razones: los cuellos de botella se
## calculan una vez en vez de una por candidato, y —lo que importa— repartir gente, construir e
## investigar miden lo que hace falta con exactamente la misma vara.
class Situation:
	extends RefCounted
	var weights: PackedFloat64Array   ## política del jugador con la orden, ya normalizada
	var snap: Integrator.Snapshot     ## qué está limitando de verdad
	var caps: PackedFloat64Array      ## topes de almacén
	## Fracción de población sin oficio tras el reparto. Es la señal de si al nodo le faltan
	## brazos o le faltan puestos.
	var idle_share: float = 0.0
	var housing_urgency: float = 0.0
	var storage_urgency: float = 0.0
	## Recursos que algo del catálogo pide, el nodo no tiene y **nadie está produciendo**.
	var shortage := PackedInt32Array()

	func _init() -> void:
		shortage.resize(Goods.COUNT)

	func weight(priority: int) -> float:
		return weights[priority]


## Lo que una decisión de compra eligió y lo que casi eligió, para el rastro.
##
## Solo se **devuelve**: nada de esto se guarda en el nodo ni en `WorldState`, y por eso el
## rastro no puede mover un bit de la simulación (`analytics_test.gd`). El segundo es el mejor
## de los que también se podían pagar y puntuaban por encima de cero, con la misma vara que el
## ganador.
class Pick:
	extends RefCounted
	var winner: String = ""          ## id del edificio o mejora comprado; "" si nada
	var score: float = 0.0
	var runner_up: String = ""       ## id del segundo candidato; "" si no lo hubo
	var runner_up_score: float = 0.0
	var done: bool = false           ## si la compra se hizo de verdad

	## Mete un candidato en el podio. Mismo desempate que la compra: `>` estricto, así que a
	## igualdad gana el primero del catálogo, que es el orden fijo del que depende el
	## determinismo.
	func offer(id: String, candidate_score: float) -> void:
		if candidate_score > score:
			runner_up = winner
			runner_up_score = score
			winner = id
			score = candidate_score
		elif candidate_score > runner_up_score:
			runner_up = id
			runner_up_score = candidate_score


## Ejecuta los checkpoints pendientes de un nodo delegado. Devuelve cuántos se evaluaron.
##
## `mods` son los multiplicadores con los que se integra el nodo (legado × peaje, el `delegated`
## de `SimEngine.tick`). Sin ellos (`null`) se calculan con `SimEngine.delegated_modifiers`, la
## misma cuenta: así quien llama a `run` suelto —los tests— ve lo mismo que el motor.
static func run(
	state: WorldState, node: SimNode, params: SimParams, events: SimEventLog,
	mods: Integrator.Modifiers = null
) -> int:
	if not node.is_delegated():
		return 0
	var interval := maxf(params.governor_interval, 1.0)
	# Con el reloj del nodo, no con el del mundo: un nodo con ⚡ ×4 decide cada 30 ciclos **suyos**,
	# cuatro veces más a menudo en tiempo real. Sin boost es `state.cycle`, bit a bit.
	var now := clock_of(state, node)
	var due := int(floor((now - node.governor_last_cycle) / interval))
	if due <= 0:
		return 0
	# Acotado: un mes offline no dispara miles de decisiones retroactivas.
	due = mini(due, 64)
	# Todo lo que se haga desde aquí lo hace el gobernador, aunque pase por las mismas funciones
	# que el jugador. El actor viaja en el log y se restaura al salir: quien llamó sigue siendo
	# quien era.
	var prev := ""
	if events != null:
		prev = events.actor
		events.actor = "governor"
	if mods == null:
		mods = SimEngine.delegated_modifiers(state, params)
	for _i in due:
		_decide(state, node, params, events, mods)
	if events != null:
		events.actor = prev
	# El reloj avanza los checkpoints que se han evaluado, no hasta `state.cycle`: lo que sobra
	# del intervalo se guarda para el siguiente. Si se tirara, con `tick(25)` y un intervalo de
	# 30 el gobernador decidiría cada 50 ciclos, y la cadencia —que es lo que fija la curva
	# temprana— dependería del tamaño del tick. Solo con el tope lleno se descarta el atraso:
	# para eso existe, para que un mes fuera no deje cientos de decisiones pendientes.
	if due >= 64:
		node.governor_last_cycle = now
	else:
		node.governor_last_cycle += float(due) * interval
	return due


## Pone un nodo en manos de un gobernador con esta política. Es la ruta única para delegar al
## fundar, la misma para el botón «Fundar y delegar» y para el gobernador que coloniza.
##
## El reloj de checkpoints arranca **ahora**: con `governor_last_cycle` a cero, el primer `run`
## creería que debe todos los checkpoints desde el ciclo 0 y tomaría de golpe hasta 64
## decisiones atrasadas en un nodo que acaba de nacer.
##
## **Sin puerta** (plan Gobernador por sello): ni 🎖️ Consejo ni sello. La puerta está antes, en
## quien decide (`delegate_blocker`); así los tests, `era_probe` y el modo captura siguen delegando
## con ella como proxy de un jugador atento.
static func delegate(state: WorldState, node: SimNode, policy: Governor) -> void:
	node.governor = policy
	node.governor_last_cycle = clock_of(state, node)


## Por qué no se puede delegar sin 🎖️ Consejo. Es el primer paso de `delegate_blocker` (que añade
## dónde se compra) y el de usar un 🎖️ Sello (`Shop.use_blocker`, que lo dice así desde «Objetos de
## tiempo»), así que vive en un solo sitio.
const NEEDS_COUNCIL := "se desbloquea con 🎖️ Consejo"


## Por qué `node` no se puede delegar, en una frase para la UI; "" si se puede.
## La única lista, como `Promotion.found_child_blocker`: la leen el botón, `Main` y «Fundar y
## delegar». Mira `governor_unlocked` y no el inventario: retomar el mando y volver a delegar un
## nodo sellado no gasta otro sello.
static func delegate_blocker(state: WorldState, node: SimNode) -> String:
	if not Ascension.governor_open(state):
		return NEEDS_COUNCIL + ", en el legado"
	if node == null:
		return "no hay ningún nodo enfocado"
	if not node.governor_unlocked:
		return "hace falta un 🎖️ Sello"
	return ""


## 🎖️ Sella `node` y lo delega en el acto, con `Governor.balanced()`. Sellar es la forma de delegar
## un nodo sin sello: no hay un paso intermedio «sellado pero a mano». Un nodo que ya estaba
## delegado (por la primitiva) conserva su política. Retomar el mando después sigue siendo gratis.
##
## No gasta nada ni mira la puerta: eso es de `Shop.use_seal`, que también anota el `item_used`.
## Aquí sale el `governor {delegated: true}`, el mismo que `Main._on_delegation_toggled`, y solo si
## de verdad pasa a manos de un gobernador.
static func seal(state: WorldState, node: SimNode, events: SimEventLog) -> void:
	node.governor_unlocked = true
	if node.is_delegated():
		return
	delegate(state, node, Governor.balanced())
	if events != null:
		events.push("governor", state.cycle, node.id,
			"%s pasa a manos de un gobernador" % node.name, {"delegated": true})


## ⚡ El reloj con el que cuenta el gobernador de un nodo: el suyo (`SimNode.local_cycle`), que con
## un boost va por delante del mundo. **Nunca por detrás**: el boost solo adelanta, y quien mueve
## `state.cycle` sin pasar por `SimEngine.tick` (los tests que llaman a `run` sueltos) no puede
## dejar al gobernador sin checkpoints. Sin boost es `state.cycle`, bit a bit.
static func clock_of(state: WorldState, node: SimNode) -> float:
	return maxf(node.local_cycle, state.cycle)


static func _decide(
	state: WorldState, node: SimNode, params: SimParams, events: SimEventLog,
	mods: Integrator.Modifiers
) -> void:
	var sit := Situation.new()
	# Los pesos ya llevan la orden dentro: el sistema no sabe qué orden hay, solo con qué pesos
	# decide. Con `Order.NONE` son `normalized()` bit a bit.
	sit.weights = node.governor.effective_weights()
	# Mirar qué está limitando de verdad, con el mismo cálculo **y los mismos multiplicadores**
	# que usa la simulación. Sin ellos el gobernador decidía sobre una economía sin legado ni
	# peaje: otro techo, otras tasas. `mods` va tal cual, sin `combined`: `build_segment` ya le
	# compone `node.effects()` (`Integrator.build_segment`), igual que en `advance`.
	sit.snap = Integrator.snapshot(node, params, mods)
	sit.caps = node.storage_caps(params)
	_survey(node, sit)

	# El rastro solo se arma si alguien lo escucha: con él apagado, el checkpoint cuesta lo que
	# costaba. Encendido, **solo lee**: copia el reparto antes de tocarlo (`duplicate` de un
	# array empaquetado es una copia, no una vista) para medir cuánto se movió.
	var tracing := events != null and events.tracing
	var jobs_before := PackedFloat64Array()
	if tracing:
		jobs_before = node.jobs.duplicate()

	# Primero la gente: las urgencias que faltan se leen del reparto ya hecho, no del anterior.
	_rebalance_jobs(node, sit)
	sit.idle_share = Integrator.idle_population(node) / maxf(node.pop, 1.0)
	sit.housing_urgency = _housing_urgency(node, sit)

	var jobs_moved := 0.0
	if tracing:
		jobs_moved = _jobs_moved(jobs_before, node.jobs)

	# De aquí abajo, todo lo que gasta. Cada decisión lleva su permiso: el jugador delega el
	# trabajo de repartir sin delegar por fuerza el de gastarse el almacén.
	var g := node.governor

	var built: Pick = null
	if g.may_build:
		built = _build_best(state, node, sit, events)
	# Construir manda: con lo que quede después, se investiga.
	var upgraded: Pick = null
	if g.may_research:
		upgraded = _buy_best_upgrade(state, node, sit, events)

	# Un nodo delegado sube de escala solo. Promocionar es techo nuevo y nada más: no hay
	# contrapartida que sopesar, y sin esto un asentamiento delegado no llegaría nunca a ver la
	# cantera, el taller ni las mejoras de pueblo.
	var promoted := false
	if g.may_promote and Promotion.can_promote(state, node):
		promoted = Promotion.promote(state, node, events)

	# Colonizar cuesta colonos y comida, así que solo cuando el núcleo ya no da más de sí. El
	# umbral fijo de antes (`w[P_EXPANSION] > 0.25`) era inalcanzable para un gobernador
	# equilibrado, que normaliza a 0,1 exactos: ningún nodo fundaba nunca.
	#
	# `Order.EXPAND` solo adelanta el umbral; el permiso y el resto de condiciones mandan igual.
	#
	# El freno es el hambre (`starving`), no `food_limited`: el techo `cap` ya es el mínimo de
	# alojamiento y comida, así que «al 90 % del techo» ya cuenta con la comida. Con
	# `food_limited` un pueblo con la comida justa —lo normal en uno sano y lleno— no fundaba
	# nunca, aunque no le faltara de nada.
	#
	# `Order.STOCKPILE` no funda nunca, y se dice aquí de forma explícita: acumular es no gastar
	# colonos ni comida en fuera. Antes lo impedía de rebote `food_limited` (Acumular no construye
	# granjas y se queda pegada a la comida); sin ese freno fundaba como sin orden.
	var found_at := FOUND_AT_CAP_EXPAND if g.order == Governor.Order.EXPAND else FOUND_AT_CAP
	var founded := false
	if g.may_expand and g.order != Governor.Order.STOCKPILE \
			and sit.weight(P_EXPANSION) > 0.0 and not sit.snap.starving \
			and node.pop >= sit.snap.cap * found_at \
			and Promotion.can_found_child(state, node, params) \
			and may_found_by_heirs(state, node):
		# Lo que funda un gobernador nace delegado, con una copia de su política: la colonia es
		# parte de lo que se le delegó al padre, y una que no lleva nadie se queda para siempre en
		# su granja y su leñador. Se decide **aquí**, no en `launch_expedition`: la función
		# compartida hace lo mismo para el jugador y para el gobernador, y delegar es cosa de quien
		# funda. La política viaja con la expedición y se aplica al llegar.
		var sent := Promotion.launch_expedition(state, node, params, events,
			g.duplicate_governor())
		founded = sent != null

	# Las rutas de comida, las últimas: leen el reparto de gente que se acaba de hacer, y solo en
	# una región con hijos. El gobernador de un hijo no las toca: las lleva quien las paga.
	if g.may_route and node.tier >= Content.REGION and not node.children.is_empty():
		_route_food(state, node, params)

	# El rastro no se amplía con las rutas: `governor_decision` es un evento de Augur con su
	# catálogo, y eso es de otro plan.
	if tracing:
		_trace_decision(state, node, sit, events, built, upgraded, promoted, founded,
			jobs_moved)


# ---------------------------------------------------------------------------
# Rutas de comida (gobernador regional)
# ---------------------------------------------------------------------------

## Paso al que el gobernador redondea el caudal de una ruta. Es el mismo que el ± del jugador
## (`HUD.ROUTE_STEP`): lo que pone el gobernador se lee con los mismos números que lo que pondría
## él, y un paso cuesta 0,25 🐎/ciclo, lo que da un mozo de establo.
const ROUTE_STEP := 0.5

## Banda muerta alrededor del caudal actual: si lo que haría falta ahora está a menos de esto del
## caudal que ya lleva la ruta, la ruta no se toca. Es media vuelta de `ROUTE_STEP`. Sin ella, un
## mozo de establo que entra y sale con el reparto de cada checkpoint movía el presupuesto de 🐎
## medio paso y la ruta subía y bajaba un paso cada vez. Tocar una ruta es además un checkpoint
## suyo (`Logistics.set_route` repone `flow`), así que una que no cambia no se toca nunca.
const ROUTE_DEADBAND := 0.25


## Lo que el gobernador regional sabe de la comida de un nodo, **sin las rutas**: lo que el nodo
## necesita o le sobra por sí mismo. Medirlo con las rutas puestas haría que una ruta que ya da
## de comer a un hambriento lo sacase de la lista, y al checkpoint siguiente se borrase.
class FoodView:
	extends RefCounted
	var id: int = -1
	var surplus: float = 0.0   ## 🌾/ciclo que le sobran con la población a la que tiende
	var need: float = 0.0      ## 🌾/ciclo que le subirían el techo hasta su alojamiento, con tope
	var starving: bool = false


## Lleva todas las rutas que paga esta región con sus hijos, y solo de comida.
##
## Busca el nodo con más excedente —la región o un hijo— y le hace llegar comida a los que pasan
## hambre o tienen el techo marcado por la comida, primero a los que pasan hambre y después por
## orden de id. Como las rutas solo van entre padre e hijo (`Logistics.route_blocker`), si el que
## da y el que recibe son dos hijos la comida pasa por la región: una ruta sube y otra baja, y la
## región paga el 🐎 de las dos. El caudal total no pasa de lo que la región paga con su
## producción neta de 🐎. Las rutas que no salen de aquí —también las que el jugador creó a mano,
## y las que no son de comida— se borran: delegar es entregar el reparto, como con los oficios.
##
## Todo por `Logistics.set_route`, la misma función que el ± del jugador. Coste: un
## `build_segment` por nodo, O(hijos), y solo en regiones.
static func _route_food(state: WorldState, node: SimNode, params: SimParams) -> void:
	var views: Array[FoodView] = [_food_view(node, params)]
	var kids := node.children.duplicate()
	kids.sort()
	for id in kids:
		var child: SimNode = state.nodes.get(id)
		if child != null:
			views.append(_food_view(child, params))

	# El que más da; a igualdad, el primero (la región y luego los hijos por id).
	var donor: FoodView = null
	for v in views:
		if v.surplus > EPS and (donor == null or v.surplus > donor.surplus):
			donor = v

	# Caudal deseado por ruta, «desde:hasta» → [desde, hasta, caudal redondeado, caudal crudo]. El
	# crudo es lo que haría falta sin redondear, y es contra lo que se mide la banda muerta.
	var wanted := {}
	var budget_total := _transport_budget(node, params)
	if donor != null:
		var receivers: Array[FoodView] = []
		for v in views:
			if v != donor and v.need > EPS and v.starving:
				receivers.append(v)
		for v in views:
			if v != donor and v.need > EPS and not v.starving:
				receivers.append(v)
		var supply := donor.surplus
		var budget := budget_total
		for v in receivers:
			# Una ruta directa si uno de los dos es la región; dos, pasando por ella, si no.
			var legs := 1 if donor.id == node.id or v.id == node.id else 2
			var raw := minf(v.need, minf(supply, budget / legs))
			var flow := minf(ceilf(v.need / ROUTE_STEP) * ROUTE_STEP,
				minf(_floor_step(supply), _floor_step(budget / legs)))
			if flow <= 0.0:
				continue
			supply -= flow
			budget -= flow * legs
			if donor.id == node.id or v.id == node.id:
				_want(wanted, donor.id, v.id, flow, raw)
			else:
				_want(wanted, donor.id, node.id, flow, raw)
				_want(wanted, node.id, v.id, flow, raw)

	# La banda muerta solo si cabe en el presupuesto: quedarse medio paso por encima de lo que se
	# paga vaciaría el almacén de 🐎 y cortaría todas las rutas antes de cada checkpoint.
	var keep := {}
	var kept_cost := 0.0
	for key in wanted:
		kept_cost += float(wanted[key][2])
	for r in state.routes:
		var key := "%d:%d" % [r.from_id, r.to_id]
		if r.good == Goods.FOOD and wanted.has(key) \
				and absf(float(wanted[key][3]) - r.rate) < ROUTE_DEADBAND:
			keep[key] = true
			kept_cost += r.rate - float(wanted[key][2])
	if kept_cost > budget_total + EPS:
		keep.clear()

	# Primero lo que ya existe, en orden de id; `set_route` puede borrar, así que sobre una copia.
	for r in state.routes.duplicate():
		if not r.touches(node.id) or Logistics.payer_of(state, r) != node.id:
			continue  # una ruta con el padre de la región la lleva el padre
		var key := "%d:%d" % [r.from_id, r.to_id]
		if r.good != Goods.FOOD or not wanted.has(key):
			Logistics.set_route(state, r.from_id, r.to_id, r.good, 0.0)
			continue
		var rate: float = wanted[key][2]
		wanted.erase(key)
		if not keep.has(key) and rate != r.rate:
			Logistics.set_route(state, r.from_id, r.to_id, r.good, rate)
	# Después las nuevas, en el orden en que se decidieron. El `Dictionary` guarda el orden de
	# inserción, que sale de recorrer los nodos por id: es determinista.
	for key in wanted:
		var w: Array = wanted[key]
		if Logistics.route_blocker(state, w[0], w[1], Goods.FOOD).is_empty():
			Logistics.set_route(state, w[0], w[1], Goods.FOOD, w[2])


static func _want(wanted: Dictionary, from_id: int, to_id: int, flow: float, raw: float) -> void:
	var key := "%d:%d" % [from_id, to_id]
	if wanted.has(key):
		wanted[key][2] += flow
		wanted[key][3] += raw
	else:
		wanted[key] = [from_id, to_id, flow, raw]


static func _floor_step(value: float) -> float:
	return floorf(value / ROUTE_STEP + EPS) * ROUTE_STEP


## Lo que necesita y lo que le sobra a un nodo **por sí mismo**: el mismo `build_segment` que la
## simulación, con las rutas quitadas solo para la medida y repuestas al salir. No toca nada más:
## `route_offset` no se guarda ni entra en el hash, y aun así sale exactamente como entró.
static func _food_view(node: SimNode, params: SimParams) -> FoodView:
	var saved := node.route_offset
	node.route_offset = PackedFloat64Array()
	var seg := Integrator.build_segment(node, params, Integrator.Modifiers.none())
	node.route_offset = saved

	var v := FoodView.new()
	v.id = node.id
	v.starving = seg.starving
	# Lo que cada habitante de más le cuesta en comida, neto de lo que produce: la misma
	# `margin` de `Integrator._food_capacity`.
	var margin := -seg.slope[Goods.FOOD]
	if seg.food_limited:
		if margin > EPS:
			# Hasta el alojamiento, pero no más allá del tope de dependencia: lo de más llenaría el
			# almacén y no subiría el techo (`SimParams.food_import_cap`).
			v.need = minf((seg.raw_housing - seg.food_capacity) * margin,
				params.food_import_cap * seg.food_capacity * margin)
	else:
		# El excedente con la población a la que tiende, no con la de ahora: un nodo que aún crece
		# come más dentro de poco, y regalar lo que va a necesitar lo dejaría con hambre.
		var pop := maxf(node.pop, seg.housing)
		v.surplus = maxf(seg.slope[Goods.FOOD] * pop + seg.offset[Goods.FOOD], 0.0)
	return v


## Unidades de caudal que la región paga con su producción neta de 🐎, sin contar lo que ya gasta
## en rutas: el reparto se rehace entero, así que lo que gastan las de ahora vuelve a estar libre.
static func _transport_budget(node: SimNode, params: SimParams) -> float:
	var saved := node.route_offset
	node.route_offset = PackedFloat64Array()
	var seg := Integrator.build_segment(node, params, Integrator.Modifiers.none())
	node.route_offset = saved
	var net := seg.slope[Goods.TRANSPORT] * node.pop + seg.offset[Goods.TRANSPORT]
	return maxf(net, 0.0) / Logistics.TRANSPORT_PER_FLOW


## Por debajo de esto, un checkpoint que solo ha vuelto a repartir no ha hecho nada que valga
## un registro: es el redondeo del reparto, no una decisión. Si el tablero sale ruidoso, se
## sube esto; no se quita el evento.
const TRACE_JOBS_MOVED := 0.5

## Fracción del techo a partir de la cual la población se da por **frenada** por él. El
## crecimiento es logístico y nunca toca el techo del todo; por debajo de esto el nodo aún crece
## con holgura y no le limita nada.
const TRACE_AT_CAP := 0.95


## Emite `governor_decision` si el checkpoint hizo algo. Solo lee el nodo y la `Situation` y
## copia **escalares** a un Dictionary nuevo: la `Situation` muere al salir de `_decide`, y si
## se colase una referencia el SDK acabaría serializando un objeto.
static func _trace_decision(
	state: WorldState, node: SimNode, sit: Situation, events: SimEventLog,
	built: Pick, upgraded: Pick, promoted: bool, founded: bool, jobs_moved: float
) -> void:
	var did_build := built != null and built.done
	var did_upgrade := upgraded != null and upgraded.done
	if not (did_build or did_upgrade or promoted or founded or jobs_moved > TRACE_JOBS_MOVED):
		return

	var actions := PackedStringArray()
	if did_build:
		actions.append("build:" + built.winner)
	if did_upgrade:
		actions.append("upgrade:" + upgraded.winner)
	if promoted:
		actions.append("promote")
	if founded:
		actions.append("found")
	if jobs_moved > TRACE_JOBS_MOVED:
		actions.append("jobs")

	# `limit`, con la misma vara que el HUD y el propio gobernador (`Integrator.snapshot`): si
	# la comida pone el techo, es la comida; si no, el techo es el alojamiento, pero solo
	# **frena** cuando la población ya está pegada a él. Antes de eso no limita nada.
	var limit := "none"
	if sit.snap.food_limited:
		limit = "food"
	elif node.pop >= sit.snap.cap * TRACE_AT_CAP:
		limit = "housing"

	var shortage := 0
	for v in sit.shortage:
		shortage += 1 if v == 1 else 0

	# El segundo candidato solo tiene sentido si hubo ganador: sin compra, «casi construyó»
	# no es nada.
	var runner_up := ""
	var runner_up_score := 0.0
	var built_score := 0.0
	if did_build:
		built_score = built.score
		runner_up = built.runner_up
		runner_up_score = built.runner_up_score

	var data := {
		"node_id": node.id,
		"tier": node.tier,
		"depth": _depth(state, node),
		"actions": ",".join(actions),
		"built": built.winner if did_build else "",
		"built_score": built_score,
		"runner_up": runner_up,
		"runner_up_score": runner_up_score,
		"upgraded": upgraded.winner if did_upgrade else "",
		"promoted": promoted,
		"founded": founded,
		"jobs_moved": jobs_moved,
		"limit": limit,
		"food_limited": sit.snap.food_limited,
		"housing_urgency": sit.housing_urgency,
		"storage_urgency": sit.storage_urgency,
		"idle_share": sit.idle_share,
		"shortage": shortage,
		"w_food": sit.weights[P_FOOD],
		"w_growth": sit.weights[P_GROWTH],
		"w_industry": sit.weights[P_INDUSTRY],
		"w_expansion": sit.weights[P_EXPANSION],
	}
	events.trace("governor_decision", state.cycle, node.id, data)


## Personas que han cambiado de oficio: Σ|Δjobs|. Un traslado de uno cuenta dos (sale de un
## oficio y entra en otro), igual que lo cuenta el reparto.
static func _jobs_moved(before: PackedFloat64Array, after: PackedFloat64Array) -> float:
	var moved := 0.0
	for i in after.size():
		var prev := before[i] if i < before.size() else 0.0
		moved += absf(after[i] - prev)
	return moved


## El tope de herederos: un gobernador solo coloniza si su nodo no está más hondo en el árbol
## (raíz = 0) que las generaciones que paga `Dinastía` en el legado. Base 0: solo la raíz.
##
## Sin él, cada colonia delegada copia `may_expand` y funda las suyas, y el árbol crece
## exponencialmente: 12 h fuera con la raíz delegada eran 29 s y 1.507 nodos. Va aquí y no en
## `Promotion.can_found_child`, porque lo que funda el jugador a mano no tiene tope.
##
## Se evalúa la última de la condición de fundar: `Ascension.bonuses` recorre el legado, y
## solo merece la pena cuando todo lo demás ya dice que sí.
static func may_found_by_heirs(state: WorldState, node: SimNode) -> bool:
	return _depth(state, node) <= Ascension.bonuses(state).heirs


## Distancia a la raíz. Lee la cadena de padres; un padre que ya no existe corta la cuenta.
static func _depth(state: WorldState, node: SimNode) -> int:
	var depth := 0
	var parent_id := node.parent_id
	while parent_id >= 0:
		var parent: SimNode = state.nodes.get(parent_id)
		if parent == null:
			break
		depth += 1
		parent_id = parent.parent_id
	return depth


# ---------------------------------------------------------------------------
# Qué hace falta ahora mismo
# ---------------------------------------------------------------------------

## Lo que vale producir un recurso en este momento, mezclando la política con el estado real.
##
## Es la pieza compartida por las tres decisiones —a quién mandar a trabajar, qué construir y
## qué investigar—: si un recurso hace falta, tiene que hacer falta en las tres a la vez.
static func _good_weight(good: int, node: SimNode, sit: Situation) -> float:
	var weight := sit.weight(_axis_of(good))

	# La comida manda: si es ella la que pone el techo, su peso sube pase lo que pase en la
	# política.
	if good == Goods.FOOD and sit.snap.food_limited:
		return maxf(weight, 0.7)

	# Hace falta para lo siguiente, no hay y no entra: es **el** cuello de botella, por poco
	# que la política valore su rama.
	#
	# Pero **no durante una hambruna**: `URGENT` (1,5) le gana al suelo de 0,7 que se acaba de
	# dar a la comida, así que un pueblo con una mejora cara pendiente vaciaba las granjas y se
	# iba entero a la cantera a por una piedra que no le iba a dar de comer. Se muere de hambre
	# antes de terminar de ahorrar. Mismo margen que abajo: escasez manda solo si el campo da
	# de comer con holgura.
	if sit.shortage[good] == 1 and sit.snap.food_capacity >= node.pop * 1.25:
		return weight + URGENT

	if sit.caps[good] != INF and node.stocks[good] >= sit.caps[good] - FULL_EPS:
		# Con el granero lleno sobran granjeros… salvo que el campo esté dando de comer justo a
		# la gente que hay. Quitar brazos ahí no libera mano de obra: provoca la hambruna.
		if good == Goods.FOOD and sit.snap.food_capacity < node.pop * 1.25:
			return weight
		weight *= SATURATED

	return weight


## Cuánto vale un oficio: la suma de todo lo que el edificio produce **de más de lo que gasta**.
##
## Sumar sobre todos los recursos, y no clasificar por el primero que casa, es lo que hace que
## cantera, taller, mercado y templo dejen de ser el mismo oficio a ojos del gobernador.
static func _workplace_weight(b: BuildingDef, node: SimNode, sit: Situation) -> float:
	var weight := 0.0
	for good in Goods.COUNT:
		if b.produces[good] - b.consumes[good] > EPS:
			weight += _good_weight(good, node, sit)
	return weight * _input_factor(b, node)


## Un oficio sin materia prima no produce nada. El taller consume madera y el templo oro: sin
## mirar `consumes`, el gobernador mandaba gente a fabricar de la nada.
static func _input_factor(b: BuildingDef, node: SimNode) -> float:
	for good in Goods.COUNT:
		if b.consumes[good] > 0.0 and node.stocks[good] <= EPS:
			return STARVED
	return 1.0


## Solo urge alojar si es el alojamiento lo que frena, ya está casi lleno **y hay a quien poner
## a trabajar**: una cabaña más para gente que ya está ociosa no produce nada.
static func _housing_urgency(node: SimNode, sit: Situation) -> float:
	if sit.snap.food_limited or node.pop < sit.snap.housing * 0.85:
		return 0.0
	return URGENT * maxf(1.0 - sit.idle_share / IDLE_SHARE_OK, 0.0)


## Recorre lo que este nodo podría querer —todos sus edificios y todas sus mejoras— y saca de
## ahí las dos cosas que no se leen de un stock suelto:
##
##   - **Escasez**: un recurso que algo pide, no hay, y nadie está produciendo. Es la señal que
##     arranca la economía de una escala nueva. Sin ella, un pueblo recién ascendido no abre
##     jamás la cantera: la piedra pesa poco «en general» y él no sabe que la necesita.
##   - **Urgencia de almacén**: un almacén no urge por estar lleno —eso es abundancia—, sino
##     cuando **el tope impide pagar lo siguiente**. Medirlo por «hay un stock a tope» llevaba
##     a un asentamiento con ocho almacenes y ninguna cantera, porque la comida se llena sola
##     en cuanto sobra un granjero y eso no es ninguna emergencia.
static func _survey(node: SimNode, sit: Situation) -> void:
	for bi in Content.buildings_for_tier(node.tier):
		_weigh_cost(Construction.cost_of(node, bi), node, sit)
	for def in Upgrading.tree_for(node):
		var d: Upgrades.Def = def
		if not Upgrading.owns(node, d.id):
			_weigh_cost(d.cost, node, sit)


static func _weigh_cost(cost: PackedFloat64Array, node: SimNode, sit: Situation) -> void:
	for i in Goods.COUNT:
		if cost[i] > sit.caps[i]:
			# Ni ahorrando cabe: lo que falta es almacén, no producción.
			sit.storage_urgency = URGENT
		elif cost[i] > node.stocks[i] and sit.snap.rates[i] <= EPS \
				and node.stocks[i] < sit.caps[i] - FULL_EPS:
			# Un recurso que ya sube llegará solo; el que no entra en absoluto, no.
			sit.shortage[i] = 1


# ---------------------------------------------------------------------------
# Reparto de la mano de obra
# ---------------------------------------------------------------------------

## Reparte la mano de obra según las prioridades y lo que cada oficio aporta de verdad.
##
## Reparte **personas**, no pesos: desde que el reparto de oficios es explícito, el gobernador
## tiene que hacer exactamente el mismo trabajo que haría el jugador con los botones, y por
## las mismas funciones (`Construction.set_workers`).
static func _rebalance_jobs(node: SimNode, sit: Situation) -> void:
	var priority := {}
	var total_weight := 0.0
	for bi in node.buildings.size():
		var b := Content.building(bi)
		if node.buildings[bi] <= 0 or not b.is_workplace():
			# Un oficio sin edificio no es un oficio: se limpia en vez de arrastrar un reparto
			# viejo que la UI todavía lee. El caso normal —ya está a cero— sale gratis.
			if node.jobs[bi] != 0.0:
				Construction.set_workers(node, bi, 0.0)
			continue
		var weight := _workplace_weight(b, node, sit)
		priority[bi] = weight
		total_weight += weight
	if total_weight <= 0.0:
		return

	# Vaciar antes de repartir: si no, `set_workers` recorta contra las asignaciones viejas y
	# el reparto se queda pegado al del ciclo anterior.
	for bi in priority:
		Construction.set_workers(node, bi, 0.0)
	for bi in priority:
		var share: float = priority[bi] / total_weight
		Construction.set_workers(node, bi, floor(node.pop * share))

	# Lo que sobre, a quien todavía tenga puestos libres, por orden de prioridad.
	var order := priority.keys()
	order.sort_custom(func(a, b): return priority[a] > priority[b])
	for bi in order:
		if Integrator.idle_population(node) <= 0.0:
			break
		Construction.add_workers(node, bi, Integrator.idle_population(node))


# ---------------------------------------------------------------------------
# Construcción
# ---------------------------------------------------------------------------

## Construye el edificio más alineado con las prioridades que se pueda pagar. Devuelve el
## ganador y el segundo para el rastro; la compra es la de siempre.
static func _build_best(
	state: WorldState, node: SimNode, sit: Situation, events: SimEventLog
) -> Pick:
	var pick := Pick.new()
	var best := -1
	# `Order.STOCKPILE`: solo lo que se paga con lo que ya está desbordando.
	var stockpiling := node.governor.order == Governor.Order.STOCKPILE
	for bi in Content.buildings_for_tier(node.tier):
		if not Construction.can_build(node, bi):
			continue
		if stockpiling and not _spends_only_surplus(Construction.cost_of(node, bi), node, sit):
			continue
		var b := Content.building(bi)
		var score := _score(b, node, sit)
		# `offer` usa el mismo `>` estricto: el ganador del podio es siempre `best`.
		if score > pick.score:
			best = bi
		pick.offer(b.id, score)
	if best >= 0:
		pick.done = Construction.build(node, best, state.cycle, events)
	return pick


## La puntuación mezcla la política del jugador con el cuello de botella real.
##
## La versión anterior premiaba el alojamiento siempre, y el resultado era un gobernador que
## levantaba seis cabañas y una sola granja: alojamiento para 40 personas y comida para 7. Sin
## mirar cuál de los dos techos está por debajo, las prioridades por sí solas no bastan.
static func _score(b: BuildingDef, node: SimNode, sit: Situation) -> float:
	var score := _workplace_weight(b, node, sit)

	# Gente parada es un puesto que falta: con brazos de sobra, un oficio nuevo vale más que
	# otra cabaña, y es lo que hace que el gobernador llegue a la cantera y al taller.
	if b.is_workplace():
		score += URGENT * sit.idle_share

	if b.produces[Goods.FOOD] > 0.0 and sit.snap.food_limited:
		score += URGENT

	if b.housing > 0.0:
		score += sit.weight(P_GROWTH) + sit.housing_urgency

	var storage_total := 0.0
	for v in b.storage:
		storage_total += v
	if storage_total > 0.0:
		score += sit.weight(P_INDUSTRY) * 0.4 + sit.storage_urgency

	return score


## La guarda de `Order.STOCKPILE`: un coste pasa si **todo** lo que pide sale de almacenes al
## `STOCKPILE_SPEND_AT` de su tope o más. Lee el coste igual que `can_build` y `can_buy`, recurso
## a recurso, y lo que no pide (coste cero) no cuenta.
##
## Un recurso sin tope (`INF`, la cultura) nunca está «casi lleno», así que gastarlo veta la
## compra: no hay desbordamiento que aprovechar, y acumular sin gastar es lo que pide la orden.
static func _spends_only_surplus(
	cost: PackedFloat64Array, node: SimNode, sit: Situation
) -> bool:
	for i in Goods.COUNT:
		if cost[i] <= 0.0:
			continue
		if sit.caps[i] == INF or node.stocks[i] < sit.caps[i] * STOCKPILE_SPEND_AT:
			return false
	return true


# ---------------------------------------------------------------------------
# Investigación
# ---------------------------------------------------------------------------

## Compra la mejora más alineada con las prioridades, una por checkpoint como los edificios.
##
## Recorre el catálogo en su orden, que es fijo: dos partidas con la misma semilla toman la
## misma decisión, y avanzar de un salto da lo mismo que avanzar paso a paso.
static func _buy_best_upgrade(
	state: WorldState, node: SimNode, sit: Situation, events: SimEventLog
) -> Pick:
	var pick := Pick.new()
	# `Order.STOCKPILE`: la misma guarda que al construir.
	var stockpiling := node.governor.order == Governor.Order.STOCKPILE
	for def in Upgrading.tree_for(node):
		var d: Upgrades.Def = def
		# `can_buy` ya descarta la poseída, la de otra escala, la que no cumple requisitos y la
		# que no se puede pagar. Es la misma comprobación que apaga el botón del jugador.
		if not Upgrading.can_buy(node, d.id):
			continue
		if stockpiling and not _spends_only_surplus(d.cost, node, sit):
			continue
		pick.offer(d.id, _upgrade_score(d, node, sit))
	if pick.winner != "":
		pick.done = Upgrading.buy(node, pick.winner, state.cycle, events)
	return pick


## Lo que aporta una mejora, medido con la misma vara que los edificios.
##
## Todos los efectos son multiplicadores (contrato de `Upgrades`), así que la magnitud es
## `value - 1` y se pondera por el peso de aquello que multiplica.
static func _upgrade_score(d: Upgrades.Def, node: SimNode, sit: Situation) -> float:
	var score := 0.0
	for effect in d.effects:
		var e: Upgrades.Effect = effect
		# 🛤️ Carreteras es el único efecto que vale por debajo de 1: acorta, así que lo que
		# aporta es `1 - value`. Pesa lo que pesa expandirse, y solo si al nodo le queda alguna
		# plaza de hijo por llenar y se le deja fundar: sin eso, el reloj no se va a usar nunca.
		# Sin esta rama la magnitud saldría negativa y no la compraría jamás.
		if e.kind == Upgrades.Kind.EXPEDITION:
			if node.governor != null and node.governor.may_expand \
					and node.def().child_slots - node.children.size() > 0:
				score += (1.0 - e.value) * sit.weight(P_EXPANSION)
			continue
		var magnitude := e.value - 1.0
		if magnitude <= 0.0:
			continue
		match e.kind:
			Upgrades.Kind.PRODUCTION:
				# Sube todo a la vez: vale lo que valen las tres prioridades productivas.
				score += magnitude * (sit.weight(P_FOOD) + sit.weight(P_GROWTH)
					+ sit.weight(P_INDUSTRY))
			Upgrades.Kind.FOOD:
				var urgency := URGENT if sit.snap.food_limited else 0.0
				score += magnitude * (sit.weight(P_FOOD) + urgency)
			Upgrades.Kind.GROWTH:
				score += magnitude * sit.weight(P_GROWTH)
			Upgrades.Kind.HOUSING:
				score += magnitude * (sit.weight(P_GROWTH) + sit.housing_urgency)
			Upgrades.Kind.STORAGE:
				score += magnitude * (sit.weight(P_INDUSTRY) * 0.4 + sit.storage_urgency)
			Upgrades.Kind.BUILDING_PRODUCTION:
				score += magnitude * _building_effect_weight(e, node, sit, false)
			Upgrades.Kind.SLOTS:
				score += magnitude * _building_effect_weight(e, node, sit, true)
	return score


## Lo que vale mejorar un tipo de edificio concreto: **nada** si no hay ninguno construido —
## nadie compra vagonetas sin cantera—, y poco si es de puestos y los que ya existen están a
## medio llenar.
static func _building_effect_weight(
	e: Upgrades.Effect, node: SimNode, sit: Situation, slots: bool
) -> float:
	var bi := Content.building_index(e.building)
	if bi < 0 or node.buildings[bi] <= 0:
		return 0.0
	var weight := _workplace_weight(Content.building(bi), node, sit)
	if slots and node.jobs[bi] < node.capacity_of(bi) - EPS:
		weight *= IDLE_SLOTS
	return weight
