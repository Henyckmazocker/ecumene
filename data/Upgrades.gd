class_name Upgrades
extends RefCounted

## Árbol de mejoras. Permanentes, **por nodo**, con requisitos entre ellas.
##
## Además de dar profundidad a la capa incremental, resuelven un agujero de diseño: al
## promocionar a Pueblo se desbloquean cantera y taller, pero **la piedra solo se gastaba en el
## propio taller y las herramientas en nada en absoluto** hasta llegar a Ciudad. Sin un
## sumidero, el tier nuevo producía números inertes. Las mejoras de pueblo son ese sumidero.
##
## Por eso **cada escala trae la rama que gasta lo suyo**: el oro y la cultura del mercado y el
## templo tuvieron el mismo problema hasta que existió la rama de Ciudad.
##
## ⚠️ **Todos los efectos son multiplicadores constantes.** Es el contrato del que depende la
## forma cerrada del integrador: «+1 puesto por granja» se modela como ×1,33 sobre los puestos,
## no como un `+1` aparte. Un efecto que dependiera del tiempo o del estado tendría que ser un
## **evento de segmento**, no un factor.

enum Kind {
	PRODUCTION,           ## toda la producción del nodo
	BUILDING_PRODUCTION,  ## la producción de un tipo de edificio
	SLOTS,                ## los puestos de trabajo de un tipo de edificio
	FOOD,                 ## solo la producción de comida
	GROWTH,               ## la tasa de crecimiento de población
	HOUSING,              ## el techo de alojamiento
	STORAGE,              ## la capacidad de los almacenes
	EXPEDITION,           ## la duración de las expediciones que salen del nodo (menor que 1 acorta)
}


class Effect:
	extends RefCounted
	var kind: int = Kind.PRODUCTION
	var building: String = ""
	var value: float = 1.0

	static func make(kind: int, value: float, building: String = "") -> Effect:
		var e := Effect.new()
		e.kind = kind
		e.value = value
		e.building = building
		return e

	func describe() -> String:
		var percent := (value - 1.0) * 100.0
		match kind:
			Kind.PRODUCTION: return "+%.0f %% de producción" % percent
			Kind.BUILDING_PRODUCTION:
				return "+%.0f %% en %s" % [percent, _building_name()]
			Kind.SLOTS: return "+%.0f %% de puestos en %s" % [percent, _building_name()]
			Kind.FOOD: return "+%.0f %% de comida" % percent
			Kind.GROWTH: return "+%.0f %% de crecimiento" % percent
			Kind.HOUSING: return "+%.0f %% de alojamiento" % percent
			Kind.STORAGE: return "+%.0f %% de almacenamiento" % percent
			Kind.EXPEDITION: return "%.0f %% de duración de las expediciones" % percent
		return ""

	func _building_name() -> String:
		var index := Content.building_index(building)
		return Content.building(index).name if index >= 0 else building


class Def:
	extends RefCounted
	var id: String
	var name: String
	var icon: String
	var tier_min: int = 0
	var requires: PackedStringArray = PackedStringArray()
	var cost: PackedFloat64Array = Goods.zeros()
	var effects: Array = []

	func describe() -> String:
		var parts := PackedStringArray()
		for e in effects:
			parts.append((e as Effect).describe())
		return " · ".join(parts)


## Multiplicadores que aporta el conjunto de mejoras de un nodo.
class Effects:
	extends RefCounted
	var production: float = 1.0
	var food: float = 1.0
	var growth: float = 1.0
	var housing: float = 1.0
	var storage: float = 1.0
	## Multiplicador de la duración de las expediciones. No entra en el integrador: lo lee
	## `Promotion.expedition_cycles` al salir, y la expedición en camino no cambia.
	var expedition: float = 1.0
	## Multiplicador de producción por índice de edificio.
	var per_building := PackedFloat64Array()
	## Multiplicador de puestos de trabajo por índice de edificio.
	var slots := PackedFloat64Array()

	func _init() -> void:
		var count := Content.building_count()
		per_building.resize(count)
		slots.resize(count)
		per_building.fill(1.0)
		slots.fill(1.0)


## Calcula los efectos de una lista de mejoras. Los multiplicadores se **componen**: dos
## mejoras del +30 % dan ×1,69, no ×1,60.
static func compute(ids: PackedStringArray) -> Effects:
	var out := Effects.new()
	for id in ids:
		var def: Def = get_def(id)
		if def == null:
			continue
		for effect in def.effects:
			var e: Effect = effect
			var building := Content.building_index(e.building)
			match e.kind:
				Kind.PRODUCTION: out.production *= e.value
				Kind.FOOD: out.food *= e.value
				Kind.GROWTH: out.growth *= e.value
				Kind.HOUSING: out.housing *= e.value
				Kind.STORAGE: out.storage *= e.value
				Kind.EXPEDITION: out.expedition *= e.value
				Kind.BUILDING_PRODUCTION:
					if building >= 0:
						out.per_building[building] *= e.value
				Kind.SLOTS:
					if building >= 0:
						out.slots[building] *= e.value
	return out


