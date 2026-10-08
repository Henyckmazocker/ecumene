#!/usr/bin/env bash
# Exporta las builds públicas de Ecúmene a builds/ con la clave de Augur de prod embebida
# (Plan «Builds Públicas», M1; adaptado de Balactorio/tools/export.sh).
#
# La clave vive FUERA del repo, en ~/.config/augur/ecumene-release.key (chmod 600, una línea);
# AUGUR_RELEASE_KEY_FILE apunta a otra ruta si hace falta. El script la vuelca en
# res://augur_release.cfg, que export_presets.cfg mete en el .pck (include_filter) y que el juego
# solo lee en build exportada (Analytics.attach, sección [augur], campo `key`). El .cfg está en
# .gitignore y se BORRA al salir, pase lo que pase (trap), para que la clave no se quede en el
# working tree.
#
# Dos editores: Linux y Windows salen con el snap mono (GODOT, por defecto godot-4), con sus
# plantillas .mono, que valen sin C#. La Web NO: el editor mono rechaza esa plataforma aunque el
# proyecto no tenga C#, así que va con un Godot 4.7.2 estándar autocontenido (GODOT_WEB). Si no
# está, se avisa y se salta la Web sin tumbar el escritorio.
#
# Android sale con el snap mono y --export-debug (Analytics manda channel = debug): APK
# precompilado, sin Gradle, solo arm64. Lo firma el keystore de depuración, que el snap solo puede
# leer dentro de su propio home (~/snap/godot-4/current/...: el plug `home` no ve directorios
# ocultos como ~/.local). El SDK está en ~/Android/Sdk, que sí ve. Si falta cualquiera de los dos,
# se avisa y se salta Android sin tumbar el resto. Ni se instala ni se arranca: eso es de David.
#
# Godot corre siempre con `env -u AUGUR_KEY`: con la clave en el entorno, cualquier arranque de
# la escena manda a prod, y el export no tiene por qué heredarla.
#
# Uso: tools/export.sh [linux|windows|web|android|all]   (por defecto all; no imprime la clave)
#
# No arranques la build para probarla: lleva la clave de prod y manda a Augur.
set -euo pipefail

TARGET="${1:-all}"
case "$TARGET" in
	linux|windows|web|android|all) ;;
	*)
		echo "Uso: $0 [linux|windows|web|android|all]" >&2
		exit 2
		;;
esac

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY_FILE="${AUGUR_RELEASE_KEY_FILE:-$HOME/.config/augur/ecumene-release.key}"
ENDPOINT="https://augur.dcahomelab.com"
CFG="$REPO/augur_release.cfg"
GODOT="${GODOT:-godot-4}"
GODOT_WEB="${GODOT_WEB:-$HOME/.local/opt/godot-4.7.2/Godot_v4.7.2-stable_linux.x86_64}"
# Lo que el editor estándar puede dejar vacío al abrir el proyecto (el autocontenido guarda sus
# cosas junto al binario, pero el user:// del proyecto sigue cayendo aquí).
USERDATA="$HOME/.local/share/godot/app_userdata/Ecumene"
# Android: rutas vistas desde dentro del snap. El keystore va también por el entorno
# (GODOT_ANDROID_KEYSTORE_DEBUG_*), que manda sobre los editor settings.
ANDROID_SDK="${ANDROID_SDK:-$HOME/Android/Sdk}"
ANDROID_KEYSTORE="${ANDROID_KEYSTORE:-$HOME/snap/godot-4/current/.local/share/godot/keystores/debug.keystore}"

if [[ ! -r "$KEY_FILE" ]]; then
	echo "ERROR: no se puede leer la clave de Augur de prod en '$KEY_FILE'." >&2
	echo "       Crea el fichero con la write_key del proyecto ecumene en prod (una línea) y" >&2
	echo "       'chmod 600', o apunta AUGUR_RELEASE_KEY_FILE a otra ruta." >&2
	exit 1
fi

# Sin saltos de línea ni espacios: el fichero se escribió con echo y trae '\n'.
KEY="$(tr -d '[:space:]' < "$KEY_FILE")"
if [[ -z "$KEY" ]]; then
	echo "ERROR: '$KEY_FILE' está vacío." >&2
	exit 1
fi

# ¿Existía ya el user:// del proyecto? Solo se limpia lo que deja vacío este export.
USERDATA_EXISTED=0
[[ -d "$USERDATA" ]] && USERDATA_EXISTED=1

