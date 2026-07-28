class_name Upgrades
extends RefCounted

## Árbol de mejoras. Permanentes, **por nodo**, con requisitos entre ellas.
##
## Además de dar profundidad a la capa incremental, resuelven un agujero de diseño: al
## promocionar a Pueblo se desbloquean cantera y taller, pero **la piedra solo se gastaba en el
## propio taller y las herramientas en nada en absoluto** hasta llegar a Ciudad. Sin un
## sumidero, el tier nuevo producía números inertes. Las mejoras de pueblo son ese sumidero.
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
	]
	_by_id = {}
	for d in _defs:
		_by_id[d.id] = d
