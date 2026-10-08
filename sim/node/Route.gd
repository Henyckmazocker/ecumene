class_name Route
extends RefCounted

## Una ruta de reparto entre un nodo y su padre (o su hijo): mueve un recurso a caudal constante.
##
## Vive en `WorldState.routes` y no en ninguno de sus dos extremos: pertenece a los dos, y
## ponerla en uno creaba una asimetría que acaba en bug al guardar o al podar.
##
## `rate` es lo que pide quien la creó; `flow`, lo que circula de verdad en este tramo. Coinciden
## salvo cuando un extremo no puede seguir (el origen se vacía, el destino se llena): entonces la
## ruta se corta, `flow` cae a cero en los dos extremos a la vez y vuelve a `rate` en el siguiente
## checkpoint de `Logistics`. Las dos cosas son estado y se guardan; lo que se deriva de ellas,
## `SimNode.route_offset`, no.

var id: int = -1
var from_id: int = -1
var to_id: int = -1
var good: int = Goods.FOOD
## Caudal pedido, en unidades por ciclo.
var rate: float = 0.0
## Caudal que circula en este tramo: `rate`, o cero si la ruta se ha cortado hasta el checkpoint.
var flow: float = 0.0


func touches(node_id: int) -> bool:
	return from_id == node_id or to_id == node_id


func to_dict() -> Dictionary:
	return {
		"id": id, "from": from_id, "to": to_id, "good": good, "rate": rate, "flow": flow,
	}


static func from_dict(d: Dictionary) -> Route:
	var r := Route.new()
	r.id = int(d["id"])
	r.from_id = int(d["from"])
	r.to_id = int(d["to"])
	r.good = int(d["good"])
	r.rate = float(d["rate"])
	r.flow = float(d.get("flow", r.rate))
	return r
