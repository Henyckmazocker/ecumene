class_name CrowdReconciler
extends RefCounted

## El puente entre las dos simulaciones: acerca la multitud a lo que dice el agregado, **sin
## copiarlo de golpe**.
##
## El contrato es preciso: la dramatización puede ir **con retraso**, no puede **mentir**. Si
## el modelo dice que hay 30 granjeros, en pantalla acabará habiendo 30 granjeros — pero
## llegando poco a poco, cada uno cambiando de rumbo cuando termina lo que estaba haciendo.
##
## Se llama **cada fotograma con `delta` real**, no en el tick de la simulación. Si dependiera
## del tick, a ×8 convergería ocho veces más rápido y habríamos vuelto a atar el visual a la
## velocidad de juego, que es justo lo que este rediseño viene a quitar.

## Diferencia a partir de la cual no tiene sentido ir poco a poco y se rellena de golpe:
## cargar una partida de 300 habitantes o volver de ocho horas fuera no puede tardar dos
## minutos en poblarse.
const BULK_THRESHOLD := 12

## Suelo de ritmo, en fracción de la multitud por segundo: un pueblo grande converge en un
## tiempo parecido a uno pequeño en vez de tardar proporcionalmente más.
const RATE_FRACTION := 0.05

var _arrival_budget: float = 0.0
var _job_budget: float = 0.0
var _layout_signature: PackedInt32Array = PackedInt32Array()
var _first_sync: bool = true


## Acerca `crowd` al estado de `node`. Devuelve `true` si tuvo que rellenar de golpe.
func sync(
	crowd: Crowd, node: SimNode, layout: Layout.Result, params: CrowdParams, delta: float
) -> bool:
	if node == null or layout == null:
		return false

	# Los edificios nuevos aparecen **de inmediato** — eso sí tiene que ser instantáneo.
	if crowd.places == null or _layout_signature != layout.signature:
		_layout_signature = layout.signature.duplicate()
		crowd.places = Places.from_layout(layout)
		_rehome_from_plaza(crowd)

	var bulk := _sync_population(crowd, node, params, delta)
	_sync_jobs(crowd, node, params, delta, bulk)
	_first_sync = false
	return bulk


# ---------------------------------------------------------------------------
# Población
# ---------------------------------------------------------------------------

func _sync_population(
	crowd: Crowd, node: SimNode, params: CrowdParams, delta: float
) -> bool:
	# Cuántos puntos toca dibujar lo decide `CrowdParams`: es tuning visual, y de él sale el
	# `represents` con el que se reparten los oficios más abajo.
	var visible := params.dots_for(node.pop)
	crowd.represents = node.pop / float(visible) if visible > 0 else 1.0

	var current := crowd.active_count()
	var difference := visible - current
	if difference == 0:
		return false

	# Salto grande (primera vez, partida cargada, vuelta de estar fuera): rellenar ya. Ver a
	# la gente gotear durante un minuto al abrir el juego sería peor que el problema original.
	var bulk := _first_sync or absi(difference) > BULK_THRESHOLD
	if bulk:
		for _i in maxi(difference, 0):
			crowd.spawn(params, false)
		# Y vaciar de golpe es lo simétrico de llenar de golpe: si al llenar nadie entra andando,
		# al vaciar nadie sale andando. Sacarlos con su desvanecimiento dejaba a los salientes
		# apilados por encima del tope justo en el fotograma que ya iba cargado.
		crowd.retire_many(maxi(-difference, 0))
		_arrival_budget = 0.0
		return true

	# Cambio normal: entra y sale gente andando, a un ritmo que se pueda mirar.
	_arrival_budget += delta * _rate(params.arrivals_per_second, current)
	while _arrival_budget >= 1.0 and difference != 0:
		_arrival_budget -= 1.0
		if difference > 0:
			crowd.spawn(params, true)
			difference -= 1
		else:
			crowd.retire_one()
			difference += 1
	return false


