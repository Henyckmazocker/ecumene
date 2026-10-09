class_name Legacy
extends RefCounted

## Árbol de legado: lo único que sobrevive a una ascensión.
##
## Cada nodo es comprable varias veces (`max_ranks`) y su efecto es un multiplicador plano.
## Que los efectos sean multiplicadores constantes es deliberado: entran en el integrador
## como parte de `mult` sin romper la linealidad de la que depende la forma cerrada.
##
## **Tiene forma de árbol**, como las mejoras por nodo: `requires` encadena los nodos en dos
## ramas —una de mundo vivo y otra de tiempo ausente—. Plano era una lista de la compra en la
## que el legado se iba en lo primero que pillabas; encadenado, gastarlo es elegir una rama.

enum Effect {
	PRODUCTION,      ## multiplicador general de producción
	FOOD,            ## multiplicador de producción de comida
	GROWTH,          ## multiplicador del crecimiento de población
	HOUSING,         ## multiplicador del alojamiento
	OFFLINE_CAP,     ## horas extra de crédito offline
	OFFLINE_RATE,    ## eficiencia offline extra
	GOVERNOR,        ## eficiencia extra de los nodos delegados
	START_LEGACY,    ## recursos de partida en cada era nueva
	HEIRS,           ## generaciones de colonias delegadas que también colonizan
	EXPEDITION,      ## fracción que se resta a la duración de las expediciones
	GOVERNOR_UNLOCK, ## sellos de regalo por era; rango ≥ 1 abre la delegación
}

class Node_:
	extends RefCounted
	var id: String
	var name: String
	var icon: String
	var description: String
	var effect: Effect
	var per_rank: float
	var max_ranks: int
	var base_cost: float
	var cost_growth: float
	## Nodos de los que cuelga. Basta un rango de cada uno para desbloquearlo.
	var requires: PackedStringArray = PackedStringArray()

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
	id: String, name: String, icon: String, description: String,
	effect: Effect, per_rank: float, max_ranks: int, base_cost: float, cost_growth: float,
	requires: Array = []
) -> Node_:
	var n := Node_.new()
	n.id = id
	n.name = name
	n.icon = icon
	n.description = description
	n.effect = effect
	n.per_rank = per_rank
	n.max_ranks = max_ranks
	n.base_cost = base_cost
	n.cost_growth = cost_growth
	n.requires = PackedStringArray(requires)
	return n


