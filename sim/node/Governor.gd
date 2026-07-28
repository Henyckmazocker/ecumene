class_name Governor
extends RefCounted

## Un gobernador **no es una IA que juega**: es una política que se evalúa dentro del tick
## agregado de su nodo. Por eso delegar escala a miles de nodos sin coste de simulación.
##
## Muta el mundo por exactamente las mismas funciones que el jugador (`Construction.build`,
## `Jobs.set_weights`, …): hay una sola ruta de mutación. Lo único que cambia al delegar es
## quién toma la decisión, y que el rendimiento del nodo baja a `governor_efficiency`
## — delegar es un intercambio, no un botón de ganar.

## Prioridades, en [0, 1]. Se normalizan al aplicarse.
@export var food: float = 0.4
@export var growth: float = 0.3
@export var industry: float = 0.2
@export var expansion: float = 0.1

## Órdenes puntuales que el jugador puede fijar por encima de las prioridades.
enum Order { NONE, STOCKPILE, EXPAND, SPECIALIZE }
var order: Order = Order.NONE

var name: String = "Gobernador"


static func balanced() -> Governor:
	return Governor.new()


func weights() -> PackedFloat64Array:
	return PackedFloat64Array([food, growth, industry, expansion])


func normalized() -> PackedFloat64Array:
	var w := weights()
	var sum := 0.0
	for v in w:
		sum += maxf(v, 0.0)
	if sum <= 0.0:
		return PackedFloat64Array([0.25, 0.25, 0.25, 0.25])
	for i in w.size():
		w[i] = maxf(w[i], 0.0) / sum
	return w


func duplicate_governor() -> Governor:
	var g := Governor.new()
	g.food = food
	g.growth = growth
	g.industry = industry
	g.expansion = expansion
	g.order = order
	g.name = name
	return g


func to_dict() -> Dictionary:
	return {
		"food": food, "growth": growth, "industry": industry,
		"expansion": expansion, "order": int(order), "name": name,
	}


static func from_dict(d: Dictionary) -> Governor:
	var g := Governor.new()
	g.food = float(d["food"])
	g.growth = float(d["growth"])
	g.industry = float(d["industry"])
	g.expansion = float(d["expansion"])
	g.order = int(d.get("order", 0)) as Order
	g.name = String(d.get("name", "Gobernador"))
	return g
