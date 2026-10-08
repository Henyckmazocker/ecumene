#!/usr/bin/env bash
# =============================================================================
# augur-setup.sh — Ecúmene: catálogo, tableros y contexto en un Augur
# =============================================================================
# Uso:
#   tools/augur-setup.sh <endpoint> <email> [slug]
#   tools/augur-setup.sh https://augur.dcahomelab.com yo@ejemplo.com   (prod)
#
# Deja el proyecto `ecumene` (o el slug que se pase) listo para leer partidas (Plan «Integración
# con Augur», M5). Tres pasos, todos idempotentes:
#   1. `catalog.upsert` de cada evento de tools/augur-catalog.json (.events[]). Declara los eventos
#      y los tipos de sus props: el constructor de gráficas solo ofrece medias y filtros tipados de
#      props del catálogo. Reemplaza cada evento entero; NO borra los que ya no estén en el JSON.
#   2. Por cada tablero de tools/augur-boards.json: lo busca por nombre (`board.list`, sin distinguir
#      mayúsculas) y lo crea si no está; dentro, busca cada gráfica por título (`board.get`) y hace
#      `chart.update` si existe o `chart.create` si no. NO borra gráficas ni tableros que ya no estén
#      en el JSON, y cambiar un título crea una gráfica nueva (la vieja se borra a mano).
#   3. `project.update {claude_context}` con .claude_context de tools/augur-catalog.json.
#
# Sin índices de props (`propIndex.create`): son globales al Augur y con tope; no hacen falta con
# el volumen de hoy.
#
# La contraseña se pide con `read -s`: nunca por argumento ni por fichero. La sesión es por cookie y
# el tarro va a un temporal que se borra al salir. El paso 3 pide rol owner (el 1 y el 2, editor).
# Necesita curl y jq. Port de BioSphera/tools/augur-setup.sh y Balactorio/tools/augur-setup.sh.
# =============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BOARDS_FILE="$ROOT_DIR/tools/augur-boards.json"
CATALOG_FILE="$ROOT_DIR/tools/augur-catalog.json"

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  sed -n '5,7p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
fi

ENDPOINT="${1%/}"
EMAIL="$2"
SLUG="${3:-ecumene}"
API="$ENDPOINT/index.php"

for bin in curl jq; do
  command -v "$bin" >/dev/null || { echo "Falta '$bin' en el PATH" >&2; exit 1; }
done
jq -e '.boards | type == "array" and length > 0' "$BOARDS_FILE" >/dev/null \
  || { echo "$BOARDS_FILE no es un JSON con .boards[]" >&2; exit 1; }
jq -e '(.events | type == "array" and length > 0) and (.claude_context | type == "string")' "$CATALOG_FILE" >/dev/null \
  || { echo "$CATALOG_FILE no es un JSON con .events[] y .claude_context" >&2; exit 1; }

TOTAL_EVENTS="$(jq '.events | length' "$CATALOG_FILE")"
TOTAL_CHARTS="$(jq '[.boards[].charts[]] | length' "$BOARDS_FILE")"
echo "Catálogo: $TOTAL_EVENTS eventos · tableros: $(jq '.boards | length' "$BOARDS_FILE") con $TOTAL_CHARTS gráficas"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"
JAR="$WORK/cookies"

# `call` lee el cuerpo JSON por stdin, deja la respuesta en $WORK/resp y devuelve el código HTTP.
# Reintenta solo fallos de conexión (Cloudflare corta a veces el handshake TLS en ráfaga). El cuerpo
# pasa por fichero para poder reenviarlo, y se borra al momento: el del login lleva la contraseña.
call () {
  local body="$WORK/body" rc=0
  cat > "$body"
  curl -sS -o "$WORK/resp" -w '%{http_code}' -b "$JAR" -c "$JAR" \
    --connect-timeout 10 --retry 4 --retry-delay 1 --retry-all-errors \
    -H 'Content-Type: application/json' --data-binary @"$body" "$API" || rc=$?
  rm -f "$body"
  return "$rc"
}
resp () { cat "$WORK/resp"; }

# Sin terminal (p. ej. el `!` de Claude Code) `read` recibe EOF y `set -e` saldría sin decir nada.
if [ ! -t 0 ]; then
  echo "Hace falta una terminal interactiva para pedir la contraseña: ejecútalo en tu terminal." >&2
  exit 1
fi
read -r -s -p "Contraseña de $EMAIL en $ENDPOINT: " PASSWORD
echo
CODE="$(jq -n --arg e "$EMAIL" --arg p "$PASSWORD" '{action: "auth.login", email: $e, password: $p}' | call)"
unset PASSWORD
if [ "$CODE" != "200" ]; then
  echo "Login fallido (HTTP $CODE): $(resp)" >&2
  exit 1
fi
# Cerrar la sesión en el servidor también al salir por error (la cookie se borra con el temporal).
trap 'echo "{\"action\":\"auth.logout\"}" | call >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

FAILED=0
fail () { FAILED=$((FAILED + 1)); echo "  ✗ $*" >&2; }

