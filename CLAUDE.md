# CLAUDE.md — Ecúmene

Juego incremental/idle de gestión a **escalas anidadas**: asentamiento → pueblo → ciudad →
región → país → imperio → planeta, donde cada escala contiene varias instancias de la anterior.
Godot 4.7, GDScript puro. Objetivo: Steam, navegador y móvil.

## 🧠 Brain

Spec y GDD completos en el segundo cerebro:
`/home/david/Documents/workspace/Brain/03 - Proyectos/Ecumene.md`

Antes de tocar diseño o balance, lee esa página y `Ecumene/Programación.md`.

## Reglas que no se negocian

1. **El agregado es la verdad; la multitud converge hacia ella.** Cada nodo es un vector de
   stats que se tickea en O(1). Los habitantes solo existen en el nodo enfocado y **nunca
   escriben en el estado**. Sin esto, un imperio no cabe en memoria ni en un móvil.

2. **Son dos simulaciones con dos relojes.** `sim/` va en ciclos, es determinista y se pausa.
   `view/crowd/` va en **segundos reales**, no es determinista, corre en pausa y le da igual la
   velocidad ×N. La multitud puede ir **con retraso** respecto a los números; no puede
   **mentir** (converge al reparto de `Integrator.effective_workers`) ni **dar saltos** (nadie
   se teletransporta, nunca se rehace la multitud entera). Tuning en `CrowdParams`, jamás en
   `SimParams`. La excepción son **los edificios**: aparecen en el acto.

   Y es una **muestra**, no una copia: pasados los 60 habitantes, un punto vale por cada cinco
   (`CrowdParams.dots_for`, y `crowd.represents` es el factor con el que se reparten los
   oficios). El coste de la vista es lineal en los puntos, así que lo que tiene techo es lo
   dibujado —salientes incluidos—, no la población.

3. **Nada automático sin delegar.** `node.jobs[b]` son **personas destinadas**, no pesos:
   construir una granja no la llena de gente y no se compra nada solo. Un juego de gestión que
   se administra solo no tiene nada que administrar. La única excepción es un nodo delegado a
   propósito, y entonces la UI apaga los botones. Ruta única para repartir:
   `Construction.set_workers`, la misma para el jugador y para el gobernador.

4. **Un solo camino para avanzar el tiempo.** `Integrator.advance(node, params, dt, mods)` lo
   usan igual el tick del juego (`dt = 1`) y el catch-up offline (`dt = 40000`). No se escribe
   una segunda ruta "para offline": si hace falta una, es que algo dejó de tener forma cerrada.

5. **La producción es lineal en la población.** Es el contrato de `BuildingDef`. Un edificio con
   producción no lineal rompe el integrador y con él el progreso offline. Si hace falta una no
   linealidad, se modela como **evento de segmento**, no como fórmula.

6. **GDScript puro, nunca C#.** El export web de Godot no soporta C#, y navegador es objetivo de
   primera. El binario instalado es `4.7.stable.mono`, pero eso no habilita nada aquí.

7. **Modelo ≠ vista.** Todo el estado en `WorldState` (RefCounted, ids propios estables). Las
   escenas y la UI solo leen. La UI muta llamando a `SimEngine` / los sistemas, nunca escribiendo
   en `WorldState`. IA y jugador usan **las mismas funciones**.

8. **Renderer Compatibility y `MultiMeshInstance2D`.** Es lo que hace que el juego corra en
   navegador y en móvil de gama baja. Nada de un nodo de escena por habitante.

9. **El save es binario.** `JSON.stringify` pierde el último bit de los dobles incluso con
   `full_precision`, y eso rompe el determinismo al continuar una partida. Para inspeccionar hay
   `Save.export_json`, que no es el formato de guardado.

10. **La analítica observa y no escribe: `state_hash` idéntico con o sin ella.** `Analytics` es
    el único que habla con Augur, y solo escucha el log; lo único que enciende es
    `events.tracing`, que vive en el log y no en el modelo. Sin clave no existe: ni modal, ni
    ⚙️, ni red, ni `user://augur/`. Los tests y el modo captura no llaman nunca a `attach`, y
    `run_tests.sh` corre con `env -u AUGUR_KEY`. La clave no entra al repo: viene del entorno o
    de `augur_release.cfg`, que está en `.gitignore`.

