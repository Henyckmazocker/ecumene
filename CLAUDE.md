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

3. **Un solo camino para avanzar el tiempo.** `Integrator.advance(node, params, dt, mods)` lo
   usan igual el tick del juego (`dt = 1`) y el catch-up offline (`dt = 40000`). No se escribe
   una segunda ruta "para offline": si hace falta una, es que algo dejó de tener forma cerrada.

4. **La producción es lineal en la población.** Es el contrato de `BuildingDef`. Un edificio con
   producción no lineal rompe el integrador y con él el progreso offline. Si hace falta una no
   linealidad, se modela como **evento de segmento**, no como fórmula.

5. **GDScript puro, nunca C#.** El export web de Godot no soporta C#, y navegador es objetivo de
   primera. El binario instalado es `4.7.stable.mono`, pero eso no habilita nada aquí.

6. **Modelo ≠ vista.** Todo el estado en `WorldState` (RefCounted, ids propios estables). Las
   escenas y la UI solo leen. La UI muta llamando a `SimEngine` / los sistemas, nunca escribiendo
   en `WorldState`. IA y jugador usan **las mismas funciones**.

7. **Renderer Compatibility y `MultiMeshInstance2D`.** Es lo que hace que el juego corra en
   navegador y en móvil de gama baja. Nada de un nodo de escena por habitante.

8. **El save es binario.** `JSON.stringify` pierde el último bit de los dobles incluso con
   `full_precision`, y eso rompe el determinismo al continuar una partida. Para inspeccionar hay
   `Save.export_json`, que no es el formato de guardado.

## Estructura

```
main/       Main.tscn/gd — arranque, carga, autoguardado
sim/        Goods, WorldState, SimEngine, Integrator, SimEventLog, NameGen, SimParams
            node/     SimNode, TierDef, BuildingDef, Governor
            systems/  Construction, Promotion, GovernorSys, Ascension  (estáticos y puros)
world/      Biomes, TerrainGen, Layout — terreno procedural y colocación
view/       SettlementView + crowd/ (Villager, Crowd, CrowdReconciler, DayClock, Places)
camera/     SettlementCamera — paneo y zoom, ratón y dedos
ui/         HUD — recursos con tasa, población de dos marcas, oficios, construcción
data/       Content (catálogo de escalas y edificios), Legacy (árbol de ascensión)
platform/   Save — user:// + volcado a IndexedDB en web
tools/      tests headless + run_tests.sh
```

## Verificación

```bash
./tools/run_tests.sh                                            # suite completa
godot-4 --headless --path . -s res://tools/offline_test.gd      # el test que sostiene todo
godot-4 --path . -- --shot=user://h10.png --shot-cycles=1800 --shot-governor --shot-hour=10
godot-4 --path .                                                # jugar
```

Los tests **tienen que vivir en `tools/`** dentro del proyecto: el snap de Godot no lee `/tmp`.

Los invariantes que cubren:

| Invariante | Test |
|---|---|
| Mismo seed + mismas acciones ⇒ mismo `state_hash()` | `determinism_test.gd` |
| La multitud converge al agregado, sin saltos ni rebarajado | `crowd_test.gd` |
| La economía tiene equilibrio, y también sabe colapsar | `economy_test.gd` |
| Avanzar N×1 ciclo == avanzar N ciclos de un salto | `offline_test.gd` |
| Guardar y cargar no altera un solo bit | `save_test.gd` |
