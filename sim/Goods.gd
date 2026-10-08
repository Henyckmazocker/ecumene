class_name Goods
extends RefCounted

## Catálogo de recursos del juego.
##
## Los stocks viven en arrays planos indexados por estas constantes (no diccionarios):
## es lo que permite que el integrador trabaje con vectores y que el tick agregado
## siga siendo barato con miles de nodos.

const FOOD := 0
const WOOD := 1
const STONE := 2
const TOOLS := 3
const GOLD := 4
const CULTURE := 5
## El recurso de la región: lo producen los establos y lo gastan las rutas, que pagan en el origen
## una cantidad fija por unidad de caudal (`Logistics.TRANSPORT_PER_FLOW`). Va **al final** a
## propósito: los saves de seis recursos cargan con él a cero sin que se mueva ningún índice.
const TRANSPORT := 6
const COUNT := 7

const IDS := ["food", "wood", "stone", "tools", "gold", "culture", "transport"]
const NAMES := ["Comida", "Madera", "Piedra", "Herramientas", "Oro", "Cultura", "Transporte"]
const ICONS := ["🌾", "🪵", "🪨", "⚒️", "🪙", "📜", "🐎"]

## Recursos que no se almacenan con tope duro (la cultura es acumulativa).
const UNCAPPED := [CULTURE]


static func zeros() -> PackedFloat64Array:
	var a := PackedFloat64Array()
	a.resize(COUNT)
	return a


static func of(values: Dictionary) -> PackedFloat64Array:
	var a := zeros()
	for k in values:
		a[k] = float(values[k])
	return a


static func id_of(index: int) -> String:
	return IDS[index]