## Estructura

```
main/       Main.tscn/gd — arranque, carga, autoguardado
sim/        Goods, WorldState, SimEngine, Integrator, SimEventLog, NameGen, SimParams
            node/     SimNode, TierDef, BuildingDef, Governor, Route, Expedition
            systems/  Construction, Promotion, GovernorSys, Ascension, Upgrading, Logistics  (estáticos y puros)
world/      Relief (tierra y agua), TerrainGen, Layout — terreno procedural y colocación
view/       SettlementView + crowd/ (Villager, Crowd, CrowdReconciler, DayClock, Places)
camera/     ScaleCamera — paneo y zoom, ratón y dedos; el zoom es profundidad y cruza de escala
ui/         HUD — recursos con tasa, población de dos marcas, oficios, construcción, y la
            consola del gobernador (prioridades, permisos y orden) dentro de la pestaña de oficios
            UpgradeTreeView — árbol de progresión genérico (mejoras y legado)
data/       Content (catálogo de escalas y edificios), Upgrades (árbol de mejoras),
            Legacy (árbol de ascensión)
platform/   Save — user:// + volcado a IndexedDB en web
            Analytics — autoload, el primero del proyecto: clave, canal y consentimiento, y el
            único que habla con Augur
addons/     augur/ — SDK de Augur (autoload `Augur`), copiado con su install.sh; no se edita aquí,
            se cambia en augur/sdk/godot/ y se reinstala
art/        PNG generados por tools/gen_sprites.gd — se editan a mano, no se regeneran solos
tools/      tests headless + run_tests.sh + export.sh + gen_sprites, layout_dump, ceiling_dump
            web/ — Dockerfile, nginx.conf y compose de la web del homelab
            sondas de rendimiento: frame_probe (fotograma de punta a punta), crowd_probe
            (cuánto cuesta la multitud según su tamaño), spike_probe (el HUD por dentro)
            augur-setup.sh + augur-boards.json + augur-catalog.json — catálogo, tableros Ritmo y
            Gobernador y claude_context en Augur (idempotente; lo ejecuta David)
```

## Verificación

```bash
./tools/run_tests.sh                                            # suite completa
godot-4 --headless --path . -s res://tools/offline_test.gd      # el test que sostiene todo
godot-4 --headless --path . -s res://tools/era_probe.gd         # la curva de la era hasta Región, hito a hito y era 2 (~13 s/semilla)
godot-4 --headless --path . -s res://tools/era_probe.gd -- --until=h3   # solo hasta Ciudad, lo que vigila la suite (~1 s/semilla)
godot-4 --path . -- --shot=user://h10.png --shot-cycles=1800 --shot-governor --shot-hour=10
godot-4 --path . -- --shot=user://leg.png --shot-cycles=600 --shot-legacy=40 --shot-tab=4
godot-4 --path . -- --shot=user://foco.png --shot-cycles=4500 --shot-governor --shot-focus-child=0 --shot-tab=0   # hace falta un hijo llegado
godot-4 --path . -- --shot=user://vista.png --shot-cycles=48000 --shot-governor --shot-depth=2.9 --shot-tab=0  # vista agregada: ciudad, pueblos y expedición
godot-4 --path . -- --shot=user://fundido.png --shot-cycles=20000 --shot-governor --shot-focus-child=0 --shot-fade=0.5   # a mitad del cruce
godot-4 --path . -s res://tools/cross_probe.gd                  # cuánto cuesta el cruce de escala (peor fotograma y p99)
godot-4 --path . -- --offline=86400                              # la vuelta tras un día fuera
godot-4 --path . -- --shot=user://barra.png --offline=86400 --shot-catchup=0.5
godot-4 --path . -- --event-log                                 # además vuelca el diario a user://logs/*.jsonl
godot-4 --path .                                                # jugar
AUGUR_KEY="$(cat ~/.config/augur/ecumene-release.key)" godot-4 --path .   # jugar grabando en Augur PROD
tools/augur-setup.sh https://augur.dcahomelab.com <email>       # catálogo + tableros (pide contraseña)
tools/export.sh [linux|windows|web|android|all]                 # builds/ con la clave de prod dentro
docker compose -p ecumene_prod -f tools/web/docker-compose.prod.yml up -d --build   # web del homelab
```

