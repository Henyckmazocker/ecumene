class_name Upgrading
extends RefCounted

## Compra y efecto de las mejoras. Mismo reparto que hay entre `data/Legacy.gd` y
## `sim/systems/Ascension.gd`: el catálogo son datos, la lógica es un sistema puro.
##
## Los efectos se **cachean en el nodo** (`SimNode.effects()`) porque `capacity_of`,
## `housing()` y `storage_caps()` se llaman en bucles calientes del HUD y del integrador.
## La caché se invalida al comprar; nunca hay que acordarse de refrescarla a mano.

## En qué punto del árbol está una mejora. Lo pinta el HUD; la lógica de compra no lo mira.
enum State {
	OWNED,      ## ya comprada
	AVAILABLE,  ## requisitos cumplidos, falte o no el dinero
	LOCKED,     ## le falta algún requisito
}


static func owns(node: SimNode, id: String) -> bool:
	return node.upgrades.has(id)


## Está a la vista: la escala da para ella y sus requisitos están cumplidos. Se enseña aunque
## no se pueda pagar — saber qué viene después es la mitad del enganche de un incremental.
static func is_available(node: SimNode, id: String) -> bool:
	var def: Upgrades.Def = Upgrades.get_def(id)
	if def == null or owns(node, id) or def.tier_min > node.tier:
		return false
	for required in def.requires:
		if not owns(node, required):
			return false
	return true


static func can_afford(node: SimNode, id: String) -> bool:
	var def: Upgrades.Def = Upgrades.get_def(id)
	if def == null:
		return false
	for i in Goods.COUNT:
		if node.stocks[i] < def.cost[i]:
			return false
	return true


static func can_buy(node: SimNode, id: String) -> bool:
	return is_available(node, id) and can_afford(node, id)


## Única ruta de compra. Como `Construction.build`, la usan igual el jugador y el gobernador.
static func buy(node: SimNode, id: String, cycle: float, events: SimEventLog) -> bool:
	if not can_buy(node, id):
		return false
	var def: Upgrades.Def = Upgrades.get_def(id)
	for i in Goods.COUNT:
		node.stocks[i] -= def.cost[i]
	node.upgrades.append(id)
	node.invalidate_effects()
	if events != null:
		events.push("upgrade", cycle, node.id,
			"%s investiga %s" % [node.name, def.name],
			{"upgrade": id, "effects": def.describe()})
	return true


static func state_of(node: SimNode, id: String) -> int:
	if owns(node, id):
		return State.OWNED
	var def: Upgrades.Def = Upgrades.get_def(id)
	if def == null:
		return State.LOCKED
	for required in def.requires:
		if not owns(node, required):
			return State.LOCKED
	return State.AVAILABLE


## El árbol entero tal y como se ve desde un nodo: compradas, disponibles y bloqueadas, en
## orden de catálogo.
##
## Enseñar solo la frontera —que es lo que hacía la versión anterior de esto— deja al jugador
## con una rejilla de botones que aparecen y desaparecen sin decir de dónde vienen. La forma de
## la progresión es la mitad del enganche de un incremental, así que se enseña entera.
##
## El tier sí es una frontera de verdad: hasta promocionar, esa parte del árbol no existe para
## este nodo y no se insinúa siquiera. Lo que se promete tiene que poder cumplirse hoy.
static func tree_for(node: SimNode) -> Array:
	var out := []
	for def in Upgrades.all():
		if (def as Upgrades.Def).tier_min <= node.tier:
			out.append(def)
	return out
