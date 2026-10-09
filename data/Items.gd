class_name Items
extends RefCounted

## Catálogo de objetos (plan «Objetos de tiempo»): lo que el jugador **posee** fuera de los nodos
## y del legado. El inventario vive en `WorldState.items` (id → cuántos) y sobrevive a la
## ascensión; aquí solo está qué es cada cosa y cuánto cuesta.
##
## Mismo patrón que `Legacy`: el catálogo se construye una vez y **su orden es el del contrato**.
## `WorldState.state_hash` y la tienda recorren el inventario por `all()`, nunca por las claves
## del diccionario, cuyo orden no forma parte del motor.

enum Kind {
	SKIP,    ## ⌛ avanza el mundo entero `cycles` ciclos (es tiempo online, regla 4)
	BOOST,   ## ⚡ un nodo va a ×`factor` durante `cycles` ciclos globales
	SEAL,    ## 🎖️ se define y se compra aquí; usarlo es del plan «Gobernador por sello»
}

class Def:
	extends RefCounted
	var id: String
	var name: String
	var icon: String
	var description: String
	var kind: Kind
	## SKIP: ciclos que avanza el mundo · BOOST: duración en ciclos globales · SEAL: 0.
	var cycles: float = 0.0
	## BOOST: 2 o 4 · el resto: 1.
	var factor: float = 1.0
	## `Goods.zeros()` con 🪙 y/o 📜: **cualquiera de los dos** paga el objeto entero, no la suma.
	var price: PackedFloat64Array = Goods.zeros()


static var _all: Array[Def] = []
static var _by_id: Dictionary = {}


static func all() -> Array[Def]:
	if _all.is_empty():
		_build()
	return _all


static func get_def(id: String) -> Def:
	if _by_id.is_empty():
		_build()
	return _by_id.get(id)


static func _make(
	id: String, name: String, icon: String, description: String,
	kind: Kind, cycles: float, factor: float, gold: float, culture: float
) -> Def:
	var d := Def.new()
	d.id = id
	d.name = name
	d.icon = icon
	d.description = description
	d.kind = kind
	d.cycles = cycles
	d.factor = factor
	d.price = Goods.zeros()
	d.price[Goods.GOLD] = gold
	d.price[Goods.CULTURE] = culture
	return d


## Precios ajustados en M5 con `era_probe` (la tabla «🛒 la primera Ciudad»): la raíz delegada,
## de H3c (Ciudad, ciclo 15.975) a H3c + 5.400 ciclos, produce **978.668 🪙** sin fijar (181 🪙/ciclo
## de media; 225 al cerrar la ventana) y **172.908 📜** (32 📜/ciclo). Las cuatro
## semillas del probe dan las mismas cifras.
##
## Criterio del plan: un `skip_1h` cuesta lo que esa ciudad produce en ~1,5 h de oro ⇒ **1.000.000 🪙**.
## Esperar la hora rinde ~650.000-800.000 🪙: comprar tiempo sale más caro que esperarlo, pero cabe
## de sobra en el almacén (tope 5,5 M en H3c, 11,4 M a la hora y media) y no es absurdo.
##
## 📜 a **1:5 y no 1:2**: la proporción 2:1 salía de Templo 0,3 frente a Mercado 0,5, pero el dato dice
## que en la primera Ciudad la cultura llega ~5,7 veces más despacio que el oro. Con 2:1 el ⌛
## costaría 4,3 h de cultura; con 1:5, 200.000 📜 ≈ 1,7 h, el mismo criterio que el oro y un poco
## más caro. El coste de verdad de la 📜 es otro: gastarla baja la 🎭
## influencia, la puerta de Región, y la tienda lo avisa.
##
## El resto, en proporción a `skip_1h` (= 1), como en los precios de partida, ×1.000 con el oro:
##   `skip_15m` 0,3 por ¼ de hora: el pequeño sale algo más caro por hora, es el que gotea gratis.
##   `skip_4h`  3,5 por 4 h: el grande, algo más barato por hora.
##   `boost_x2` 0,4 por 600 ciclos de más **de un nodo** (⅙ de la hora): más caro por ciclo que el
##              ⌛ porque se apunta a donde importa, y acelera también la expedición en camino.
##   `boost_x4` 1,2 = 3 × `boost_x2` por 3 × los ciclos de más (1.800): el mismo precio por ciclo.
##   `seal`     2, como en los precios de partida: es permanente y abre la delegación de un nodo, así
##              que cuesta dos horas de ⌛. Aquí solo se compra; usarlo es del plan «Gobernador por sello».
## Las 📜, todas a un quinto de su 🪙.
static func _build() -> void:
	_all = [
		_make("skip_15m", "Reloj de arena", "⌛",
			"El mundo entero avanza 15 minutos (900 ciclos).",
			Kind.SKIP, 900.0, 1.0, 300000.0, 60000.0),
		_make("skip_1h", "Reloj de arena grande", "⌛",
			"El mundo entero avanza una hora (3.600 ciclos).",
			Kind.SKIP, 3600.0, 1.0, 1000000.0, 200000.0),
		_make("skip_4h", "Reloj de arena antiguo", "⌛",
			"El mundo entero avanza cuatro horas (14.400 ciclos).",
			Kind.SKIP, 14400.0, 1.0, 3500000.0, 700000.0),
		_make("boost_x2", "Fervor", "⚡",
			"Un nodo va al doble de ritmo durante 600 ciclos: producción, gobernador y expedición.",
			Kind.BOOST, 600.0, 2.0, 400000.0, 80000.0),
		_make("boost_x4", "Frenesí", "⚡",
			"Un nodo va a ×4 durante 600 ciclos: producción, gobernador y expedición.",
			Kind.BOOST, 600.0, 4.0, 1200000.0, 240000.0),
		_make("seal", "Sello", "🎖️",
			"Un encargo para el gobernador. Se desbloquea con 🎖️ Consejo.",
			Kind.SEAL, 0.0, 1.0, 2000000.0, 400000.0),
	]
	_by_id.clear()
	for d in _all:
		_by_id[d.id] = d