Con `AUGUR_KEY` en el entorno, **cualquier** arranque de la escena manda a producción tras el
consentimiento (canal `dev`); por eso `run_tests.sh` va con `env -u AUGUR_KEY` y el modo captura no
llama a `attach`. La clave no entra nunca al repo.

**Builds.** `tools/export.sh` vuelca la clave de `~/.config/augur/ecumene-release.key` en
`augur_release.cfg` (`[augur] key`, en `.gitignore`), que el preset mete en el `.pck` y que el script
**borra al salir**. **No arranques una build exportada para probar: manda a Augur prod** (release en
Linux, Windows y web; `debug` en el APK). El editor del snap es **mono, y el mono no exporta a Web**:
la web sale con un Godot 4.7.2 estándar autocontenido en `~/.local/opt/godot-4.7.2/` (`GODOT_WEB`).
El snap no ve carpetas ocultas, así que el keystore de depuración y el JDK 17 de Android viven
dentro de sus datos (`~/snap/godot-4/…`). La web lleva Noto Color Emoji (`assets/fonts/`) porque el
navegador no tiene fuentes del sistema; `tools/font_test.gd` vigila que no falte ninguno.

Los tests **tienen que vivir en `tools/`** dentro del proyecto: el snap de Godot no lee `/tmp`.
Las capturas salen en `~/snap/godot-4/*/.local/share/godot/app_userdata/Ecumene/`.

`--shot-cycles` por encima de unos 5000 con `--shot-governor` deja de terminar en tiempo
razonable. Es cosa de la simulación, no del modo captura.

Al volver de una ausencia, la acreditación se reparte entre fotogramas y la partida queda
bloqueada con una barra (`Main._begin_catch_up`). Mientras dura, **la vista no se refresca**:
refrescar el HUD en cada uno de los 64 pasos es lo que colgaba el arranque unos 13 s, y el
trabajo de simulación de un día entero eran 110 ms con las colonias huérfanas; con la raíz
delegada y sus colonias también delegadas son ~3 s, y ~55 s con 👑 Dinastía al máximo.
`--offline=<segundos>` fuerza la ausencia para poder verlo sin cerrar el juego un día.

**A un `Control` que ya está en el árbol de escena no se le cambia el aspecto por el tema.**
Asignar un `Theme`, un `add_theme_*_override`, cualquier cosa que lo invalide, obliga a
reconformar su texto; y si ese texto lleva un emoji hay que resolver otra vez la fuente de
reserva. Son ~6 ms por control: el mismo botón sin emoji cuesta 0,05 ms, y fuera del árbol de
escena, 0,001. Doce nodos del árbol de mejoras cambiando a la vez —lo normal justo después de
comprar algo— eran 77 ms clavados en un fotograma. Lo que varía con el estado se dibuja en el
`_draw` del contenedor y se tiñe con `modulate`; el tema se pone una vez, antes del `add_child`,
y no se vuelve a tocar. `tools/spike_probe.gd` tiene las dos rutas cronometradas al lado.

Los invariantes que cubren:

