#!/usr/bin/env bash
# Suite headless de Ecúmene. Ejecutar desde la raíz del proyecto:
#   ./tools/run_tests.sh
#
# Los tests viven en tools/ dentro del proyecto a propósito: el snap de Godot no puede leer
# /tmp, así que un script fuera del proyecto no se carga.
set -uo pipefail

GODOT="${GODOT:-godot-4}"
FAILED=0

## Toda invocación de Godot va **sin `AUGUR_KEY`**: la suite no abre sesiones de analítica ni
## manda nada, aunque quien la lance tenga la clave en el entorno.
godot() {
	env -u AUGUR_KEY "$GODOT" "$@"
}

# **Godot sale con código 0 aunque un script no compile o reviente en tiempo de ejecución.**
# Confiar en el código de salida daba la suite en verde con `ui/HUD.gd` sin compilar y el juego
# arrancando sin `Main.gd`: el error salía por stderr, que además iba a /dev/null. Así que el
# log se lee y se busca el error a mano.
ERRORS='SCRIPT ERROR|Parse Error|Compile Error|^ERROR:'

## Devuelve 1 —y enseña el error— si el log de Godot trae una explosión dentro.
check_log() {
	local label="$1" log="$2"
	if grep -qE "$ERRORS" <<<"$log"; then
		echo "FALLO: $label ha soltado errores del motor"
		grep -E "$ERRORS|^ +at:" <<<"$log" | head -20
		return 1
	fi
	return 0
}

echo "== compilando scripts =="
LOG="$(godot --headless --path . --import 2>&1)"
if [ $? -ne 0 ]; then
	echo "FALLO al importar"
	exit 1
fi
check_log "la importación" "$LOG" || exit 1

echo "== smoke test de la escena =="
LOG="$(godot --headless --path . --quit-after 200 2>&1)"
if [ $? -ne 0 ]; then
	echo "FALLO en la escena"
	FAILED=1
fi
check_log "la escena" "$LOG" || FAILED=1

for test in determinism economy offline catchup save terrain crowd camera childmap crumbs legacy analytics font; do
	echo
	echo "== ${test}_test =="
	LOG="$(godot --headless --path . -s "res://tools/${test}_test.gd" 2>&1)"
	STATUS=$?
	grep -E '^(OK|FALLO|AVISO|===)' <<<"$LOG"
	if [ "$STATUS" -ne 0 ]; then
		FAILED=1
	fi
	check_log "${test}_test" "$LOG" || FAILED=1
done

echo
if [ "$FAILED" -eq 0 ]; then
	echo "SUITE EN VERDE"
else
	echo "SUITE EN ROJO"
fi
exit "$FAILED"