cleanup() {
	rm -f "$CFG"
	if [[ "$USERDATA_EXISTED" == 0 && -d "$USERDATA" ]]; then
		# rmdir solo quita directorios vacíos: si algo escribió de verdad, se queda.
		find "$USERDATA" -depth -type d -exec rmdir {} \; 2>/dev/null || true
	fi
}

# Desde aquí el .cfg existe: se borra al salir, también si el export falla o se corta con Ctrl+C.
trap cleanup EXIT
( umask 077; printf '[augur]\n\nkey="%s"\nendpoint="%s"\n' "$KEY" "$ENDPOINT" > "$CFG" )
unset KEY

cd "$REPO"

# builds/ cuelga del proyecto: sin .gdignore, el --import se traga los PNG de la web exportada
# (index.png, los iconos) y la siguiente build los mete en el .pck. Los .import que dejó un
# export anterior sobran.
mkdir -p builds
touch builds/.gdignore
rm -f builds/*/*.import

want() { [[ "$TARGET" == all || "$TARGET" == "$1" ]]; }

check() {
	for f in "$@"; do
		if [[ ! -s "$f" ]]; then
			echo "ERROR: el export no ha dejado $f." >&2
			exit 1
		fi
	done
}

if want linux || want windows || want android; then
	# El --import primero: en un checkout recién clonado .godot/ no existe y el export fallaría.
	timeout 300 env -u AUGUR_KEY "$GODOT" --headless --path . --import
fi

if want linux; then
	mkdir -p builds/linux
	timeout 300 env -u AUGUR_KEY "$GODOT" --headless --path . --export-release "Linux" builds/linux/Ecumene.x86_64
	check builds/linux/Ecumene.x86_64 builds/linux/Ecumene.pck
fi

if want windows; then
	mkdir -p builds/windows
	timeout 300 env -u AUGUR_KEY "$GODOT" --headless --path . --export-release "Windows" builds/windows/Ecumene.exe
	check builds/windows/Ecumene.exe builds/windows/Ecumene.pck
fi

if want web; then
	if [[ ! -x "$GODOT_WEB" ]]; then
		echo "AVISO: no está el Godot estándar para web en '$GODOT_WEB' (GODOT_WEB); se salta la Web." >&2
		# Pedida sola, saltarla es no hacer nada: eso sí es un fallo.
		[[ "$TARGET" == web ]] && exit 1
	else
		mkdir -p builds/web
		# Su propio --import: la caché de .godot/ es compartida, pero el editor estándar la revisa.
		timeout 300 env -u AUGUR_KEY "$GODOT_WEB" --headless --path . --import
		timeout 300 env -u AUGUR_KEY "$GODOT_WEB" --headless --path . --export-release "Web" builds/web/index.html
		check builds/web/index.html builds/web/index.js builds/web/index.wasm builds/web/index.pck
	fi
fi

if want android; then
	if [[ ! -d "$ANDROID_SDK/platform-tools" || ! -d "$ANDROID_SDK/build-tools" ]]; then
		echo "AVISO: no está el SDK de Android en '$ANDROID_SDK' (ANDROID_SDK); se salta Android." >&2
		[[ "$TARGET" == android ]] && exit 1
	elif [[ ! -s "$ANDROID_KEYSTORE" ]]; then
		echo "AVISO: no está el keystore de depuración en '$ANDROID_KEYSTORE' (ANDROID_KEYSTORE); se salta Android." >&2
		[[ "$TARGET" == android ]] && exit 1
	else
		mkdir -p builds/android
		# --export-debug, no release: la plantilla de depuración es la que pone channel = debug.
		timeout 300 env -u AUGUR_KEY \
			GODOT_ANDROID_KEYSTORE_DEBUG_PATH="$ANDROID_KEYSTORE" \
			GODOT_ANDROID_KEYSTORE_DEBUG_USER=androiddebugkey \
			GODOT_ANDROID_KEYSTORE_DEBUG_PASSWORD=android \
			"$GODOT" --headless --path . --export-debug "Android (debug)" builds/android/Ecumene-debug.apk
		check builds/android/Ecumene-debug.apk
	fi
fi

echo "Builds listas:"
for d in linux windows web android; do
	if want "$d" && [[ -d "builds/$d" ]]; then
		ls -lh "builds/$d"
	fi
done
