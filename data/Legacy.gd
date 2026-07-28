class_name Legacy
extends RefCounted

## Árbol de legado: lo único que sobrevive a una ascensión.
##
## Cada nodo es comprable varias veces (`max_ranks`) y su efecto es un multiplicador plano.
## Que los efectos sean multiplicadores constantes es deliberado: entran en el integrador
## como parte de `mult` sin romper la linealidad de la que depende la forma cerrada.

enum Effect {
	PRODUCTION,      ## multiplicador general de producción
	FOOD,            ## multiplicador de producción de comida
	GROWTH,          ## multiplicador del crecimiento de población
	HOUSING,         ## multiplicador del alojamiento
	OFFLINE_CAP,     ## horas extra de crédito offline
	OFFLINE_RATE,    ## eficiencia offline extra
	GOVERNOR,        ## eficiencia extra de los nodos delegados
	START_LEGACY,    ## recursos de partida en cada era nueva
}

class Node_:
	extends RefCounted
	var id: String
	var name: String
	var description: String
	var effect: Effect
	var per_rank: float
	var max_ranks: int
	var base_cost: float
	var cost_growth: float

	func cost_for(rank: int) -> float:
		return base_cost * pow(cost_growth, float(rank))


static var _nodes: Array = []
static var _by_id: Dictionary = {}


static func nodes() -> Array:
	if _nodes.is_empty():
		_build()
	return _nodes


static func get_node_def(id: String) -> Node_:
	if _by_id.is_empty():
		_build()
	return _by_id.get(id)


static func _make(
	id: String, name: String, description: String,
	effect: Effect, per_rank: float, max_ranks: int, base_cost: float, cost_growth: float
) -> Node_:
	var n := Node_.new()
	n.id = id
	n.name = name
	n.description = description
	n.effect = effect
	n.per_rank = per_rank
	n.max_ranks = max_ranks
	n.base_cost = base_cost
	n.cost_growth = cost_growth
	return n


static func _build() -> void:
	_nodes = [
		_make("fertile_soil", "Tierra fértil",
			"La memoria de las cosechas viaja contigo: +12 % de producción de comida por rango.",
			Effect.FOOD, 0.12, 5, 2.0, 2.2),
		_make("old_crafts", "Oficios antiguos",
			"Las técnicas no se olvidan: +10 % de producción general por rango.",
			Effect.PRODUCTION, 0.10, 8, 3.0, 2.4),
		_make("lineage", "Linaje",
			"Los tuyos se multiplican más rápido: +8 % de crecimiento por rango.",
			Effect.GROWTH, 0.08, 5, 4.0, 2.3),
		_make("stone_roots", "Raíces de piedra",
			"Se construye más denso: +10 % de alojamiento por rango.",
			Effect.HOUSING, 0.10, 5, 4.0, 2.3),
		_make("chronicle", "Crónica",
			"El mundo sigue sin ti: +12 h de crédito offline por rango.",
			Effect.OFFLINE_CAP, 12.0, 4, 6.0, 2.5),
		_make("night_watch", "Guardia nocturna",
			"Lo que ocurre mientras duermes cunde más: +10 % de eficiencia offline por rango.",
			Effect.OFFLINE_RATE, 0.10, 5, 8.0, 2.5),
		_make("stewards", "Escuela de gobernadores",
			"Delegar duele menos: +4 % de eficiencia en los nodos delegados por rango.",
			Effect.GOVERNOR, 0.04, 4, 10.0, 2.6),
		_make("first_stones", "Primeras piedras",
			"Cada era nueva empieza con provisiones: +100 de comida y madera por rango.",
			Effect.START_LEGACY, 100.0, 3, 5.0, 2.4),
	]
	_by_id = {}
	for n in _nodes:
		_by_id[n.id] = n
