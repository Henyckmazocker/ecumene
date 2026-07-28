class_name Content
extends RefCounted

## Catálogo estático del juego: las siete escalas y los edificios.
##
## Se construye en código y se cachea. Al ser `Resource`, `TierDef` y `BuildingDef` pueden
## migrar a `.tres` editables desde el editor sin cambiar a los consumidores: solo cambiaría
## el cuerpo de `_build_*`.

const SETTLEMENT := 0
const TOWN := 1
const CITY := 2
const REGION := 3
const COUNTRY := 4
const EMPIRE := 5
const PLANET := 6
const TIER_COUNT := 7

static var _tiers: Array[TierDef] = []
static var _buildings: Array[BuildingDef] = []
static var _building_index: Dictionary = {}


static func tiers() -> Array[TierDef]:
	if _tiers.is_empty():
		_build_tiers()
	return _tiers


static func tier(index: int) -> TierDef:
	return tiers()[index]


static func buildings() -> Array[BuildingDef]:
	if _buildings.is_empty():
		_build_buildings()
	return _buildings


static func building(index: int) -> BuildingDef:
	return buildings()[index]


static func building_count() -> int:
	return buildings().size()


## Índice global estable de un edificio por su id. -1 si no existe.
static func building_index(id: String) -> int:
	if _building_index.is_empty():
		_build_buildings()
	return _building_index.get(id, -1)


## Índices de los edificios disponibles en un tier (incluye los de tiers inferiores).
static func buildings_for_tier(tier_index: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in building_count():
		if building(i).tier_min <= tier_index:
			out.append(i)
	return out


# ---------------------------------------------------------------------------
# Escalas
# ---------------------------------------------------------------------------

static func _make_tier(
	index: int, id: String, name: String, plural: String,
	goods: Array, buildings_ids: Array,
	promote_pop: float, promote_buildings: int, child_slots: int, unlocks: String
) -> TierDef:
	var t := TierDef.new()
	t.index = index
	t.id = id
	t.name = name
	t.name_plural = plural
	t.goods = PackedInt32Array(goods)
	t.buildings = PackedStringArray(buildings_ids)
	t.promote_pop = promote_pop
	t.promote_buildings = promote_buildings
	t.child_slots = child_slots
	t.unlocks = unlocks
	return t


static func _build_tiers() -> void:
	_tiers = [
		_make_tier(SETTLEMENT, "settlement", "Asentamiento", "Asentamientos",
			[Goods.FOOD, Goods.WOOD], ["hut", "farm", "woodcutter", "storehouse"],
			100.0, 12, 1, "Supervivencia: comida, madera y alojamiento."),
		_make_tier(TOWN, "town", "Pueblo", "Pueblos",
			[Goods.STONE, Goods.TOOLS], ["quarry", "workshop"],
			1000.0, 24, 4, "Especialización: la mano de obra se reparte en oficios."),
		_make_tier(CITY, "city", "Ciudad", "Ciudades",
			[Goods.GOLD, Goods.CULTURE], ["market", "temple"],
			10000.0, 40, 6, "Comercio y cultura: el excedente se convierte en influencia."),
		_make_tier(REGION, "region", "Región", "Regiones",
			[], [],
			120000.0, 0, 8, "Logística: rutas y reparto de excedentes entre ciudades."),
		_make_tier(COUNTRY, "country", "País", "Países",
			[], [],
			1.5e6, 0, 10, "Política: leyes que modifican el tick de todos los hijos."),
		_make_tier(EMPIRE, "empire", "Imperio", "Imperios",
			[], [],
			2.0e7, 0, 12, "Diplomacia: imperios vecinos con los que tratar o competir."),
		_make_tier(PLANET, "planet", "Planeta", "Planetas",
			[], [],
			0.0, 0, 0, "Ecología global: el planeta responde a lo que le has hecho."),
	]


# ---------------------------------------------------------------------------
# Edificios
# ---------------------------------------------------------------------------

static func _make_building(
	id: String, name: String, tier_min: int,
	cost: Dictionary, cost_growth: float,
	slots: float, produces: Dictionary, consumes: Dictionary,
	housing: float, storage: Dictionary
) -> BuildingDef:
	var b := BuildingDef.new()
	b.id = id
	b.name = name
	b.tier_min = tier_min
	b.cost = Goods.of(cost)
	b.cost_growth = cost_growth
	b.worker_slots = slots
	b.produces = Goods.of(produces)
	b.consumes = Goods.of(consumes)
	b.housing = housing
	b.storage = Goods.of(storage)
	return b


static func _build_buildings() -> void:
	_buildings = [
		_make_building("hut", "Cabaña", SETTLEMENT,
			{Goods.WOOD: 20.0}, 1.18,
			0.0, {}, {},
			5.0, {}),
		_make_building("farm", "Granja", SETTLEMENT,
			{Goods.WOOD: 30.0}, 1.16,
			3.0, {Goods.FOOD: 0.6}, {},
			0.0, {}),
		_make_building("woodcutter", "Leñador", SETTLEMENT,
			{Goods.WOOD: 15.0}, 1.16,
			2.0, {Goods.WOOD: 0.4}, {},
			0.0, {}),
		_make_building("storehouse", "Almacén", SETTLEMENT,
			{Goods.WOOD: 60.0}, 1.25,
			0.0, {}, {},
			0.0, {Goods.FOOD: 200.0, Goods.WOOD: 200.0, Goods.STONE: 200.0,
				Goods.TOOLS: 100.0, Goods.GOLD: 100.0}),
		_make_building("quarry", "Cantera", TOWN,
			{Goods.WOOD: 80.0}, 1.18,
			3.0, {Goods.STONE: 0.3}, {},
			0.0, {}),
		_make_building("workshop", "Taller", TOWN,
			{Goods.WOOD: 40.0, Goods.STONE: 60.0}, 1.20,
			2.0, {Goods.TOOLS: 0.15}, {Goods.WOOD: 0.2},
			0.0, {}),
		_make_building("market", "Mercado", CITY,
			{Goods.STONE: 120.0, Goods.TOOLS: 20.0}, 1.20,
			4.0, {Goods.GOLD: 0.5}, {},
			0.0, {}),
		_make_building("temple", "Templo", CITY,
			{Goods.STONE: 150.0, Goods.TOOLS: 40.0}, 1.22,
			2.0, {Goods.CULTURE: 0.3}, {Goods.GOLD: 0.1},
			0.0, {}),
	]
	_building_index = {}
	for i in _buildings.size():
		_building_index[_buildings[i].id] = i
