class_name OfflineReport
extends RefCounted

## Lo que pasó mientras no estabas.
##
## Se saca comparando una foto del estado antes y después del catch-up. No forma parte de la
## simulación: es una lectura, y por eso vive fuera del `WorldState`.
##
## Incluye a propósito **lo que se perdió por no delegar**. Un nodo sin gobernador produce y
## crece, pero se para en su techo y ahí se queda: si estuviste ocho horas fuera y tu
## asentamiento pasó siete de ellas lleno, eso hay que enseñarlo, no esconderlo. Es el
## argumento honesto para delegar.

var seconds_credited: float = 0.0
var cycles: float = 0.0
var capped: bool = false
var pop_before: float = 0.0
var pop_after: float = 0.0
var gained := Goods.zeros()
var buildings_built: int = 0
var upgrades_bought: int = 0
## Colonias que nacieron durante la ausencia: expediciones que **llegaron**, salieran antes o
## durante. Un nodo nuevo solo nace de `Promotion.arrive`, así que basta con los ids que no
## estaban en la foto de antes (los ids no se reutilizan).
var colonies_arrived: PackedStringArray = PackedStringArray()
## Nodos que pasaron la ausencia parados en su techo pudiendo haber crecido delegados.
var idle_nodes: PackedStringArray = PackedStringArray()
## Rendimiento de un nodo delegado, para poder citarlo sin repetir el número a mano. Lo pone
## `build` con el que aplica la simulación (`SimEngine.governor_efficiency`), legado incluido.
var governor_efficiency: float = 0.85


## Foto del estado, para poder comparar después.
static func snapshot(state: WorldState) -> Dictionary:
	var totals := Goods.zeros()
	var buildings := 0
	var upgrades := 0
	var ids := {}
	for id in state.ordered_ids():
		var node: SimNode = state.nodes[id]
		ids[id] = true
		for i in Goods.COUNT:
			totals[i] += node.stocks[i]
		buildings += node.building_total()
		upgrades += node.upgrades.size()
	return {
		"pop": state.root().total_pop if state.root() != null else 0.0,
		"stocks": totals,
		"buildings": buildings,
		"upgrades": upgrades,
		"ids": ids,
	}


static func build(
	before: Dictionary, state: WorldState, params: SimParams,
	seconds: float, cycles_credited: float, was_capped: bool, efficiency: float
) -> OfflineReport:
	var report := OfflineReport.new()
	report.seconds_credited = seconds
	report.cycles = cycles_credited
	report.capped = was_capped
	# Se recibe hecho, no se calcula aquí: el informe no sabe del legado, y una segunda cuenta
	# del peaje es justo lo que hacía que la UI enseñase un número distinto del aplicado.
	report.governor_efficiency = efficiency
	report.pop_before = float(before["pop"])
	report.pop_after = state.root().total_pop if state.root() != null else 0.0

	var after := snapshot(state)
	var before_stocks: PackedFloat64Array = before["stocks"]
	var after_stocks: PackedFloat64Array = after["stocks"]
	for i in Goods.COUNT:
		report.gained[i] = after_stocks[i] - before_stocks[i]
	report.buildings_built = int(after["buildings"]) - int(before["buildings"])
	report.upgrades_bought = int(after["upgrades"]) - int(before["upgrades"])
	var before_ids: Dictionary = before.get("ids", {})
	for id in state.ordered_ids():
		if not before_ids.has(id):
			report.colonies_arrived.append((state.nodes[id] as SimNode).name)

	# Los que se quedaron parados en su techo sin nadie que decidiera por ellos.
	for id in state.ordered_ids():
		var node: SimNode = state.nodes[id]
		if node.is_delegated():
			continue
		var snap := Integrator.snapshot(node, params)
		if node.pop >= snap.cap - 0.5:
			report.idle_nodes.append(node.name)
	return report


func has_anything_to_say() -> bool:
	return cycles > 1.0


## Texto para la pantalla de vuelta.
func lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("Han pasado %s%s." % [
		span(seconds_credited),
		"  (tope de ausencia alcanzado)" if capped else "",
	])
	if pop_after > pop_before + 0.05:
		out.append("👥 La población ha crecido de %.0f a %.0f." % [pop_before, pop_after])
	elif pop_after < pop_before - 0.05:
		out.append("👥 La población ha bajado de %.0f a %.0f." % [pop_before, pop_after])

	for i in Goods.COUNT:
		if gained[i] > 0.5:
			out.append("%s  +%.0f de %s" % [Goods.ICONS[i], gained[i], Goods.NAMES[i]])
	if buildings_built > 0:
		out.append("🔨 Tus gobernadores han levantado %d edificios." % buildings_built)
	if upgrades_bought > 0:
		out.append("🔬 Y han investigado %d mejoras." % upgrades_bought)
	if colonies_arrived.size() == 1:
		out.append("🚩 Ha llegado una expedición: nace %s." % colonies_arrived[0])
	elif colonies_arrived.size() > 1:
		out.append("🚩 Han llegado %d expediciones: nacen %s." % [
			colonies_arrived.size(), ", ".join(colonies_arrived)])

	if not idle_nodes.is_empty():
		out.append("")
		out.append("⏸️ %s ha estado parado en su techo mientras no mirabas." % \
			", ".join(idle_nodes) if idle_nodes.size() == 1
			else "⏸️ %d asentamientos han estado parados en su techo." % idle_nodes.size())
		out.append("Un gobernador habría seguido construyendo, al %.0f %% de rendimiento."
			% (governor_efficiency * 100.0))
	return out


## Una duración en palabras. Público porque lo comparten el informe, el diario y la barra de
## vuelta: tres sitios que hablan de la misma ausencia y no pueden medirla cada uno a su modo.
static func span(seconds: float) -> String:
	var hours := int(seconds) / 3600
	var minutes := (int(seconds) % 3600) / 60
	if hours > 0:
		return "%d h %d min" % [hours, minutes]
	if minutes > 0:
		return "%d min" % minutes
	return "%d s" % int(seconds)
