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


## Recursos que un nodo de este tier maneja (los suyos más los de todas las escalas por
## debajo). La UI los usa para no enseñar recursos que el jugador aún no ha desbloqueado.
static func goods_for_tier(tier_index: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in range(0, mini(tier_index + 1, TIER_COUNT)):
		for good in tier(i).goods:
			if not out.has(good):
				out.append(good)
	return out


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
	promote_pop: float, promote_buildings: int, child_slots: int, unlocks: String,
	promote_children := 0, cost_scale := 1.0, expedition_scale := 1.0,
	promote_influence := 0.0
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
	t.promote_children = promote_children
	t.child_slots = child_slots
	t.unlocks = unlocks
	t.cost_scale = cost_scale
	t.expedition_scale = expedition_scale
	t.promote_influence = promote_influence
	return t


static func _build_tiers() -> void:
	_tiers = [
		_make_tier(SETTLEMENT, "settlement", "Asentamiento", "Asentamientos",
			[Goods.FOOD, Goods.WOOD], ["hut", "farm", "woodcutter", "storehouse"],
			60.0, 10, 1, "Supervivencia: comida, madera y alojamiento."),
		_make_tier(TOWN, "town", "Pueblo", "Pueblos",
			[Goods.STONE, Goods.TOOLS], ["quarry", "workshop"],
			1000.0, 24, 4, "Especialización: la mano de obra se reparte en oficios.",
			# Ciudad pide las cuatro plazas ocupadas: sin hijos, la raíz llegaba sola a los
			# 1.000 hab y 24 edificios (~6.300 ciclos) y el reloj de las expediciones no marcaba
			# nada. Con los 4 hijos, Ciudad cae cuando llega el cuarto. Cualquier asentamiento
			# cuenta (`Promotion.grown_children`); la expedición en camino, no.
			4),
		_make_tier(CITY, "city", "Ciudad", "Ciudades",
			[Goods.GOLD, Goods.CULTURE], ["market", "temple"],
			10000.0, 40, 6, "Comercio y cultura: la cultura se vuelve 🎭 influencia, y la influencia abre la región.",
			# Una región sin ciudades no es una región: además de los 10.000 hab y los 40
			# edificios, las seis plazas ocupadas por pueblos. Los 4 asentamientos de la raíz
			# suben a Pueblo en cuanto es Ciudad; con 3 bastaba eso y Región saltaba ~2.800 ciclos
			# después de Ciudad. Los dos que faltan los funda la ciudad, y es su reloj el que marca.
			6, 1.0,
			# Reloj ×7: las expediciones de una ciudad tardan siete veces lo que las de un pueblo
			# con los mismos hijos (5.º: 12.150 × 7, 6.º: 18.225 × 7, los dos × 0,75 de 🛤️
			# Carreteras, que la ciudad ya tiene: ~63.800 y ~95.700 ciclos). Es lo que estira Región
			# hacia los ~2 días (172.800). Con ×4 caía en 107.100, por debajo de los 120.000 del
			# objetivo; con ×7, `era_probe` la da en 175.475 (M5 de «Plan - Balance de la era»).
			# Es la única palanca que no mueve H1-Ciudad: la base y el crecimiento también fijan
			# los tests de expediciones de un pueblo, y Ciudad (15.975) ya está en su rango.
			7.0,
			# 🎭 Influencia: √ de la cultura del subárbol (`WorldState.influence_of`). 2.250 es el
			# 70 % de lo que junta el gobernador equilibrado al llegar el 6.º pueblo (√10.336.018 =
			# 3.215, M0 de «Plan - Sumidero de oro y cultura»): pide templos, pero a los 100.000
			# ciclos ya va por 2.239, así que la cruza a mitad del tramo y el reloj sigue marcando.
			2250.0),
		# Región: el 🐎 transporte de los establos y las rutas que lo gastan. Sin oro ni cultura
		# nuevos, que son del plan del sumidero. Los 60 edificios siguen la escalera 10 → 24 → 40;
		# hoy no abren nada, porque país aún no tiene contenido (`TierDef.is_playable`).
		_make_tier(REGION, "region", "Región", "Regiones",
			[Goods.TRANSPORT], ["stables"],
			120000.0, 60, 8, "Logística: rutas y reparto de excedentes entre ciudades."),
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
	housing: float, storage: Dictionary,
	color: Color, footprint: Vector2, icon: String
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
	b.color = color
	b.footprint = footprint
	b.icon = icon
	return b


static func _build_buildings() -> void:
	_buildings = [
		_make_building("hut", "Cabaña", SETTLEMENT,
			{Goods.WOOD: 16.0}, 1.15,
			0.0, {}, {},
			5.0, {},
			Color(0.75, 0.62, 0.45), Vector2(0.7, 0.7), "🛖"),
		_make_building("farm", "Granja", SETTLEMENT,
			{Goods.WOOD: 24.0}, 1.14,
			3.0, {Goods.FOOD: 0.6}, {},
			0.0, {},
			Color(0.88, 0.76, 0.34), Vector2(1.5, 1.1), "🌾"),
		_make_building("woodcutter", "Leñador", SETTLEMENT,
			{Goods.WOOD: 12.0}, 1.14,
			2.0, {Goods.WOOD: 0.55}, {},
			0.0, {},
			Color(0.55, 0.38, 0.24), Vector2(0.8, 0.8), "🪓"),
		# `cost_growth` bajo a propósito: es el único edificio que sube el tope, y con 1,25 —el
		# más alto que hubo del catálogo— **se bloqueaba a sí mismo** en el ejemplar nº 32,
		# congelando el tope de un pueblo en 51.200 y con él la economía entera.
		_make_building("storehouse", "Almacén", SETTLEMENT,
			{Goods.WOOD: 60.0}, 1.20,
			0.0, {}, {},
			0.0, {Goods.FOOD: 200.0, Goods.WOOD: 200.0, Goods.STONE: 200.0,
				Goods.TOOLS: 100.0, Goods.GOLD: 100.0},
			Color(0.62, 0.55, 0.44), Vector2(1.2, 1.0), "🏚️"),
		_make_building("quarry", "Cantera", TOWN,
			{Goods.WOOD: 80.0}, 1.18,
			3.0, {Goods.STONE: 0.3}, {},
			0.0, {},
			Color(0.70, 0.70, 0.72), Vector2(1.4, 1.2), "⛏️"),
		_make_building("workshop", "Taller", TOWN,
			{Goods.WOOD: 40.0, Goods.STONE: 60.0}, 1.20,
			2.0, {Goods.TOOLS: 0.15}, {Goods.WOOD: 0.2},
			0.0, {},
			Color(0.58, 0.64, 0.72), Vector2(1.0, 0.9), "🔨"),
		# La casa comunal y el depósito son **de piedra a propósito**. Con la cabaña y el almacén
		# como únicas fuentes de techo, el límite de un pueblo era el tope de madera y nada más:
		# la cabaña nº 59 costaba más de lo que cabía en el almacén, y ahí se acababa la partida
		# a las ~500 almas. Aquí el techo se compra con lo que produce la cantera, que hasta
		# ahora solo se gastaba en el propio taller.
		_make_building("commons", "Casa comunal", TOWN,
			{Goods.STONE: 120.0, Goods.WOOD: 60.0}, 1.17,
			0.0, {}, {},
			20.0, {},
			Color(0.66, 0.58, 0.52), Vector2(1.3, 1.1), "🏘️"),
		_make_building("depot", "Depósito", TOWN,
			{Goods.STONE: 150.0}, 1.22,
			0.0, {}, {},
			0.0, {Goods.FOOD: 500.0, Goods.WOOD: 500.0, Goods.STONE: 500.0,
				Goods.TOOLS: 250.0, Goods.GOLD: 250.0},
			Color(0.52, 0.50, 0.46), Vector2(1.4, 1.2), "🏦"),
		_make_building("market", "Mercado", CITY,
			{Goods.STONE: 120.0, Goods.TOOLS: 20.0}, 1.20,
			4.0, {Goods.GOLD: 0.5}, {},
			0.0, {},
			Color(0.86, 0.60, 0.30), Vector2(1.6, 1.2), "🏪"),
		_make_building("temple", "Templo", CITY,
			{Goods.STONE: 150.0, Goods.TOOLS: 40.0}, 1.22,
			2.0, {Goods.CULTURE: 0.3}, {Goods.GOLD: 0.1},
			0.0, {},
			Color(0.72, 0.56, 0.82), Vector2(1.1, 1.4), "⛩️"),
		# Lo único que construye la región, y lo que la hace jugable. Un establo lleno (4 mozos)
		# da 1 🐎 por ciclo, que mueve 2 unidades de caudal (`Logistics.TRANSPORT_PER_FLOW`).
		# Se paga con lo que ya produce una ciudad —piedra, herramientas y madera—, sin oro.
		_make_building("stables", "Establos", REGION,
			{Goods.STONE: 600.0, Goods.TOOLS: 120.0, Goods.WOOD: 300.0}, 1.20,
			4.0, {Goods.TRANSPORT: 0.25}, {},
			0.0, {},
			Color(0.60, 0.44, 0.30), Vector2(1.5, 1.2), "🐎"),
	]
	_building_index = {}
	for i in _buildings.size():
		_building_index[_buildings[i].id] = i
