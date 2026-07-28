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
## Nodos que pasaron la ausencia parados en su techo pudiendo haber crecido delegados.
var idle_nodes: PackedStringArray = PackedStringArray()


## Foto del estado, para poder comparar después.
static func snapshot(state: WorldState) -> Dictionary:
	var totals := Goods.zeros()
	var buildings := 0
	var upgrades := 0
	for id in state.ordered_ids():
		var node: SimNode = state.nodes[id]
		for i in Goods.COUNT:
			totals[i] += node.stocks[i]
		buildings += node.building_total()
		upgrades += node.upgrades.size()
	return {
		"pop": state.root().total_pop if state.root() != null else 0.0,
		"stocks": totals,
		"buildings": buildings,
		"upgrades": upgrades,
	}


static func build(
	before: Dictionary, state: WorldState, params: SimParams,
	seconds: float, cycles_credited: float, was_capped: bool
) -> OfflineReport:
	var report := OfflineReport.new()
	report.seconds_credited = seconds
	report.cycles = cycles_credited
	report.capped = was_capped
	report.pop_before = float(before["pop"])
	report.pop_after = state.root().total_pop if state.root() != null else 0.0

	var after := snapshot(state)
	var before_stocks: PackedFloat64Array = before["stocks"]
	var after_stocks: PackedFloat64Array = after["stocks"]
	for i in Goods.COUNT:
		report.gained[i] = after_stocks[i] - before_stocks[i]
	report.buildings_built = int(after["buildings"]) - int(before["buildings"])
	report.upgrades_bought = int(after["upgrades"]) - int(before["upgrades"])

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
		_span(seconds_credited),
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

	if not idle_nodes.is_empty():
		out.append("")
		out.append("⏸️ %s ha estado parado en su techo mientras no mirabas." % \
			", ".join(idle_nodes) if idle_nodes.size() == 1
			else "⏸️ %d asentamientos han estado parados en su techo." % idle_nodes.size())
		out.append("Un gobernador habría seguido construyendo, al 85 % de rendimiento.")
	return out


static func _span(seconds: float) -> String:
	var hours := int(seconds) / 3600
	var minutes := (int(seconds) % 3600) / 60
	if hours > 0:
		return "%d h %d min" % [hours, minutes]
	if minutes > 0:
		return "%d min" % minutes
	return "%d s" % int(seconds)