| Invariante | Test |
|---|---|
| Mismo seed + mismas acciones ⇒ mismo `state_hash()` | `determinism_test.gd` |
| La multitud converge al agregado, sin saltos ni rebarajado | `crowd_test.gd` |
| Un punto por cada varios habitantes, y lo dibujado no se desborda por mucho que la población se meza | `crowd_test.gd` |
| La economía tiene equilibrio, y también sabe colapsar | `economy_test.gd` |
| Sin delegar no se destina, ni se compra ni se investiga nada solo | `economy_test.gd` |
| Delegando sí: reparte por todos los oficios, mira el consumo, investiga y asciende | `economy_test.gd` |
| Y solo hasta donde se le deja: sin permiso no construye, ni investiga, ni asciende — pero reparte igual | `economy_test.gd` |
| Cambiar las prioridades cambia el reparto de verdad | `economy_test.gd` |
| Cada orden (acumular, expandir, especializar) cambia lo que hace el gobernador, y sin orden todo sigue igual | `economy_test.gd` |
| Con cualquier orden puesta, la partida es determinista y acreditar troceado da lo mismo que de un tirón | `determinism_test.gd`, `catchup_test.gd` |
| Sin madera para otra cabaña, el pueblo se sigue alojando en piedra | `economy_test.gd` |
| La política del gobernador sobrevive al guardado, y un save sin permisos carga con todos | `save_test.gd` |
| Avanzar N×1 ciclo == avanzar N ciclos de un salto | `offline_test.gd` |
| Acreditar la ausencia repartida entre fotogramas da el mismo estado que de un tirón | `catchup_test.gd` |
| Guardar y cargar no altera un solo bit | `save_test.gd` |
| El foco sobrevive a guardar y cargar, fuera de `WorldState`: no cambia `state_hash` | `save_test.gd` |
| Alejar más allá del mínimo pide el padre y acercar más allá del máximo el último hijo; sin ellos, el zoom de siempre | `camera_test.gd` |
| Ningún edificio pisa a otro, y queda hueco entre ellos | `terrain_test.gd` |
| El mismo punto del mundo da el mismo terreno desde cualquier nodo | `terrain_test.gd` |
| Fundar dice por qué no se puede, con una sola lista de condiciones para jugador y gobernador | `economy_test.gd` |
| Ningún huérfano: lo que funda un gobernador nace delegado y sale de los 7,2 hab | `economy_test.gd` |
| Un pueblo delegado con la comida al límite sigue fundando hasta llenar sus plazas | `economy_test.gd` |
| No se asciende a una escala sin edificios: país, imperio y planeta están cerrados | `economy_test.gd` |
| Región pide influencia, que es √ de la cultura del subárbol | `economy_test.gd` |
| Acelerar con oro adelanta la llegada sin romper N×1 == N, y cada aceleración cuesta más | `offline_test.gd`, `economy_test.gd`, `save_test.gd` |
| La cultura suma legado por encima del suelo, y por debajo nada | `legacy_test.gd` |
| Región pide 6 pueblos, y una ciudad tarda ×7 en mandar la misma expedición que un pueblo | `economy_test.gd` |
| Una ruta no crea ni destruye recursos: se corta en los dos extremos a la vez, y el 🐎 lo paga el padre | `offline_test.gd`, `economy_test.gd` |
| Con rutas, el salto da lo mismo que el paso a paso (al error del integrador), la partida es determinista y el catch-up troceado da lo mismo que de un tirón | `offline_test.gd`, `determinism_test.gd`, `catchup_test.gd` |
| La comida importada sube K como mucho un 50 %, y al cortar la ruta se vuelve al K propio sin extinguirse | `offline_test.gd` |
| El gobernador regional saca a un hijo del hambre con rutas de comida, y sin `may_route` no toca ninguna | `economy_test.gd` |
| Las rutas sobreviven al guardado; un save v2 carga sin rutas y uno con 6 recursos, con 🐎 a 0 | `save_test.gd` |
| El tope de herederos frena el árbol delegado: sin 👑 Dinastía solo funda la raíz | `economy_test.gd` |
| Un pueblo delegado que funda colonias delegadas sigue siendo determinista | `determinism_test.gd` |
| Una colonia delegada sobrevive al guardado con su política y su reloj | `save_test.gd` |
| Ascender sube el techo de almacenamiento, y el muro nunca llega antes que el ascenso | `economy_test.gd` |
| El árbol se enseña entero, sin prometer nada de una escala a la que no se ha llegado | `economy_test.gd` |
| Ascender conserva el legado y deja una era nueva jugable | `legacy_test.gd` |
| Una expedición llega igual tickeando de 1 en 1 que de un salto, y troceada que de un tirón | `offline_test.gd`, `catchup_test.gd`, `determinism_test.gd` |
| Fundar es una expedición: una por nodo, y el hijo nace al llegar | `economy_test.gd`, `save_test.gd` |
| La analítica observa y no escribe: mismo `state_hash` con o sin rastro, autoría correcta, el rastro no entra en el diario | `analytics_test.gd` |
| El ritmo de la era: primer hijo en 2.400-5.400 ciclos, Ciudad en 14.400-32.400, y la era 2 llega a Pueblo en ≤ 0,95 y a Ciudad en ≤ 0,8 del tiempo de la primera | `economy_test.gd`, `legacy_test.gd` |