## Las ramas cuelgan de tres raíces: **la tierra** (lo que produce el mundo mientras juegas),
## **la crónica** (lo que ocurre mientras no estás) y **el consejo** (lo que mandas sin estar). El
## orden de la lista solo decide el de las raíces; a cada hijo lo coloca bajo su padre quien
## dibuja el árbol.
static func _build() -> void:
	_nodes = [
		_make("fertile_soil", "Tierra fértil", "🌾",
			"La memoria de las cosechas viaja contigo: +12 % de producción de comida por rango.",
			Effect.FOOD, 0.12, 5, 2.0, 2.2),
		_make("chronicle", "Crónica", "📜",
			"El mundo sigue sin ti: +12 h de crédito offline por rango.",
			Effect.OFFLINE_CAP, 12.0, 4, 6.0, 2.5),
		# La llave de los gobernadores, no un bono: con un rango se puede delegar lo que esté
		# sellado. Y cada rango regala un 🎖️ Sello al comprarlo (`Ascension.buy`) y otro al
		# empezar cada era (`Ascension.ascend`), porque el oro para comprarlo solo llega en Ciudad y sin él la llave no abriría nada
		# hasta media era. A 6, una ascensión en Ciudad (28 de legado) la compra seguro.
		_make("council", "Consejo", "🎖️",
			"Abre los gobernadores: cada nodo que selles se puede delegar. +1 🎖️ Sello al comprarlo y otro al empezar cada era, por rango.",
			Effect.GOVERNOR_UNLOCK, 1.0, 3, 6.0, 2.4),

		_make("old_crafts", "Oficios antiguos", "⚒️",
			"Las técnicas no se olvidan: +10 % de producción general por rango.",
			Effect.PRODUCTION, 0.10, 8, 3.0, 2.4, ["fertile_soil"]),
		_make("lineage", "Linaje", "👶",
			"Los tuyos se multiplican más rápido: +8 % de crecimiento por rango.",
			Effect.GROWTH, 0.08, 5, 4.0, 2.3, ["fertile_soil"]),
		_make("night_watch", "Guardia nocturna", "🌙",
			"Lo que ocurre mientras duermes cunde más: +10 % de eficiencia offline por rango.",
			Effect.OFFLINE_RATE, 0.10, 5, 8.0, 2.5, ["chronicle"]),

		_make("stewards", "Escuela de gobernadores", "🎓",
			"Delegar duele menos: +4 % de eficiencia en los nodos delegados por rango.",
			Effect.GOVERNOR, 0.04, 4, 10.0, 2.6, ["council"]),
		_make("stone_roots", "Raíces de piedra", "🪨",
			"Se construye más denso: +10 % de alojamiento por rango.",
			Effect.HOUSING, 0.10, 5, 4.0, 2.3, ["lineage"]),
		_make("first_stones", "Primeras piedras", "🧱",
			"Cada era nueva empieza con provisiones: +100 de comida y madera por rango.",
			Effect.START_LEGACY, 100.0, 3, 5.0, 2.4, ["night_watch"]),

		# El tope de herederos. Sin rangos solo coloniza delegando la raíz; cada rango deja fundar
		# a una generación más de colonias. Es un entero, no un multiplicador, como la crónica: el
		# freno del crecimiento exponencial del árbol delegado, que es lo que se compra. Cuesta
		# algo más que la escuela de la que cuelga (15 frente a 10, mismo crecimiento 2,6) porque
		# no es un bono más sino una escala de imperio entera que se pone a trabajar sola.
		_make("heirs", "Dinastía", "👑",
			"Tus colonias crían colonias: +1 generación de colonias delegadas que también fundan, por rango.",
			Effect.HEIRS, 1.0, 2, 15.0, 2.6, ["stewards"]),

		# El reloj de las expediciones. No es un multiplicador que entre en el integrador sino el
		# de un segmento: acorta la expedición **al salir** (`Promotion.expedition_cycles`) y no
		# toca la que ya está en camino. Resta y no compone, como pide el plan: 5 rangos dejan el
		# reloj en ×0,6. Cuelga de la tierra, como el linaje: son las dos maneras de que la era
		# nueva llene antes sus plazas.
		#
		# **Cuesta 2 y crece ×1,6, más barato que el linaje (4 y ×2,3).** Desde que Ciudad pide
		# hijos, lo que marca el reloj de la era es esperar expediciones, y la producción no lo
		# acorta. A 4 y ×2,3 una ascensión en Ciudad (28 de legado) daba para un rango y la era 2
		# llegaba a Ciudad a ×0,92 de la primera. A 2 · 3,2 · 5,1 · 8,2 · 13,1 entra justo detrás
		# de Tierra fértil y con esos 28 se compran tres rangos (−24 %) sin dejar de comprar los
		# de producción: la era 2 llega a Ciudad a ×0,77 y a Pueblo sigue a ×0,86 (era_probe,
		# M4 de «Plan - Balance de la era»). Por eso tampoco hace falta que `spend_legacy` lo
		# prefiera: el más barato primero ya lo intercala.
		#
		# Va al final de la lista y no junto al linaje porque `TestUtil.spend_legacy` desempata por
		# este orden. Con el coste de antes (4) empataba con «Raíces de piedra» y, delante, se la
		# quitaba en la era 2 (H6/H1 de 0,90 a 1,00). Con 2 · 3,2 · 5,1… ya no empata con nadie,
		# pero al final el desempate no puede volver a favorecerlo si se toca un coste.
		_make("old_roads", "Caminos antiguos", "🧭",
			"Los caminos de tus antepasados siguen ahí: −8 % de duración de las expediciones por rango.",
			Effect.EXPEDITION, 0.08, 5, 2.0, 1.6, ["fertile_soil"]),
	]
	_by_id = {}
	for n in _nodes:
		_by_id[n.id] = n
