class_name Expedition
extends RefCounted

## Colonos en camino de un nodo a la colonia que van a fundar.
##
## Fundar no es instantáneo: los colonos y la comida salen del padre al lanzarla
## (`Promotion.launch_expedition`) y el hijo nace al llegar (`Promotion.arrive`), que lo llama
## `SimEngine.tick` partiendo el tramo justo en `arrive_cycle`. Así la colonia crece lo mismo
## tickeando de 1 en 1 que de un salto (regla 4).
##
## Vive en `WorldState.expeditions` y no en el padre, igual que `Route`: está entre dos nodos, y
## uno de ellos todavía no existe. Una por nodo como mucho (`WorldState.expedition_of`).
##
## La duración se fija **al salir** y no cambia sola en camino: es una constante del tramo, no una
## tasa que integrar. Lo único que la mueve es ⏩ acelerar con oro (`Promotion.accelerate_expedition`),
## que es una acción discreta entre ticks, como construir.

var parent_id: int = -1
var depart_cycle: float = 0.0
var arrive_cycle: float = 0.0
## Escala con la que nacerá el hijo: la del padre menos uno **al salir**. Si el padre promociona
## en camino, la colonia sigue siendo la que se mandó a fundar.
var tier: int = 0
## Colonos en camino: ya han salido del padre y no cuentan en ningún total.
var pop: float = 0.0
## Provisiones con las que nacerá el hijo.
var food: float = 0.0
## La política con la que nacerá delegado, o null si nace sin gobernador. Se copia **al salir**:
## si el padre deja de estar delegado mientras tanto, la colonia no se queda huérfana.
var delegate_policy: Governor = null
## Quién la mandó (`player` o `governor`). El evento `found` sale al llegar con este actor, como
## salía antes al fundar: el tablero de Augur cuenta las fundaciones del gobernador por él. No es
## estado de la simulación y no entra en el `state_hash`.
var actor: String = "player"
## Cuántas veces se ha acelerado con oro: encarece la siguiente (`Promotion.accelerate_cost`). Es
## estado —decide cuánto cuesta lo próximo—, así que entra en el save y en el `state_hash`.
var accelerations: int = 0


func to_dict() -> Dictionary:
	var d := {
		"parent": parent_id, "depart": depart_cycle, "arrive": arrive_cycle, "tier": tier,
		"pop": pop, "food": food, "actor": actor, "accelerations": accelerations,
	}
	if delegate_policy != null:
		d["policy"] = delegate_policy.to_dict()
	return d


static func from_dict(d: Dictionary) -> Expedition:
	var e := Expedition.new()
	e.parent_id = int(d["parent"])
	e.depart_cycle = float(d["depart"])
	e.arrive_cycle = float(d["arrive"])
	e.tier = int(d["tier"])
	e.pop = float(d["pop"])
	e.food = float(d["food"])
	e.actor = String(d.get("actor", "player"))
	# Un save v4 de antes de ⏩ acelerar no trae la clave: esa expedición nunca se aceleró, así que
	# 0 es exactamente lo que era. Por eso no hace falta subir `SCHEMA_VERSION`.
	e.accelerations = int(d.get("accelerations", 0))
	if d.has("policy"):
		e.delegate_policy = Governor.from_dict(d["policy"])
	return e