static var _defs: Array = []
static var _by_id: Dictionary = {}


static func all() -> Array:
	if _defs.is_empty():
		_build()
	return _defs


static func get_def(id: String) -> Def:
	if _by_id.is_empty():
		_build()
	return _by_id.get(id)


static func _make(
	id: String, name: String, icon: String, tier_min: int,
	requires: Array, cost: Dictionary, effects: Array
) -> Def:
	var d := Def.new()
	d.id = id
	d.name = name
	d.icon = icon
	d.tier_min = tier_min
	d.requires = PackedStringArray(requires)
	d.cost = Goods.of(cost)
	d.effects = effects
	return d


static func _build() -> void:
	_defs = [
		# --- Asentamiento: se pagan con lo que ya tienes ---
		_make("sharp_axes", "Hachas afiladas", "🪓", Content.SETTLEMENT,
			[], {Goods.WOOD: 120.0},
			[Effect.make(Kind.BUILDING_PRODUCTION, 1.30, "woodcutter")]),
		_make("crop_rotation", "Rotación de cultivos", "🌱", Content.SETTLEMENT,
			[], {Goods.FOOD: 150.0},
			[Effect.make(Kind.BUILDING_PRODUCTION, 1.30, "farm")]),
		_make("granary", "Granero", "🏺", Content.SETTLEMENT,
			["crop_rotation"], {Goods.WOOD: 220.0},
			[Effect.make(Kind.STORAGE, 1.50)]),
		_make("sturdy_frames", "Armazones firmes", "🪵", Content.SETTLEMENT,
			["sharp_axes"], {Goods.WOOD: 260.0},
			[Effect.make(Kind.HOUSING, 1.25)]),
		_make("shared_hearth", "Hogar común", "🔥", Content.SETTLEMENT,
			["granary"], {Goods.FOOD: 200.0},
			[Effect.make(Kind.GROWTH, 1.30)]),
		_make("wide_paths", "Sendas anchas", "🛤️", Content.SETTLEMENT,
			["sturdy_frames"], {Goods.WOOD: 320.0},
			[Effect.make(Kind.SLOTS, 1.34, "farm")]),
		_make("woodpiles", "Leñeras", "🪓", Content.SETTLEMENT,
			["granary"], {Goods.WOOD: 450.0},
			[Effect.make(Kind.STORAGE, 1.40)]),
		_make("thatch_roofs", "Techos de paja", "🏚️", Content.SETTLEMENT,
			["wide_paths"], {Goods.WOOD: 500.0},
			[Effect.make(Kind.HOUSING, 1.20)]),
		_make("deep_wells", "Pozos", "💧", Content.SETTLEMENT,
			["shared_hearth"], {Goods.FOOD: 400.0},
			[Effect.make(Kind.GROWTH, 1.25)]),

		# --- Pueblo: **el sumidero** de piedra y herramientas ---
		_make("stone_tools", "Herramientas de piedra", "🪨", Content.TOWN,
			[], {Goods.STONE: 90.0},
			[Effect.make(Kind.PRODUCTION, 1.25)]),
		_make("quarry_rails", "Vagonetas", "🛒", Content.TOWN,
			["stone_tools"], {Goods.STONE: 150.0},
			[Effect.make(Kind.BUILDING_PRODUCTION, 1.50, "quarry")]),
		_make("iron_plows", "Arados de hierro", "⚒️", Content.TOWN,
			["stone_tools"], {Goods.TOOLS: 70.0},
			[Effect.make(Kind.BUILDING_PRODUCTION, 1.50, "farm")]),
		_make("saw_pit", "Aserradero", "🪚", Content.TOWN,
			["stone_tools"], {Goods.TOOLS: 70.0},
			[Effect.make(Kind.BUILDING_PRODUCTION, 1.50, "woodcutter")]),
		_make("stone_houses", "Casas de piedra", "🧱", Content.TOWN,
			["iron_plows"], {Goods.STONE: 240.0},
			[Effect.make(Kind.HOUSING, 1.40)]),
		_make("apprentices", "Aprendices", "🧑‍🏭", Content.TOWN,
			["quarry_rails"], {Goods.TOOLS: 120.0},
			[Effect.make(Kind.SLOTS, 1.50, "workshop"),
			 Effect.make(Kind.SLOTS, 1.34, "quarry")]),
		_make("deep_cellars", "Bodegas profundas", "🕳️", Content.TOWN,
			["stone_houses"], {Goods.STONE: 300.0},
			[Effect.make(Kind.STORAGE, 2.00)]),
		_make("guild_hall", "Casa de oficios", "🏛️", Content.TOWN,
			["apprentices", "deep_cellars"], {Goods.TOOLS: 180.0},
			[Effect.make(Kind.PRODUCTION, 1.30)]),
		_make("crop_terraces", "Bancales", "🌾", Content.TOWN,
			["iron_plows"], {Goods.TOOLS: 300.0},
			[Effect.make(Kind.FOOD, 1.35)]),
		_make("masonry", "Cantería", "🧱", Content.TOWN,
			["stone_houses"], {Goods.STONE: 500.0},
			[Effect.make(Kind.HOUSING, 1.30)]),
		_make("granite_vaults", "Bóvedas de granito", "🏦", Content.TOWN,
			["deep_cellars"], {Goods.TOOLS: 400.0},
			[Effect.make(Kind.STORAGE, 1.75)]),
		_make("road_network", "Calzadas", "🛣️", Content.TOWN,
			["guild_hall"], {Goods.STONE: 800.0},
			[Effect.make(Kind.SLOTS, 1.34, "quarry"),
			 Effect.make(Kind.SLOTS, 1.25, "farm")]),
		# El reloj de las expediciones, en el nodo que la compra. Tiene que estar al alcance antes
		# de que salga el segundo hijo: el primero sale con el Pueblo (~750) y llega hacia el
		# 3.150, que es cuando sale el segundo. Cuelga de las vagonetas —la piedra que se saca se
		# echa al camino— y no de las calzadas, que caen al fondo de la rama (~1.700 con un
		# gobernador, y más tarde a mano). Cuesta 600 🪨 y 120 ⚒️: un gobernador junta eso hacia
		# el 1.800-1.900, y a mano queda con más de mil ciclos de margen antes del segundo.
		_make("roads", "Carreteras", "🛤️", Content.TOWN,
			["quarry_rails"], {Goods.STONE: 600.0, Goods.TOOLS: 120.0},
			[Effect.make(Kind.EXPEDITION, 0.75)]),

		# --- Ciudad: **el sumidero** de oro y cultura ---
		#
		# El mismo agujero que las mejoras de Pueblo cerraron para la piedra: sin esta rama, el
		# mercado y el templo producen números que no se gastan en nada.
		_make("coinage", "Acuñación", "🪙", Content.CITY,
			[], {Goods.GOLD: 300.0},
			[Effect.make(Kind.PRODUCTION, 1.30)]),
		_make("guilds_charter", "Fuero de gremios", "📜", Content.CITY,
			["coinage"], {Goods.GOLD: 600.0},
			[Effect.make(Kind.SLOTS, 1.30, "market"),
			 Effect.make(Kind.SLOTS, 1.30, "workshop")]),
		_make("aqueduct", "Acueducto", "🌊", Content.CITY,
			["coinage"], {Goods.GOLD: 500.0, Goods.STONE: 800.0},
			[Effect.make(Kind.HOUSING, 1.75)]),
		_make("stone_mills", "Molinos", "⚙️", Content.CITY,
			["guilds_charter"], {Goods.TOOLS: 600.0},
			[Effect.make(Kind.BUILDING_PRODUCTION, 1.60, "farm")]),
		_make("public_granaries", "Pósitos", "🏛️", Content.CITY,
			["aqueduct"], {Goods.GOLD: 900.0},
			[Effect.make(Kind.STORAGE, 2.00)]),
		_make("schools", "Escuelas", "📚", Content.CITY,
			["guilds_charter"], {Goods.CULTURE: 200.0},
			[Effect.make(Kind.GROWTH, 1.40)]),
		_make("great_library", "Gran biblioteca", "📖", Content.CITY,
			["schools", "public_granaries"], {Goods.GOLD: 1200.0, Goods.CULTURE: 500.0},
			[Effect.make(Kind.PRODUCTION, 1.40)]),

		# --- Región: **el sumidero** del transporte, y lo que lo multiplica ---
		#
		# Todas con efectos que ya existen (constantes por tramo): más 🐎 por establo, más mozos
		# por establo y más almacén para lo que viaja. Abaratar el 🐎 por unidad de caudal pediría
		# un efecto nuevo que leyera `Logistics`, y no hace falta para que la rama tenga sentido.
		_make("horseshoes", "Herraduras", "🐴", Content.REGION,
			[], {Goods.TOOLS: 800.0},
			[Effect.make(Kind.BUILDING_PRODUCTION, 1.40, "stables")]),
		_make("coaching_inns", "Casas de postas", "🏨", Content.REGION,
			["horseshoes"], {Goods.STONE: 3000.0, Goods.TRANSPORT: 150.0},
			[Effect.make(Kind.SLOTS, 1.50, "stables")]),
		_make("staging_depots", "Almacenes de etapa", "📦", Content.REGION,
			["horseshoes"], {Goods.STONE: 4000.0, Goods.TRANSPORT: 300.0},
			[Effect.make(Kind.STORAGE, 1.60)]),
		_make("royal_roads", "Caminos reales", "🗺️", Content.REGION,
			["coaching_inns", "staging_depots"], {Goods.TOOLS: 1500.0, Goods.TRANSPORT: 800.0},
			[Effect.make(Kind.PRODUCTION, 1.30)]),
	]
	_by_id = {}
	for d in _defs:
		_by_id[d.id] = d