# ── El proyecto ────────────────────────────────────────────────────────────────
CODE="$(echo '{"action":"project.list"}' | call)"
[ "$CODE" = "200" ] || { echo "project.list falló (HTTP $CODE): $(resp)" >&2; exit 1; }
PROJECT_ID="$(jq -r --arg s "$SLUG" '.projects[] | select(.slug == $s) | .id' "$WORK/resp")"
[ -n "$PROJECT_ID" ] || { echo "No hay proyecto '$SLUG' visible para $EMAIL en $ENDPOINT" >&2; exit 1; }
echo "Proyecto $SLUG → id $PROJECT_ID"

# ── 1. Catálogo de eventos ─────────────────────────────────────────────────────
OK=0
while IFS= read -r event; do
  name="$(jq -r '.name' <<<"$event")"
  CODE="$(jq -c --argjson pid "$PROJECT_ID" \
    '{action: "catalog.upsert", project_id: $pid, name, description: (.description // ""), properties: (.properties // {})}' \
    <<<"$event" | call)"
  if [ "$CODE" = "200" ]; then OK=$((OK + 1)); else fail "catalog.upsert $name (HTTP $CODE): $(resp)"; fi
done < <(jq -c '.events[]' "$CATALOG_FILE")
echo "1. Catálogo declarado: $OK / $TOTAL_EVENTS"

# ── 2. Tableros y gráficas ─────────────────────────────────────────────────────
CODE="$(jq -n --argjson pid "$PROJECT_ID" '{action: "board.list", project_id: $pid}' | call)"
[ "$CODE" = "200" ] || { echo "board.list falló (HTTP $CODE): $(resp)" >&2; exit 1; }
cp "$WORK/resp" "$WORK/boards.json"

CREATED=0
UPDATED=0
while IFS= read -r board; do
  bname="$(jq -r '.name' <<<"$board")"
  # El nombre es único por proyecto sin distinguir mayúsculas (collation de Augur).
  bid="$(jq -r --arg n "$bname" '[.boards[] | select((.name | ascii_downcase) == ($n | ascii_downcase)) | .id][0] // ""' "$WORK/boards.json")"
  if [ -z "$bid" ]; then
    CODE="$(jq -n --argjson pid "$PROJECT_ID" --arg n "$bname" '{action: "board.create", project_id: $pid, name: $n}' | call)"
    if [ "$CODE" != "200" ]; then fail "board.create «$bname» (HTTP $CODE): $(resp)"; continue; fi
    bid="$(jq -r '.board.id' "$WORK/resp")"
    echo "2. Tablero «$bname»: creado (id $bid)"
  else
    echo "2. Tablero «$bname»: ya existe (id $bid)"
  fi
  CODE="$(jq -n --argjson pid "$PROJECT_ID" --argjson bid "$bid" '{action: "board.get", project_id: $pid, board_id: $bid}' | call)"
  if [ "$CODE" != "200" ]; then fail "board.get «$bname» (HTTP $CODE): $(resp)"; continue; fi
  cp "$WORK/resp" "$WORK/board.json"
  while IFS= read -r chart; do
    title="$(jq -r '.title' <<<"$chart")"
    cid="$(jq -r --arg t "$title" '[.charts[] | select(.title == $t) | .id][0] // ""' "$WORK/board.json")"
    if [ -n "$cid" ]; then
      CODE="$(jq -c --argjson pid "$PROJECT_ID" --argjson cid "$cid" \
        '{action: "chart.update", project_id: $pid, chart_id: $cid, title, definition, note: (.note // null)}' <<<"$chart" | call)"
      if [ "$CODE" = "200" ]; then UPDATED=$((UPDATED + 1)); else fail "chart.update «$title» (HTTP $CODE): $(resp)"; fi
    else
      CODE="$(jq -c --argjson pid "$PROJECT_ID" --argjson bid "$bid" \
        '{action: "chart.create", project_id: $pid, board_id: $bid, title, definition, note: (.note // null)}' <<<"$chart" | call)"
      if [ "$CODE" = "200" ]; then CREATED=$((CREATED + 1)); else fail "chart.create «$title» (HTTP $CODE): $(resp)"; fi
    fi
  done < <(jq -c '.charts[]' <<<"$board")
done < <(jq -c '.boards[]' "$BOARDS_FILE")
echo "2. Gráficas: $CREATED creadas, $UPDATED actualizadas (de $TOTAL_CHARTS)"

# ── 3. Contexto para Claude ────────────────────────────────────────────────────
CODE="$(jq -c --argjson pid "$PROJECT_ID" '{action: "project.update", project_id: $pid, claude_context: .claude_context}' "$CATALOG_FILE" | call)"
if [ "$CODE" = "200" ]; then
  echo "3. claude_context escrito ($(jq -r '.claude_context | utf8bytelength' "$CATALOG_FILE") bytes)"
else
  fail "project.update claude_context (HTTP $CODE): $(resp)"
fi

if [ "$FAILED" -eq 0 ]; then
  echo "Listo: sin fallos."
else
  echo "Terminado con $FAILED fallo(s): revisa los ✗ de arriba." >&2
  exit 1
fi
