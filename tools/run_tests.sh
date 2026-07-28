#!/usr/bin/env bash
# Suite headless de Ecúmene. Ejecutar desde la raíz del proyecto:
#   ./tools/run_tests.sh
#
# Los tests viven en tools/ dentro del proyecto a propósito: el snap de Godot no puede leer
# /tmp, así que un script fuera del proyecto no se carga.
set -uo pipefail

GODOT="${GODOT:-godot-4}"
FAILED=0

echo "== compilando scripts =="
"$GODOT" --headless --path . --import >/dev/null 2>&1 || { echo "FALLO al importar"; exit 1; }

echo "== smoke test de la escena =="
"$GODOT" --headless --path . --quit-after 200 >/dev/null 2>&1 || { echo "FALLO en la escena"; FAILED=1; }

for test in determinism economy offline save agents; do
	echo
	echo "== ${test}_test =="
	if ! "$GODOT" --headless --path . -s "res://tools/${test}_test.gd" 2>&1 | grep -E '^(OK|FALLO|===)'; then
		FAILED=1
	fi
	# grep se traga el código de salida de Godot: se recupera del pipe.
	if [ "${PIPESTATUS[0]}" -ne 0 ]; then
		FAILED=1
	fi
done

echo
if [ "$FAILED" -eq 0 ]; then
	echo "SUITE EN VERDE"
else
	echo "SUITE EN ROJO"
fi
exit "$FAILED"
