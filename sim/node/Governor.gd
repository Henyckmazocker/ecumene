class_name Governor
extends RefCounted

## Un gobernador **no es una IA que juega**: es una política que se evalúa dentro del tick
## agregado de su nodo. Por eso delegar escala a miles de nodos sin coste de simulación.
##
## Muta el mundo por exactamente las mismas funciones que el jugador
## (`Construction.set_workers`, `Construction.build`, `Upgrading.buy`, `Promotion.promote`):
## hay una sola ruta de mutación. Lo único que cambia al delegar es
## quién toma la decisión, y que el rendimiento del nodo baja a `governor_efficiency`
## — delegar es un intercambio, no un botón de ganar.

## Prioridades, en [0, 1]. Se normalizan al aplicarse.
@export var food: float = 0.4
@export var growth: float = 0.3
@export var industry: float = 0.2
@export var expansion: float = 0.1

## Hasta dónde llega la delegación. Delegar no es una rendición: el jugador sigue decidiendo
## **qué** puede hacer su gobernador, aunque ya no decida cada movimiento.
##
## Repartir la gente no lleva interruptor a propósito. Es lo único que un gobernador hace
## siempre; si no quieres que reparta, lo que no quieres es un gobernador.
var may_build := true
var may_research := true
var may_promote := true
var may_expand := true
## Llevar las rutas de comida entre una región y sus hijos (`GovernorSys._route_food`). Solo
## sirve en escala región o superior con hijos; en las demás no hace nada, y por eso las colonias
## que copian la política lo pueden heredar sin consecuencias.
var may_route := true

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


## Índices de `weights()`. Son los mismos que `GovernorSys.P_*`; se repiten aquí para que el
## modelo no dependa del sistema que lo lee.
const _FOOD := 0
const _GROWTH := 1
const _INDUSTRY := 2
const _EXPANSION := 3

## Cuánto pesa lo que una orden empuja, antes de volver a normalizar. Un ×2 sobre un eje que
## el jugador ya tenía alto lo pone por encima del resto sin borrar las prioridades: la orden
## sesga la política, no la sustituye.
const ORDER_BOOST := 2.0
## Cuánto pesa lo que una orden aparta. No es cero a propósito: un peso nulo apaga ramas
## enteras del gobernador (fundar exige `expansion > 0`, y un oficio sin peso no recibe gente).
const ORDER_DAMP := 0.25


## Los pesos con los que decide el gobernador: la política del jugador **sesgada por la orden**.
##
## Es el único sitio que sabe qué hace cada orden con los pesos; `GovernorSys` lee de aquí y no
## se entera de que existen. Con `Order.NONE` devuelve `normalized()` **sin tocarlo**: ni
## multiplicar por uno ni renormalizar, porque el último bit movería el reparto y con él el
## determinismo de todas las partidas que no usan órdenes.
func effective_weights() -> PackedFloat64Array:
	var w := normalized()
	match order:
		Order.NONE:
			return w
		Order.STOCKPILE:
			# Juntar es producir lo que se guarda —comida e industria— y no gastar colonos en
			# colonias.
			w[_FOOD] *= ORDER_BOOST
			w[_INDUSTRY] *= ORDER_BOOST
			w[_EXPANSION] *= ORDER_DAMP
		Order.EXPAND:
			# Fundar pide población cerca del techo, y el techo lo ponen las casas: expandir es
			# crecer. El umbral más bajo para fundar vive en `GovernorSys._decide`.
			w[_GROWTH] *= ORDER_BOOST
		Order.SPECIALIZE:
			# El eje dominante es el que más pesa en la política del jugador entre los tres
			# productivos; a igualdad gana el primero, que es un orden fijo. La salvaguarda de
			# hambre de `GovernorSys._good_weight` se aplica después, sobre estos pesos.
			var dominant := _FOOD
			for i in [_GROWTH, _INDUSTRY]:
				if w[i] > w[dominant]:
					dominant = i
			for i in w.size():
				if i != dominant:
					w[i] *= ORDER_DAMP
	return _renormalized(w)


## Vuelve a sumar uno tras el sesgo de una orden. Nunca divide por cero: `normalized()` siempre
## suma uno y los factores son positivos.
static func _renormalized(w: PackedFloat64Array) -> PackedFloat64Array:
	var sum := 0.0
	for v in w:
		sum += v
	for i in w.size():
		w[i] /= sum
	return w


func duplicate_governor() -> Governor:
	var g := Governor.new()
	g.food = food
	g.growth = growth
	g.industry = industry
	g.expansion = expansion
	g.may_build = may_build
	g.may_research = may_research
	g.may_promote = may_promote
	g.may_expand = may_expand
	g.may_route = may_route
	g.order = order
	g.name = name
	return g


func to_dict() -> Dictionary:
	return {
		"food": food, "growth": growth, "industry": industry,
		"expansion": expansion, "order": int(order), "name": name,
		"may_build": may_build, "may_research": may_research,
		"may_promote": may_promote, "may_expand": may_expand,
		"may_route": may_route,
	}


static func from_dict(d: Dictionary) -> Governor:
	var g := Governor.new()
	g.food = float(d["food"])
	g.growth = float(d["growth"])
	g.industry = float(d["industry"])
	g.expansion = float(d["expansion"])
	# Con default tolerante y no `d[...]`: un save anterior a los permisos carga con un
	# gobernador con permiso para todo, que es exactamente lo que era. Sin migración de esquema.
	g.may_build = bool(d.get("may_build", true))
	g.may_research = bool(d.get("may_research", true))
	g.may_promote = bool(d.get("may_promote", true))
	g.may_expand = bool(d.get("may_expand", true))
	g.may_route = bool(d.get("may_route", true))
	g.order = int(d.get("order", 0)) as Order
	g.name = String(d.get("name", "Gobernador"))
	return g