## Al construir las primeras cabañas, quien vivía apiñado en la plaza se muda. Sin esto, los
## habitantes fundadores se quedarían para siempre amontonados en el centro del mapa.
func _rehome_from_plaza(crowd: Crowd) -> void:
	if crowd.places.homes.is_empty():
		return
	var plaza := crowd.places.plaza
	for villager in crowd.villagers:
		if villager.home.distance_to(plaza) < 0.01:
			villager.home = crowd.places.home_point(crowd.rng())


# ---------------------------------------------------------------------------
# Oficios
# ---------------------------------------------------------------------------

func _sync_jobs(
	crowd: Crowd, node: SimNode, params: CrowdParams, delta: float, bulk: bool
) -> void:
	if crowd.size() == 0:
		return

	# El objetivo sale de la **misma función** que usa el integrador para producir. No es una
	# aproximación paralela: es la cifra buena, solo que repartida entre puntos de pantalla.
	var workers := Integrator.effective_workers(node)
	var target := {}
	var assigned := 0
	for bi in workers.size():
		if workers[bi] <= 0.0 or not crowd.places.has_job(bi):
			continue
		var want := mini(int(round(workers[bi] / crowd.represents)), crowd.size() - assigned)
		if want <= 0:
			continue
		target[bi] = want
		assigned += want

	var current := crowd.job_counts()
	var changes := 0
	if bulk:
		changes = crowd.size()
	else:
		_job_budget += delta * _rate(params.job_changes_per_second, crowd.size())
		changes = int(_job_budget)
		_job_budget -= float(changes)
	if changes <= 0:
		return

	for _i in changes:
		if not _move_one(crowd, target, current):
			break


## Mueve a un villager del oficio con más sobra al que más falta le hace. Uno por llamada:
## el ritmo lo decide el presupuesto, no este bucle.
func _move_one(crowd: Crowd, target: Dictionary, current: Dictionary) -> bool:
	var needy := -2
	var best_deficit := 0
	for job in target:
		var deficit: int = target[job] - int(current.get(job, 0))
		if deficit > best_deficit:
			best_deficit = deficit
			needy = job
	if needy == -2:
		# Nadie necesita gente: si sobra en algún oficio, esos pasan a estar ociosos.
		return _release_surplus(crowd, target, current)

	# De dónde sacarlo: primero los ociosos, y si no, del oficio que más sobrado va.
	var donor := -1
	var best_surplus := 0
	for job in current:
		if job == -1 or job == needy:
			continue
		var surplus: int = int(current[job]) - int(target.get(job, 0))
		if surplus > best_surplus:
			best_surplus = surplus
			donor = job
	if int(current.get(-1, 0)) <= 0 and donor < 0:
		return false
	var from_job := -1 if int(current.get(-1, 0)) > 0 else donor

	var villager := _pick(crowd, from_job)
	if villager == null:
		return false
	villager.assign_job(needy, crowd.places.work_point(needy, crowd.rng()))
	current[from_job] = int(current.get(from_job, 0)) - 1
	current[needy] = int(current.get(needy, 0)) + 1
	return true


func _release_surplus(crowd: Crowd, target: Dictionary, current: Dictionary) -> bool:
	for job in current:
		if job == -1:
			continue
		if int(current[job]) > int(target.get(job, 0)):
			var villager := _pick(crowd, job)
			if villager == null:
				continue
			villager.assign_job(-1, Vector2.ZERO)
			current[job] = int(current[job]) - 1
			current[-1] = int(current.get(-1, 0)) + 1
			return true
	return false


## Elige a alguien de un oficio, preferiblemente que no esté ahora mismo en su puesto: sacar
## a un villager de la granja en mitad del turno se ve como un salto.
static func _pick(crowd: Crowd, job: int) -> Villager:
	var fallback: Villager = null
	for villager in crowd.villagers:
		if villager.departing or villager.job != job:
			continue
		if villager.activity != Villager.Activity.WORKING:
			return villager
		if fallback == null:
			fallback = villager
	return fallback


static func _rate(base: float, count: int) -> float:
	return maxf(base, float(count) * RATE_FRACTION)
