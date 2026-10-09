class_name HUD
extends CanvasLayer

## HUD del asentamiento. Construido por código: un panel de estos es trivial de mantener así
## y no arrastra un `.tscn` enorme que hay que abrir en el editor para cambiar un margen
## (la misma decisión que en Worlding).
##
## **Todo el HUD es un solo dock.** Antes eran dos barras a ancho completo, arriba y abajo,
## con el mundo estrujado en la franja de en medio: a 1280×720 se comían la mitad del alto y
## el terreno se veía por una rendija. Ahora hay un único panel con las pestañas pegadas a su
## borde superior, que **cambia de sitio según la forma de la pantalla**:
##
##   * ancha (escritorio, navegador, móvil apaisado) → columna a la derecha, a toda altura;
##   * alta (móvil vertical) → hoja inferior.
##
## Es el mismo árbol de controles en los dos casos —no hay dos diseños que mantener—: solo
## cambian las anclas del dock, en [method _layout]. El resto de la pantalla es mundo, sin
## nada encima.
##
## La regla de UX que sigue en pie: **la tasa por ciclo va siempre pegada al stock**, porque
## en un incremental el número que el jugador lee de verdad es la derivada.

signal build_requested(building_index: int)
signal speed_requested(index: int)
## Mover gente a un oficio (`amount` negativo la saca).
signal workers_changed(building_index: int, amount: float)
signal delegation_toggled(delegated: bool)
## Retocar la política del gobernador del nodo: una prioridad (0..1) o un permiso (0 ó 1).
signal governor_changed(field: String, value: float)
signal promotion_requested()
## Fundar un hijo desde el nodo enfocado. Lo atiende `Main`, que llama a
## `Promotion.launch_expedition`; con `delegate`, la colonia nace en manos de un gobernador
## (`GovernorSys.delegate`) al llegar.
signal found_requested(delegate: bool)
## ⏩ Acelerar con oro la expedición en camino del nodo enfocado. Lo atiende `Main`, que llama a
## `Promotion.accelerate_expedition`, la misma lista de condiciones que pinta el botón.
signal accelerate_requested()
signal upgrade_requested(id: String)
signal legacy_requested(id: String)
signal ascension_requested()
## 🛒 Comprar un objeto pagando con `good` (🪙 o 📜) del almacén del nodo enfocado. Lo atiende
## `Main`, que llama a `Shop.buy`: la misma lista de condiciones (`Shop.buy_blocker`) que pinta el
## botón.
signal item_buy_requested(id: String, good: int)
## 🛒 Usar un objeto del inventario: un ⚡ sobre el nodo enfocado o, con `all`, uno por nodo de su
## subárbol (`Shop.use_boost`); un ⌛ sobre el mundo entero (`Main.use_skip`, `all` no cuenta).
signal item_use_requested(id: String, all: bool)
## Enfocar otro nodo: un hijo desde la lista de «Colonias» o un ancestro desde las migas de pan.
## Lo atiende `Main._focus`, el mismo que enfoca la raíz al cargar.
signal focus_requested(id: int)
## Crear una ruta, cambiarle el caudal o borrarla (`rate` 0) entre el nodo enfocado y un hijo. Lo
## atiende `Main._on_route`, que llama a `Logistics.set_route`: la misma ruta que tendrá el
## gobernador regional.
signal route_requested(from_id: int, to_id: int, good: int, rate: float)
## El jugador ha elegido en el modal de consentimiento. Solo se emite al **elegir**: «Volver»
## (en modo «cambiar») cierra sin emitir. `Main` llama a `Analytics.set_consent` y, si era el
## primer arranque, devuelve la velocidad que había.
signal consent_decided(granted: bool)
## ⚙️ pulsado. Lo atiende `Main`, que sabe la decisión vigente y abre el modal en modo «cambiar».
signal consent_settings_requested()

const IDLE_COLOR := Color(0.62, 0.62, 0.60)
const WARN_COLOR := Color(0.85, 0.35, 0.30)
const OK_COLOR := Color(0.65, 0.80, 0.62)
## Migas de pan: los ancestros apagados, el eslabón activo encendido. Con `modulate`, nunca con el
## tema: los botones ya están en el árbol.
const CRUMB_COLOR := Color(0.70, 0.76, 0.74, 0.85)
const CRUMB_ACTIVE_COLOR := Color(1.0, 0.86, 0.52)

const TAB_STATUS := 0
const TAB_JOBS := 1
const TAB_BUILD := 2
const TAB_UPGRADES := 3
const TAB_LEGACY := 4
const TAB_SHOP := 5

## El título del panel de vuelta, y el que pone mientras avanza un ⌛ (que no tiene informe).
const WELCOME_TITLE := "🌙 Mientras no estabas"
const SKIP_TITLE := "⌛ El mundo avanza"

## Los estados de `Upgrading` y los del widget son la misma idea contada dos veces: uno es
## modelo y el otro es dibujo, y por eso no se importan entre ellos.
const TREE_STATE := {
	Upgrading.State.OWNED: UpgradeTreeView.State.OWNED,
	Upgrading.State.AVAILABLE: UpgradeTreeView.State.AVAILABLE,
	Upgrading.State.LOCKED: UpgradeTreeView.State.LOCKED,
}

## Las cuatro prioridades del gobernador, en el orden en que `Governor.weights()` las devuelve.
const GOVERNOR_PRIORITIES := [
	["food", "🌾 Comida"],
	["growth", "👶 Crecimiento"],
	["industry", "⚒️ Industria"],
	["expansion", "🧭 Expansión"],
]

## Qué le dejas hacer. Repartir la gente no está aquí: eso lo hace siempre, es lo que es.
##
## Con palabra y no solo icono: cuatro emojis en fila son cuatro adivinanzas, y un interruptor
## que no dice lo que apaga es peor que no estar.
const GOVERNOR_PERMISSIONS := [
	["may_build", "🔨 Construir", "Le dejas gastar el almacén en edificios"],
	["may_research", "🔬 Investigar", "Le dejas comprar mejoras"],
	["may_promote", "⬆️ Ascender", "Le dejas subir de escala al cumplir el umbral"],
	["may_expand", "🌱 Colonizar", "Le dejas fundar nodos hijos con tu gente y tu comida"],
	["may_route", "🛣️ Rutas",
		"Le dejas llevar las rutas de comida con tus hijos, también las que hiciste a mano"],
]

## Permisos que solo se enseñan desde una escala: un interruptor que no hace nada en el nodo que
## miras es ruido. Las rutas solo existen en una región con hijos (`GovernorSys._route_food`); el
## permiso se sigue guardando y copiando en todas, igual que los demás.
const GOVERNOR_PERMISSION_MIN_TIER := {"may_route": Content.REGION}

## Las órdenes puntuales, una por botón, con el ordinal de `Governor.Order` que fijan. Sin
## `NONE`: no hay botón de «ninguna», se quita la orden volviendo a pulsar la activa.
const GOVERNOR_ORDERS := [
	[Governor.Order.STOCKPILE, "📦 Acumular", "Junta recursos y no gasta hasta llenar el almacén"],
	[Governor.Order.EXPAND, "🧭 Expandir", "Funda antes y prioriza las casas"],
	[Governor.Order.SPECIALIZE, "🎯 Especializar", "Concentra la gente en tu prioridad más alta"],
]

## Cuánto caudal sube o baja cada pulsación de ± en una ruta, y con cuánto nace. Cada unidad de
## caudal cuesta `Logistics.TRANSPORT_PER_FLOW` (0,5) 🐎 por ciclo al padre, así que un paso de 0,5
## cuesta 0,25 🐎/ciclo: **lo que da un mozo de establo** (4 mozos × 0,25 = 1 🐎 por establo lleno).
## Un establo sostiene 4 pasos y los 2 establos de una región recién llegada, 8 (4 de caudal). Más
## fino no se lee en un número de una cifra; más grueso, una ruta de un paso ya se come medio
## establo.
const ROUTE_STEP := 0.5

## Por debajo de esta relación de aspecto el dock se va abajo en vez de a la derecha.
const WIDE_ASPECT := 1.15
## Ancho del dock en pantalla ancha: una fracción, acotada para que ni se coma el mundo en un
## monitor grande ni ahogue los botones en una ventana pequeña.
const DOCK_WIDTH_FRACTION := 0.30
const DOCK_WIDTH_MIN := 320.0
const DOCK_WIDTH_MAX := 480.0
## Alto del dock en pantalla alta. Deja al mundo la mitad larga de la pantalla.
const DOCK_HEIGHT_FRACTION := 0.42
const DOCK_HEIGHT_MIN := 260.0
const DOCK_HEIGHT_MAX := 520.0
## Por debajo de este ancho las palabras no caben y las pestañas se quedan en icono.
## Eran cuatro y el umbral estaba en 340; con «Legado» dentro, a 384 px ya sobraba una, y se subió
## a 440. Con «Tienda» son seis, ~85 px por pestaña: 530, por encima de `DOCK_WIDTH_MAX`. La
## columna derecha va siempre en iconos; la hoja inferior de un móvil vertical, a lo ancho, no.
const COMPACT_TABS_BELOW := 530.0

var _dock: PanelContainer
var _dock_style: StyleBoxFlat
var _modal: Control
var _title: Label
## Las migas de pan, `Raíz › … › Enfocado`, encima de las pestañas. `_crumbs_clip` recorta y no
## deja que el ancho de la cadena empuje el dock: dentro, `_crumbs` es una fila libre, fuera de
## cualquier contenedor que le pida sitio a su padre.
var _crumbs_clip: Control
var _crumbs: HBoxContainer
## «… ›»: sustituye a los eslabones de la izquierda que no caben.
var _crumbs_more: Label
## Los eslabones, de la raíz al enfocado: `[botón, separador «›», ancho, id que pide o -1]`. Es una
## reserva que solo crece: se usan los `_crumb_count` primeros y el resto está escondido.
var _crumb_links: Array = []
var _crumb_count: int = 0
## Qué cadena hay construida (ids, escalas y nombres). Solo se reconstruye cuando cambia.
var _crumbs_key: String = ""
var _subtitle: Label
var _pop_bar: PopulationBar
var _pop_label: Label
var _promotion_box: VBoxContainer
var _promotion_label: Label
var _promotion_button: Button
var _found_box: VBoxContainer
var _found_slots: Label
var _found_button: Button
var _found_delegate_button: Button
var _accelerate_button: Button
var _found_reason: Label
var _children_box: VBoxContainer
var _children_title: Label
var _children_rows: Array[Button] = []
## La lista de rutas del nodo enfocado con sus hijos (`_build_routes_list`). Las filas se
## reutilizan por posición, como las de colonias; el formulario de abajo crea rutas nuevas.
var _routes_box: VBoxContainer
var _route_list: VBoxContainer
var _route_rows: Array[VBoxContainer] = []
var _route_child: OptionButton
var _route_dir: OptionButton
var _route_good: OptionButton
var _route_create: Button
var _route_reason: Label
## Lo que hay en los desplegables: los ids de los hijos y los recursos, en el orden de sus items.
## Solo se rehacen cuando cambian, no en cada refresco.
var _route_child_ids := PackedInt32Array()
var _route_goods := PackedInt32Array()
## El nodo y el estado del último refresco, para recalcular el motivo de no poder crear al tocar
## un desplegable con la partida en pausa. Solo se leen.
var _route_node: SimNode
var _route_state: WorldState
var _tabs: TabContainer
var _upgrade_tree: UpgradeTreeView
var _legacy_tree: UpgradeTreeView
var _legacy_title: Label
var _legacy_subtitle: Label
var _ascension_box: VBoxContainer
var _ascension_label: Label
var _ascension_button: Button
var _confirm: PanelContainer
var _confirm_body: Label
var _ascension_warning: String = ""
## 🛒 La pestaña de la tienda. Todo se crea una vez en `_build_shop_tab`, con el tema puesto antes
## del `add_child`; al refrescar solo cambian `text`, `disabled`, `tooltip_text` y `visible`, y el
## texto solo cuando cambia (`_set_text`).
var _shop_drip: Label
var _shop_pay: Label
## Una por objeto, en el orden de `Items.all()`: `{id, header, gold, culture, use, all, reason}`.
var _shop_rows: Array[Dictionary] = []
## ⚡ en 📊 Estado: «⚡ ×2 · quedan 412 ciclos». Solo se ve con un boost activo.
var _boost_label: Label
## Hay una acreditación (ausencia o ⌛) a medias: `Shop.use_blocker` la recibe como `busy`. El HUD
## lo sabe porque es quien enseña la barra (`begin_catch_up`/`end_catch_up`).
var _busy: bool = false
## Lo que dice la barra: «acreditando» una ausencia o «adelantando» un ⌛, y el título del panel.
var _catch_up_verb: String = "acreditando"
var _welcome_title: Label
## El modal de consentimiento y su ⚙️. **Solo existen con clave**: `enable_consent` los construye
## cuando `Main` sabe que `Analytics.enabled`, y sin clave se quedan en `null`.
var _consent: PanelContainer
var _consent_status: Label
var _consent_accept: Button
var _consent_reject: Button
var _consent_back: Button
## Si el modal abierto es el del primer arranque: con velo y sin forma de salir sin elegir.
var _consent_blocking: bool = false
var _speeds_row: HBoxContainer
var _resource_rows: Dictionary = {}
var _resource_box: VBoxContainer
var _build_box: HFlowContainer
var _build_buttons: Dictionary = {}
var _job_box: VBoxContainer
var _job_rows: Dictionary = {}
var _idle_label: Label
var _step_buttons: Array[Button] = []
var _delegate_button: Button
var _governor_box: VBoxContainer
var _governor_sliders: Dictionary = {}
var _governor_shares: Dictionary = {}
var _governor_checks: Dictionary = {}
## El peaje de delegar, a la vista y sin hover (en móvil no hay tooltip).
var _governor_toll: Label
## Lo que rinde un nodo delegado, tal y como lo aplica `SimEngine.tick`. Se lee una vez por
## refresco con la misma función del motor: la UI no hace su propia cuenta del peaje.
var _governor_efficiency: float = 0.0
## Por qué un nodo delegado con permiso de colonizar no coloniza: el tope de herederos.
var _heirs_note: Label
## Los botones de orden, en el mismo orden que `GOVERNOR_ORDERS`, y la línea que dice qué está
## haciendo el gobernador por culpa de la orden activa.
var _order_buttons: Array[Button] = []
var _order_note: Label
## Lo último que se pintó en los botones de orden: la orden y si puede colonizar, que es lo único
## que cambia la frase. Solo se tocan botones y frase cuando esto cambia, no en cada refresco.
var _order_shown: int = -1
var _speed_buttons: Array[Button] = []
## Cuánta gente mueve cada pulsación. Con miles de habitantes, ir de uno en uno es inviable.
var _step: int = 1
var _welcome: PanelContainer
var _welcome_body: Label
var _welcome_button: Button
var _catch_up_box: VBoxContainer
var _catch_up_label: Label
var _catch_up_bar: ProgressBar
var _veil: Control
var _feed: Label
var _feed_lines: PackedStringArray = PackedStringArray()
## Estado de los títulos de pestaña, para poder recomponerlos sin releerlos de la interfaz.
var _promotion_ready: bool = false
var _famine_warning: bool = false
var _tabs_with_text: bool = true


func _ready() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_dock = _build_dock()
	root.add_child(_dock)

	# El velo va **entre el dock y el modal**: tapa el mundo y el dock —así de verdad no se
	# puede tocar nada mientras se acredita la ausencia— y deja el panel por encima.
	_veil = _build_veil()
	root.add_child(_veil)

	# El modal vive en su propia capa anclada al hueco libre: centrado en la ventana quedaría
	# medio debajo del dock.
	_modal = Control.new()
	_modal.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_modal)
	var centered := CenterContainer.new()
	centered.set_anchors_preset(Control.PRESET_FULL_RECT)
	centered.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_modal.add_child(centered)
	centered.add_child(_build_welcome())

	var confirm_center := CenterContainer.new()
	confirm_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	confirm_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_modal.add_child(confirm_center)
	confirm_center.add_child(_build_confirm())

	get_viewport().size_changed.connect(_layout)
	_layout()


# ---------------------------------------------------------------------------
# Colocación del dock
# ---------------------------------------------------------------------------

## Dónde cae el dock, en píxeles de pantalla.
##
## Es una **función pura del tamaño de la ventana**: no mira el rectángulo real de ningún
## `Control`, así que da la respuesta correcta antes de que el layout se haya resuelto y
## `Main` puede preguntar en cualquier orden sin quedarse un fotograma por detrás.
func dock_rect(viewport: Vector2) -> Rect2:
	if viewport.x >= viewport.y * WIDE_ASPECT:
		var w := clampf(viewport.x * DOCK_WIDTH_FRACTION, DOCK_WIDTH_MIN, DOCK_WIDTH_MAX)
		w = minf(w, viewport.x)
		return Rect2(viewport.x - w, 0.0, w, viewport.y)
	var h := clampf(viewport.y * DOCK_HEIGHT_FRACTION, DOCK_HEIGHT_MIN, DOCK_HEIGHT_MAX)
	h = minf(h, viewport.y)
	return Rect2(0.0, viewport.y - h, viewport.x, h)


## Lo que le queda al mundo. Es lo que encuadra la cámara.
func free_rect() -> Rect2:
	var viewport := Vector2(get_viewport().get_visible_rect().size)
	var dock := dock_rect(viewport)
	if dock.size.x >= viewport.x:  # dock abajo
		return Rect2(0.0, 0.0, viewport.x, dock.position.y)
	return Rect2(0.0, 0.0, dock.position.x, viewport.y)


## Coloca el dock y redondea sus esquinas por el lado que da al mundo. A ras del borde de la
## ventana: un dock con margen alrededor se lee como un menú flotante, no como parte del marco.
func _layout() -> void:
	if _dock == null:
		return
	var viewport := Vector2(get_viewport().get_visible_rect().size)
	var dock := dock_rect(viewport)
	var wide := dock.size.x < viewport.x

	_dock.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_dock.position = dock.position
	_dock.size = dock.size

	_dock_style.corner_radius_top_left = 12
	_dock_style.corner_radius_bottom_left = 12 if wide else 0
	_dock_style.corner_radius_top_right = 0 if wide else 12
	_dock_style.corner_radius_bottom_right = 0

	var free := free_rect()
	_modal.position = free.position
	_modal.size = free.size

	_set_tab_titles(dock.size.x >= COMPACT_TABS_BELOW)


## Pantalla de vuelta. Un panel modal, descartable de un toque.
##
## El catch-up ya funcionaba y era **invisible**: volvías y los números eran otros sin que
## nadie te contara nada. En un idle, lo que pasó mientras no estabas es la mitad del juego.
##
## El mismo panel cuenta la vuelta en dos tiempos: primero la barra de lo que se está
## acreditando, y cuando acaba se convierte en el informe. Son dos caras del mismo momento, así
## que comparten marco en vez de relevarse con un pestañeo.
func _build_welcome() -> Control:
	_welcome = _modal_panel()

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	_welcome.add_child(box)

	var title := Label.new()
	title.text = WELCOME_TITLE
	title.add_theme_font_size_override("font_size", 22)
	box.add_child(title)
	_welcome_title = title

	_catch_up_box = VBoxContainer.new()
	_catch_up_box.add_theme_constant_override("separation", 8)
	_catch_up_box.visible = false
	box.add_child(_catch_up_box)

	_catch_up_label = Label.new()
	_catch_up_label.add_theme_font_size_override("font_size", 14)
	_catch_up_box.add_child(_catch_up_label)

	_catch_up_bar = _build_catch_up_bar()
	_catch_up_box.add_child(_catch_up_bar)

	_welcome_body = Label.new()
	_welcome_body.add_theme_font_size_override("font_size", 14)
	box.add_child(_welcome_body)

	_welcome_button = Button.new()
	_welcome_button.text = "Continuar"
	_welcome_button.custom_minimum_size = Vector2(0, 46)
	_welcome_button.pressed.connect(func() -> void: _welcome.visible = false)
	box.add_child(_welcome_button)
	return _welcome


## La barra de la acreditación. Los estilos se ponen **aquí y una sola vez**: cada override de
## tema fuerza un re-shape del texto del control, y esta barra se toca en cada fotograma.
func _build_catch_up_bar() -> ProgressBar:
	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(280, 18)
	bar.max_value = 100.0
	bar.show_percentage = false

	var back := StyleBoxFlat.new()
	back.bg_color = Color(1, 1, 1, 0.08)
	var fill := StyleBoxFlat.new()
	fill.bg_color = OK_COLOR
	for style in [back, fill]:
		for corner in ["top_left", "top_right", "bottom_left", "bottom_right"]:
			style.set("corner_radius_" + corner, 4)
	bar.add_theme_stylebox_override("background", back)
	bar.add_theme_stylebox_override("fill", fill)
	return bar


## El velo que bloquea la partida mientras se acredita la ausencia.
##
## `MOUSE_FILTER_STOP` a pantalla completa: se come los clics antes de que lleguen al dock y
## antes de que la cámara los vea en `_unhandled_input`. Los eventos de dedo y los gestos **no**
## los para un `Control`, así que la cámara se apaga aparte, desde `Main`.
func _build_veil() -> Control:
	var veil := Control.new()
	veil.set_anchors_preset(Control.PRESET_FULL_RECT)
	veil.mouse_filter = Control.MOUSE_FILTER_STOP
	veil.visible = false

	var shade := ColorRect.new()
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.color = Color(0, 0, 0, 0.45)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	veil.add_child(shade)
	return veil


## El marco de los paneles que se plantan encima del mundo. Con borde y esquinas redondeadas, al
## revés que el dock: este sí es una cosa flotante y tiene que leerse como tal.
func _modal_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.08, 0.09, 0.97)
	style.set_border_width_all(2)
	style.border_color = Color(0.35, 0.45, 0.40)
	for corner in ["top_left", "top_right", "bottom_left", "bottom_right"]:
		style.set("corner_radius_" + corner, 10)
	for side in ["left", "top", "right", "bottom"]:
		style.set("content_margin_" + side, 24)
	panel.add_theme_stylebox_override("panel", style)
	panel.visible = false
	return panel


## Confirmación del ascenso.
##
## Es la única acción del juego que **destruye la partida**: reinicia el árbol entero a cambio
## de legado. Todo lo demás se deshace jugando; esto no. Un botón suelto en una pestaña no es
## bastante puerta para eso.
func _build_confirm() -> Control:
	_confirm = _modal_panel()

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	_confirm.add_child(box)

	var title := Label.new()
	title.text = "⭐ Ascender"
	title.add_theme_font_size_override("font_size", 22)
	box.add_child(title)

	_confirm_body = Label.new()
	_confirm_body.add_theme_font_size_override("font_size", 14)
	_confirm_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_confirm_body.custom_minimum_size = Vector2(280, 0)
	box.add_child(_confirm_body)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	box.add_child(buttons)

	var cancel := Button.new()
	cancel.text = "Seguir aquí"
	cancel.custom_minimum_size = Vector2(0, 46)
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel.pressed.connect(func() -> void: _confirm.visible = false)
	buttons.add_child(cancel)

	var accept := Button.new()
	accept.text = "⭐ Ascender"
	accept.custom_minimum_size = Vector2(0, 46)
	accept.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	accept.pressed.connect(func() -> void:
		_confirm.visible = false
		ascension_requested.emit())
	buttons.add_child(accept)
	return _confirm


## Texto del consentimiento, literal del plan de integración con Augur. Lo que se promete aquí es
## lo que hace `Analytics`: si cambia una cosa, cambia la otra. Lo de la IA externa no es
## opcional: el SDK lo exige en su README, porque un editor puede pedir esa lectura.
const CONSENT_TITLE := "¿Nos ayudas a mejorar Ecúmene?"
const CONSENT_BODY := ("Si aceptas, el juego guarda de forma anónima cómo avanza tu partida: "
	+ "cuándo creces y subes de escala, qué delegas y qué deciden tus gobernadores. Sirve para "
	+ "ajustar el ritmo y la IA.\n\n"
	+ "No se recoge tu nombre, ni tu IP, ni nada fuera del juego. Los datos se identifican con "
	+ "un número aleatorio de esta instalación, se guardan en un servidor propio y pueden "
	+ "analizarse bajo demanda con un servicio de IA externo (Anthropic Claude).\n\n"
	+ "Puedes cambiar de opinión cuando quieras desde ⚙️. Si rechazas, no se guarda nada.")


## Monta el modal de consentimiento y el ⚙️. Lo llama `Main` una vez, tras `Analytics.attach`, y
## solo si hay clave: sin ella no se construye nada y el HUD es el de siempre.
##
## Las dos piezas se **construyen enteras fuera del árbol** y entran con un único `add_child`
## (regla del tema del `CLAUDE.md`): ni un override sobre un control vivo. Lo que cambia según
## la decisión —la línea de estado, qué botón está apagado, si hay «Volver»— es texto,
## `disabled` y `visible`, que no invalidan el tema. La línea de estado no lleva emoji, para que
## reescribirla no obligue a resolver la fuente de reserva.
func enable_consent() -> void:
	if _consent != null:
		return
	# Mismo marco y misma capa que el del ascenso: centrado en el hueco libre, encima del velo.
	_consent = _modal_panel()
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	_consent.add_child(box)

	var title := Label.new()
	title.text = CONSENT_TITLE
	title.add_theme_font_size_override("font_size", 22)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(title)

	var body := Label.new()
	body.text = CONSENT_BODY
	body.add_theme_font_size_override("font_size", 14)
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(340, 0)
	box.add_child(body)

	_consent_status = Label.new()
	_consent_status.add_theme_font_size_override("font_size", 13)
	_consent_status.modulate = OK_COLOR
	_consent_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_consent_status.visible = false
	box.add_child(_consent_status)

	# Los dos pesan lo mismo: mismo tamaño, mismo estilo, a partes iguales del ancho. Un «no»
	# más pequeño o más gris que el «sí» no es un consentimiento, es un empujón.
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	box.add_child(buttons)
	_consent_reject = Button.new()
	_consent_reject.text = "No, gracias"
	_consent_accept = Button.new()
	_consent_accept.text = "Aceptar"
	for pair in [[_consent_reject, false], [_consent_accept, true]]:
		var b: Button = pair[0]
		b.custom_minimum_size = Vector2(0, 46)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_on_consent_chosen.bind(bool(pair[1])))
		buttons.add_child(b)

	# Solo en modo «cambiar»: desde ⚙️ sí se puede volver sin tocar nada.
	_consent_back = Button.new()
	_consent_back.text = "Volver"
	_consent_back.custom_minimum_size = Vector2(0, 40)
	_consent_back.visible = false
	_consent_back.pressed.connect(close_consent)
	box.add_child(_consent_back)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(_consent)
	_modal.add_child(center)

	# El ⚙️ junto a las velocidades, del mismo alto. Sin `EXPAND_FILL`: es un ajuste, no una
	# velocidad más, y no tiene por qué quitarles ancho a partes iguales.
	var gear := Button.new()
	gear.text = "⚙️"
	gear.tooltip_text = "Datos de uso anónimos"
	gear.custom_minimum_size = Vector2(44, 40)
	gear.pressed.connect(func() -> void: consent_settings_requested.emit())
	_speeds_row.add_child(gear)


## Abre el modal. `blocking` es el primer arranque: velo encima del dock y del mundo, sin
## «Volver», y no se va hasta que se elige. Sin `blocking` es el ⚙️: enseña la decisión vigente
## (`granted`), apaga el botón que ya está elegido y deja volver sin cambiar.
func open_consent(blocking: bool, granted: bool) -> void:
	if _consent == null:
		return
	_consent_blocking = blocking
	_veil.visible = blocking
	_consent_back.visible = not blocking
	_consent_status.visible = not blocking
	_consent_accept.disabled = not blocking and granted
	_consent_reject.disabled = not blocking and not granted
	if not blocking:
		var text := ("Ahora mismo: aceptado. Se guarda cómo avanza tu partida." if granted
				else "Ahora mismo: rechazado. No se guarda nada.")
		if _consent_status.text != text:
			_consent_status.text = text
	# Si estaba abierta la confirmación del ascenso, se cierra: dos paneles en el mismo hueco
	# se pisarían.
	_confirm.visible = false
	_consent.visible = true


func close_consent() -> void:
	if _consent == null:
		return
	_consent.visible = false
	if _consent_blocking:
		_veil.visible = false
		_consent_blocking = false


func is_consent_open() -> bool:
	return _consent != null and _consent.visible


func _on_consent_chosen(granted: bool) -> void:
	close_consent()
	consent_decided.emit(granted)


## Selecciona una pestaña. Lo usa el modo de captura para poder fotografiar las tres.
func select_tab(index: int) -> void:
	if _tabs != null and index >= 0 and index < _tabs.get_tab_count():
		_tabs.current_tab = index


func show_offline(report: OfflineReport) -> void:
	if report == null or not report.has_anything_to_say():
		return
	_welcome_body.text = "\n".join(report.lines())
	_welcome.visible = true


# ---------------------------------------------------------------------------
# La vuelta: barra de acreditación
# ---------------------------------------------------------------------------

## Levanta el velo y enseña la barra. A partir de aquí no se puede tocar la partida hasta que
## `end_catch_up` diga que el mundo ya está al día.
func begin_catch_up(seconds_away: float, skip := false) -> void:
	_busy = true
	_catch_up_verb = "adelantando" if skip else "acreditando"
	var title := SKIP_TITLE if skip else WELCOME_TITLE
	if _welcome_title.text != title:
		_welcome_title.text = title
	_veil.visible = true
	_welcome.visible = true
	_catch_up_box.visible = true
	_welcome_body.visible = false
	_welcome_button.visible = false
	_catch_up_bar.value = 0.0
	_catch_up_label.text = "%s %s" % [_catch_up_verb, OfflineReport.span(seconds_away)]


## Mueve la barra. La **etiqueta solo se reescribe cuando cambia el entero del porcentaje**:
## cambiar el texto de un control obliga a rehacer el shaping, y esto se llama en cada
## fotograma. Sin emoji, por lo mismo — con emoji el shaping cuesta unos 5 ms.
func set_catch_up_progress(fraction: float, seconds_away: float) -> void:
	var percent := int(clampf(fraction, 0.0, 1.0) * 100.0)
	_catch_up_bar.value = float(percent)
	var text := "%s %s · %d %%" % [_catch_up_verb, OfflineReport.span(seconds_away), percent]
	if _catch_up_label.text != text:
		_catch_up_label.text = text


## El mundo ya está al día: la barra desaparece, el velo se levanta y el mismo panel pasa a
## contar lo que pasó. Si no hay nada que contar, el panel se cierra y no se estorba.
func end_catch_up(report: OfflineReport) -> void:
	_busy = false
	if _welcome_title.text != WELCOME_TITLE:
		_welcome_title.text = WELCOME_TITLE
	_veil.visible = false
	_catch_up_box.visible = false
	_welcome_body.visible = true
	_welcome_button.visible = true
	if report == null or not report.has_anything_to_say():
		_welcome.visible = false
		return
	show_offline(report)


# ---------------------------------------------------------------------------
# Construcción del layout
# ---------------------------------------------------------------------------

## El dock entero: pestañas arriba, contenido en medio, y abajo lo que hace falta ver desde
## cualquier pestaña.
##
## Antes esto eran dos paneles y las mejoras vivían en un tercero, flotante. Tres superficies
## compitiendo por el mismo sitio: el panel inferior crecía sin control al construirse
## edificios nuevos y en móvil vertical no cabía. En pestañas cada una tiene el alto que
## necesita y el marco no se mueve al cambiar de una a otra.
##
## Lo **global** —cuánta gente hay sin destinar, quién manda, y a qué velocidad corre el
## juego— se queda fuera de las pestañas: no pertenece a ninguna y hace falta verlo mientras
## se trabaja en cualquiera.
func _build_dock() -> PanelContainer:
	var panel := _panel()
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)

	# La cabecera común del dock: las migas van fuera de las pestañas para que se pueda subir
	# desde cualquiera de ellas, no solo desde 📊 Estado.
	box.add_child(_build_crumbs())

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.tab_alignment = TabBar.ALIGNMENT_LEFT
	box.add_child(_tabs)

	_tabs.add_child(_build_status_tab())
	_tabs.add_child(_build_jobs_tab())
	_tabs.add_child(_build_buildings_tab())
	_tabs.add_child(_build_upgrades_tab())
	_tabs.add_child(_build_legacy_tab())
	_tabs.add_child(_build_shop_tab())
	_set_tab_titles(true)

	_feed = Label.new()
	_feed.add_theme_font_size_override("font_size", 12)
	_feed.modulate = Color(1, 1, 1, 0.6)
	# Recortar, no envolver: una línea larga que se parte en tres mueve el pie del dock.
	_feed.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_feed.clip_text = true
	box.add_child(_feed)

	box.add_child(_build_global_rows())
	return panel


## Los títulos de las pestañas: **la palabra cuando cabe, el icono cuando no**.
##
## Con las dos cosas a la vez no caben cinco pestañas en un dock estrecho: `TabContainer` saca
## flechas de scroll y esconde «Estado» —la peor forma posible de perder una pestaña, y
## comprobado que pasa—. El emoji es lo que se sacrifica, porque de los dos es el que menos
## dice; solo se queda solo cuando ni las palabras entran.
##
## La flecha de promoción es la excepción, y el ⚠️ de hambruna también: esas van siempre,
## quepa lo que quepa.
func _set_tab_titles(with_text: bool) -> void:
	if _tabs == null:
		return
	_tabs_with_text = with_text
	var titles := {
		TAB_STATUS: ["📊", "Estado"],
		TAB_JOBS: ["👷", "Oficios"],
		TAB_BUILD: ["🔨", "Construir"],
		TAB_UPGRADES: ["🔬", "Mejoras"],
		TAB_LEGACY: ["🏛️", "Legado"],
		TAB_SHOP: ["🛒", "Tienda"],
	}
	for index in titles:
		var parts: Array = titles[index]
		var title := String(parts[1]) if with_text else String(parts[0])
		if index == TAB_STATUS and _promotion_ready:
			title = "⬆️ " + title
		if index == TAB_STATUS and _famine_warning:
			title = "⚠️ " + title
		_tabs.set_tab_title(index, title)


func _build_status_tab() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)

	# En dos etiquetas, no en una que se parta sola: el nombre del nodo es lo que se busca de un
	# vistazo, y la era y el ciclo son letra pequeña que no tiene por qué competir con él.
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 18)
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	box.add_child(_title)

	_subtitle = Label.new()
	_subtitle.add_theme_font_size_override("font_size", 12)
	_subtitle.modulate = Color(1, 1, 1, 0.6)
	box.add_child(_subtitle)

	_pop_bar = PopulationBar.new()
	_pop_bar.custom_minimum_size = Vector2(0, 18)
	box.add_child(_pop_bar)

	_pop_label = Label.new()
	_pop_label.add_theme_font_size_override("font_size", 13)
	_pop_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_pop_label)

	# ⚡ El boost activo del nodo: color y tamaño aquí, antes de entrar al árbol; luego solo texto.
	_boost_label = Label.new()
	_boost_label.add_theme_font_size_override("font_size", 13)
	_boost_label.modulate = OK_COLOR
	_boost_label.visible = false
	box.add_child(_boost_label)

	_resource_box = VBoxContainer.new()
	_resource_box.add_theme_constant_override("separation", 2)
	box.add_child(_resource_box)

	box.add_child(_build_promotion_row())
	box.add_child(_build_found_row())
	box.add_child(_build_children_list())
	box.add_child(_build_routes_list())
	return _scrollable(box)


## El eje vertical del juego.
##
## Mientras no se cumple el umbral enseña **cuánto falta**: en un incremental, saber a qué
## distancia está el próximo salto es la mitad del enganche. Cuando se cumple, se convierte en
## el botón más llamativo de la pestaña — y la propia pestaña se marca con una flecha, que es
## lo que evita que el momento del juego se quede escondido detrás de un clic.
##
## En columna, no en fila: el texto de lo que desbloquea la escala siguiente no cabe al lado
## de un botón en un dock estrecho.
func _build_promotion_row() -> Control:
	_promotion_box = VBoxContainer.new()
	_promotion_box.add_theme_constant_override("separation", 6)

	_promotion_label = Label.new()
	_promotion_label.add_theme_font_size_override("font_size", 13)
	_promotion_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_promotion_box.add_child(_promotion_label)

	_promotion_button = Button.new()
	_promotion_button.custom_minimum_size = Vector2(0, 44)
	_promotion_button.pressed.connect(func() -> void: promotion_requested.emit())
	_promotion_box.add_child(_promotion_button)
	return _promotion_box


## Fundar un hijo: la otra decisión que cambia *qué es* el nodo, junto a la promoción.
##
## Plazas arriba, el verbo con su coste en el botón y, cuando no se puede, **la frase de por
## qué** debajo — sacada de `Promotion.found_child_blocker`, que es la misma lista de
## condiciones que mira el gobernador. Un botón apagado sin explicación es peor que no tenerlo.
func _build_found_row() -> Control:
	_found_box = VBoxContainer.new()
	_found_box.add_theme_constant_override("separation", 4)

	_found_slots = Label.new()
	_found_slots.add_theme_font_size_override("font_size", 13)
	_found_slots.modulate = Color(1, 1, 1, 0.75)
	_found_box.add_child(_found_slots)

	_found_button = Button.new()
	_found_button.custom_minimum_size = Vector2(0, 44)
	_found_button.pressed.connect(func() -> void: found_requested.emit(false))
	_found_box.add_child(_found_button)

	# El mismo verbo, pero la colonia nace delegada. Sin él, lo fundado había que ir a delegarlo
	# entrando en ella (M4) — y lo que no se delega se queda en su granja y su leñador.
	_found_delegate_button = Button.new()
	_found_delegate_button.custom_minimum_size = Vector2(0, 44)
	# Texto y consejo los pone `_refresh_found_delegate`, con la puerta del legado y los sellos.
	_found_delegate_button.text = "🚩🎖️ Fundar y delegar"
	_found_delegate_button.pressed.connect(func() -> void: found_requested.emit(true))
	_found_box.add_child(_found_delegate_button)

	# ⏩ El sumidero del oro de una ciudad: comprar tiempo a la expedición en camino. Todo lo que
	# lleva de aspecto se pone aquí, antes del `add_child`; luego solo cambian `text`, `disabled`,
	# `visible` y `tooltip_text`, que con emoji no obligan a reconformar contra el tema.
	_accelerate_button = Button.new()
	_accelerate_button.custom_minimum_size = Vector2(0, 44)
	_accelerate_button.visible = false
	_accelerate_button.pressed.connect(func() -> void: accelerate_requested.emit())
	_found_box.add_child(_accelerate_button)

	_found_reason = Label.new()
	_found_reason.add_theme_font_size_override("font_size", 12)
	_found_reason.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_found_reason.modulate = WARN_COLOR
	_found_box.add_child(_found_reason)
	return _found_box


## Los hijos directos del nodo enfocado, uno por fila: nombre, escala y población.
##
## Es una lista de texto y tapa el agujero hasta que exista la vista agregada: sin ella, fundar
## era pulsar un botón y que no pasara nada a la vista. Aquí solo se monta el contenedor; las
## filas se crean en `_refresh_children` cuando cambia el número de hijos.
func _build_children_list() -> Control:
	_children_box = VBoxContainer.new()
	_children_box.add_theme_constant_override("separation", 0)

	_children_title = Label.new()
	_children_title.add_theme_font_size_override("font_size", 13)
	_children_title.modulate = Color(1, 1, 1, 0.75)
	_children_box.add_child(_children_title)
	return _children_box


## Una fila de la lista de hijos: un `Button` plano que **enfoca su hijo**. El ratón lo recibe
## como cualquier otro botón de la pestaña (`MOUSE_FILTER_STOP`, el de serie, igual que fundar
## y ascender); no coge el foco de teclado.
##
## El id del hijo no se fija aquí: las filas se reutilizan por posición, y cuando un hijo
## colapsa las de detrás se desplazan. `_refresh_children` lo apunta en `child_id` en cada
## refresco y se lee al pulsar.
##
## El tema se pone aquí, antes del `add_child`, y no se vuelve a tocar.
func _make_child_row() -> Button:
	var row := Button.new()
	row.flat = true
	row.alignment = HORIZONTAL_ALIGNMENT_LEFT
	row.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.focus_mode = Control.FOCUS_NONE
	row.add_theme_font_size_override("font_size", 13)
	row.set_meta("child_id", -1)
	row.pressed.connect(func() -> void:
		var id := int(row.get_meta("child_id", -1))
		if id >= 0:
			focus_requested.emit(id))
	return row


## Las rutas del nodo con sus hijos, y el formulario para crear una. Solo se ve en una región
## (o más arriba) con hijos: es la escala que tiene establos, y en una ciudad las rutas no tendrían
## con qué pagar el 🐎.
##
## **Solo desde el padre.** Desde M3 el 🐎 lo paga siempre el padre, así que es el padre quien
## decide qué rutas sostiene; listarlas también en el hijo daría dos sitios para tocar lo mismo, y
## el hijo ya enseña el efecto en sus tasas. Mismo principio que fundar: lo hace quien paga.
##
## Todo el tema se pone aquí, antes de entrar al árbol. En el refresco solo cambian `text`,
## `modulate`, `disabled` y `visible`.
func _build_routes_list() -> Control:
	_routes_box = VBoxContainer.new()
	_routes_box.add_theme_constant_override("separation", 4)
	_routes_box.visible = false

	var title := Label.new()
	title.text = "Rutas"
	title.add_theme_font_size_override("font_size", 13)
	title.modulate = Color(1, 1, 1, 0.75)
	_routes_box.add_child(title)

	_route_list = VBoxContainer.new()
	_route_list.add_theme_constant_override("separation", 6)
	_routes_box.add_child(_route_list)

	# El formulario: hijo, sentido y recurso, y el botón con el caudal con el que nace.
	_route_child = OptionButton.new()
	_route_child.add_theme_font_size_override("font_size", 13)
	_route_child.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_route_child.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_route_child.item_selected.connect(_on_route_form_changed)
	_routes_box.add_child(_route_child)

	var pick := HBoxContainer.new()
	pick.add_theme_constant_override("separation", 6)
	_routes_box.add_child(pick)

	_route_dir = OptionButton.new()
	_route_dir.add_theme_font_size_override("font_size", 13)
	_route_dir.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Fijo: el índice 0 baja al hijo y el 1 sube al padre. Lo lee `_route_form_ends`.
	_route_dir.add_item("⬇️ Enviar al hijo")
	_route_dir.add_item("⬆️ Traer del hijo")
	_route_dir.item_selected.connect(_on_route_form_changed)
	pick.add_child(_route_dir)

	_route_good = OptionButton.new()
	_route_good.add_theme_font_size_override("font_size", 13)
	_route_good.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_route_good.item_selected.connect(_on_route_form_changed)
	pick.add_child(_route_good)

	_route_create = Button.new()
	_route_create.custom_minimum_size = Vector2(0, 44)
	# Texto fijo: se pone antes de entrar al árbol y no se vuelve a tocar.
	_route_create.text = "🛣️ Crear ruta — %.1f por ciclo" % ROUTE_STEP
	_route_create.tooltip_text = (
		"Cada unidad de caudal cuesta %.1f 🐎 por ciclo a este nodo, que es el padre, tanto si "
		+ "la ruta baja como si sube. Sin 🐎 la ruta se corta."
	) % Logistics.TRANSPORT_PER_FLOW
	_route_create.pressed.connect(func() -> void:
		var ends := _route_form_ends()
		if not ends.is_empty():
			route_requested.emit(ends[0], ends[1], ends[2], ROUTE_STEP))
	_routes_box.add_child(_route_create)

	_route_reason = Label.new()
	_route_reason.add_theme_font_size_override("font_size", 12)
	_route_reason.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_route_reason.modulate = WARN_COLOR
	_routes_box.add_child(_route_reason)
	return _routes_box


## Una fila de la lista de rutas: qué va de dónde a dónde arriba; el caudal real frente al pedido
## y los botones abajo; y, si la ruta va por debajo de lo pedido, el motivo en rojo.
##
## Como las de colonias, se reutilizan por posición: la ruta que enseña cada fila se apunta en
## `route` (origen, destino, recurso y caudal pedido) en cada refresco y se lee al pulsar.
func _make_route_row() -> VBoxContainer:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	row.set_meta("route", [])

	var what := Label.new()
	what.name = "what"
	what.add_theme_font_size_override("font_size", 13)
	what.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(what)

	var line := HBoxContainer.new()
	line.name = "line"
	line.add_theme_constant_override("separation", 6)
	row.add_child(line)

	var flow := Label.new()
	flow.name = "flow"
	flow.add_theme_font_size_override("font_size", 13)
	flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	flow.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	line.add_child(flow)

	line.add_child(_route_button(row, "minus", "−", -ROUTE_STEP))
	line.add_child(_route_button(row, "plus", "+", ROUTE_STEP))
	# Borrar es lo mismo que pedir caudal cero: `set_route` con `rate <= 0` la quita.
	line.add_child(_route_button(row, "drop", "✕", 0.0))

	var why := Label.new()
	why.name = "why"
	why.add_theme_font_size_override("font_size", 12)
	why.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	why.modulate = WARN_COLOR
	why.visible = false
	row.add_child(why)
	return row


## Un botón de una fila de ruta. Con `delta` 0 borra; si no, suma `delta` al caudal pedido.
func _route_button(row: VBoxContainer, node_name: String, text: String,
		delta: float) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = text
	button.custom_minimum_size = Vector2(44, 40)  # mínimo táctil de la guía de UX
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(func() -> void:
		var r: Array = row.get_meta("route", [])
		if r.size() < 4:
			return
		var rate := 0.0 if delta == 0.0 else maxf(float(r[3]) + delta, 0.0)
		route_requested.emit(int(r[0]), int(r[1]), int(r[2]), rate))
	return button


## El pie del dock: lo que no pertenece a ninguna pestaña porque hace falta en todas.
##
## Dos filas, no una. La fila única de antes medía sus buenos 540 px —gente sin destinar,
## delegación y cinco velocidades— y vivía en un panel a ancho completo; en un dock de 384 no
## entra. Partida en dos, las velocidades se reparten el ancho a partes iguales, que de paso
## las convierte en el objetivo táctil más cómodo del HUD.
func _build_global_rows() -> Control:
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 6)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	rows.add_child(top)

	_idle_label = Label.new()
	_idle_label.add_theme_font_size_override("font_size", 14)
	_idle_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_idle_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	top.add_child(_idle_label)

	_delegate_button = Button.new()
	_delegate_button.custom_minimum_size = Vector2(0, 36)
	_delegate_button.toggle_mode = true
	_delegate_button.toggled.connect(func(on: bool) -> void: delegation_toggled.emit(on))
	top.add_child(_delegate_button)

	var speeds := HBoxContainer.new()
	speeds.add_theme_constant_override("separation", 6)
	rows.add_child(speeds)
	_speeds_row = speeds

	# Sin modo desarrollo solo ⏸ y ▶: ×2, ×4 y ×8 eran depuración. Se crean una vez y el índice
	# de cada botón sigue siendo el de `SimParams.speeds`.
	var labels: Array[String] = ["⏸", "▶", "▶▶", "▶▶▶", "▶▶▶▶"]
	for i in labels.slice(0, DevMode.max_speed_index(labels.size()) + 1):
		var b := Button.new()
		b.text = i
		b.custom_minimum_size = Vector2(44, 40)  # el mínimo táctil de la guía de UX
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_on_speed.bind(_speed_buttons.size()))
		speeds.add_child(b)
		_speed_buttons.append(b)
	return rows


func _build_jobs_tab() -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)

	column.add_child(_build_governor_panel())

	var step_row := HBoxContainer.new()
	step_row.add_theme_constant_override("separation", 8)
	var step_label := Label.new()
	step_label.text = "Mover de"
	step_label.add_theme_font_size_override("font_size", 12)
	step_label.modulate = Color(1, 1, 1, 0.6)
	step_row.add_child(step_label)
	for amount in [1, 10, 100]:
		var button := Button.new()
		button.text = str(amount)
		button.custom_minimum_size = Vector2(46, 32)
		button.pressed.connect(_on_step.bind(amount))
		step_row.add_child(button)
		_step_buttons.append(button)
	var en := Label.new()
	en.text = "en " + str(_step)
	en.visible = false
	step_row.add_child(en)
	column.add_child(step_row)

	_job_box = VBoxContainer.new()
	_job_box.add_theme_constant_override("separation", 2)
	column.add_child(_job_box)
	return _scrollable(column)


## La consola del gobernador: a qué da prioridad y qué le dejas hacer.
##
## Vive en la pestaña de oficios porque es **exactamente donde deja de haber nada que tocar** al
## delegar: los ± de cada fila se apagan y la pestaña se queda mirando. Quien viene a ver cómo
## se reparte la gente es quien quiere cambiar el porqué del reparto, así que el mando va donde
## está el resultado.
##
## Aquí sí van deslizadores, y no botones como en los oficios. La diferencia es real: un oficio
## se destina en personas y el número tiene que ser exacto; una prioridad **es** un «más o menos
## por aquí» —lo que se reparte con ella se recalcula solo en cada checkpoint—, y el control que
## dice eso es el deslizador.
func _build_governor_panel() -> Control:
	_governor_box = VBoxContainer.new()
	_governor_box.add_theme_constant_override("separation", 4)
	_governor_box.visible = false

	var title := Label.new()
	title.text = "🎖️ Prioridades"
	title.add_theme_font_size_override("font_size", 12)
	title.modulate = Color(1, 1, 1, 0.6)
	_governor_box.add_child(title)

	# El peaje, fijo bajo el título. El tema va antes de entrar al árbol; después solo cambia
	# `.text`, y solo cuando el legado mueve el número.
	_governor_toll = Label.new()
	_governor_toll.add_theme_font_size_override("font_size", 12)
	_governor_toll.modulate = Color(1, 1, 1, 0.8)
	_governor_box.add_child(_governor_toll)

	for entry in GOVERNOR_PRIORITIES:
		_governor_box.add_child(_make_priority_row(String(entry[0]), String(entry[1])))

	var leash := Label.new()
	leash.text = "Le dejas"
	leash.add_theme_font_size_override("font_size", 12)
	leash.modulate = Color(1, 1, 1, 0.6)
	_governor_box.add_child(leash)

	# Flujo, no fila: cuatro interruptores con palabra no caben en un dock de 320 px, y aquí se
	# reparten en dos filas solos.
	var permissions := HFlowContainer.new()
	permissions.add_theme_constant_override("h_separation", 4)
	permissions.add_theme_constant_override("v_separation", 2)
	_governor_box.add_child(permissions)

	for entry in GOVERNOR_PERMISSIONS:
		var field := String(entry[0])
		var check := CheckButton.new()
		check.text = String(entry[1])
		check.tooltip_text = String(entry[2])
		check.add_theme_font_size_override("font_size", 12)
		check.toggled.connect(
			func(on: bool) -> void: governor_changed.emit(field, 1.0 if on else 0.0))
		permissions.add_child(check)
		_governor_checks[field] = check

	_governor_box.add_child(_build_order_row())

	# Junto al permiso, y con el tema puesto antes de entrar al árbol: después solo cambia
	# `visible`. El permiso puede estar encendido y no servir de nada, y sin esta frase parece un
	# fallo del gobernador.
	_heirs_note = Label.new()
	_heirs_note.text = "🌱 Esta colonia no fundará otras: sube 👑 Dinastía en el legado"
	_heirs_note.add_theme_font_size_override("font_size", 11)
	_heirs_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_heirs_note.modulate = Color(1, 1, 1, 0.7)
	_heirs_note.visible = false
	_governor_box.add_child(_heirs_note)

	var rule := HSeparator.new()
	_governor_box.add_child(rule)
	return _governor_box


## Las órdenes, bajo los permisos: una intención **de ahora** encima de las prioridades de
## siempre.
##
## Botones y no casillas, porque se excluyen entre sí: el mismo criterio que separó los
## deslizadores de oficio de los ±. Un `ButtonGroup` con `allow_unpress` ya dice eso solo
## —pulsar otra cambia, pulsar la activa la quita—, y lo que llega al motor es el resultado,
## no cada botón que se suelta. El tema va antes del `add_child`; después solo cambian
## `button_pressed` y `.text`, que son los baratos (ver `tools/spike_probe.gd`).
func _build_order_row() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)

	var heading := Label.new()
	heading.text = "Orden"
	heading.add_theme_font_size_override("font_size", 12)
	heading.modulate = Color(1, 1, 1, 0.6)
	box.add_child(heading)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	box.add_child(row)

	var group := ButtonGroup.new()
	group.allow_unpress = true
	for entry in GOVERNOR_ORDERS:
		var ordinal := int(entry[0])
		var button := Button.new()
		button.text = String(entry[1])
		button.tooltip_text = String(entry[2])
		button.toggle_mode = true
		button.button_group = group
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.add_theme_font_size_override("font_size", 12)
		# Tras el clic el grupo ya ha resuelto: si este quedó pulsado es la orden nueva, y si
		# no, era la activa y se ha quitado.
		button.pressed.connect(func() -> void:
			governor_changed.emit("order",
				float(ordinal if button.button_pressed else Governor.Order.NONE)))
		row.add_child(button)
		_order_buttons.append(button)

	_order_note = Label.new()
	_order_note.add_theme_font_size_override("font_size", 11)
	_order_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_order_note.modulate = Color(1, 1, 1, 0.8)
	_order_note.visible = false
	box.add_child(_order_note)
	return box


## Qué hace el gobernador por culpa de la orden, en una frase. Dice lo que hace **de verdad**,
## estancamientos incluidos: una orden que parece no hacer nada es peor que no tenerla.
static func _order_text(order: int, may_expand: bool) -> String:
	match order:
		Governor.Order.STOCKPILE:
			return "📦 Acumulando: solo gasta lo que desborda el almacén; si no se llena, " \
				+ "no construye casas ni granjas"
		Governor.Order.EXPAND:
			if not may_expand:
				# Los permisos mandan sobre las órdenes: sin colonizar, expandir es solo crecer.
				return "🧭 Expandiendo: prioriza las casas, pero no funda: no le dejas colonizar"
			return "🧭 Expandiendo: funda al 60 % del techo y prioriza las casas"
		Governor.Order.SPECIALIZE:
			return "🎯 Especializando: concentra la gente en tu prioridad más alta"
	return ""


func _make_priority_row(field: String, label_text: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var label := Label.new()
	label.text = label_text
	label.add_theme_font_size_override("font_size", 12)
	label.custom_minimum_size = Vector2(104, 0)
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(label)

	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.05
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(0, 24)
	slider.value_changed.connect(
		func(value: float) -> void: governor_changed.emit(field, value))
	row.add_child(slider)
	_governor_sliders[field] = slider

	# El porcentaje **ya normalizado**, que es el que se aplica de verdad: los cuatro pesos
	# crudos no suman 1, así que enseñarlos tal cual sería enseñar un número que el gobernador
	# no usa.
	var share := Label.new()
	share.add_theme_font_size_override("font_size", 12)
	share.custom_minimum_size = Vector2(40, 0)
	share.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	share.modulate = Color(1, 1, 1, 0.7)
	row.add_child(share)
	_governor_shares[field] = share
	return row


func _build_buildings_tab() -> Control:
	# Flujo, no fila: con ocho edificios en Ciudad una fila se sale de la pantalla en móvil.
	_build_box = HFlowContainer.new()
	_build_box.add_theme_constant_override("h_separation", 6)
	_build_box.add_theme_constant_override("v_separation", 6)
	return _scrollable(_build_box)


## El árbol de mejoras del nodo, entero: lo comprado, lo que está a tiro y lo que aún no.
##
## Antes era una rejilla con **solo la frontera** —las mejoras cuyos requisitos ya estaban
## cumplidos—, y eso convertía la progresión en botones que aparecían y desaparecían sin decir
## de dónde salían. Saber qué viene después es la mitad del enganche de un incremental, y para
## saberlo hay que ver la forma, no la siguiente casilla.
func _build_upgrades_tab() -> Control:
	_upgrade_tree = UpgradeTreeView.new()
	_upgrade_tree.item_pressed.connect(func(id: String) -> void: upgrade_requested.emit(id))
	return _scrollable(_upgrade_tree)


## El árbol de legado y el botón de ascender, que es lo que lo alimenta.
##
## Van juntos a propósito: el legado no se gana jugando, se gana **dejando atrás la partida**, y
## una pestaña que enseñara nodos que comprar sin decir de dónde sale la moneda sería un
## escaparate sin puerta.
func _build_legacy_tab() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)

	_legacy_title = Label.new()
	_legacy_title.add_theme_font_size_override("font_size", 18)
	box.add_child(_legacy_title)

	_legacy_subtitle = Label.new()
	_legacy_subtitle.add_theme_font_size_override("font_size", 12)
	_legacy_subtitle.modulate = Color(1, 1, 1, 0.6)
	box.add_child(_legacy_subtitle)

	_ascension_box = VBoxContainer.new()
	_ascension_box.add_theme_constant_override("separation", 6)
	box.add_child(_ascension_box)

	_ascension_label = Label.new()
	_ascension_label.add_theme_font_size_override("font_size", 13)
	_ascension_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ascension_box.add_child(_ascension_label)

	_ascension_button = Button.new()
	_ascension_button.custom_minimum_size = Vector2(0, 44)
	_ascension_button.pressed.connect(_on_ascension_pressed)
	_ascension_box.add_child(_ascension_button)

	_legacy_tree = UpgradeTreeView.new()
	_legacy_tree.item_pressed.connect(func(id: String) -> void: legacy_requested.emit(id))
	box.add_child(_legacy_tree)
	return _scrollable(box)


## 🛒 La tienda: arriba el goteo y con qué se paga, debajo una fila por objeto.
##
## Cada fila: icono, nombre y cuántos tienes; «Comprar 🪙», «Comprar 📜», «Usar aquí» y, para un
## ⚡, «Usar en todos (N)». Un botón apagado lleva su motivo en el consejo, como «Fundar», y los
## motivos de la fila se leen también debajo, en rojo: en móvil no hay consejo que valga.
##
## **Todo se crea aquí y una sola vez**, con el tema puesto antes del `add_child`: los botones
## llevan emoji, y tocarles el tema ya en el árbol cuesta ~6 ms cada uno. El refresco solo cambia
## `text`, `disabled`, `tooltip_text` y `visible`. Los precios no cambian: su texto es fijo.
func _build_shop_tab() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)

	_shop_drip = Label.new()
	_shop_drip.add_theme_font_size_override("font_size", 14)
	_shop_drip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_shop_drip)

	_shop_pay = Label.new()
	_shop_pay.add_theme_font_size_override("font_size", 13)
	_shop_pay.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_shop_pay.modulate = Color(1, 1, 1, 0.75)
	box.add_child(_shop_pay)

	# El coste escondido de la cultura, dicho antes de pagar: es la raíz de la 🎭 influencia.
	var warning := Label.new()
	warning.add_theme_font_size_override("font_size", 12)
	warning.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	warning.modulate = Color(1, 1, 1, 0.6)
	warning.text = ("Pagar con 📜 baja la 🎭 influencia, que es la puerta de Región. Lo comprado "
		+ "es de la partida, no del nodo, y sobrevive a la ascensión.")
	box.add_child(warning)

	for d in Items.all():
		box.add_child(HSeparator.new())
		box.add_child(_make_shop_row(d))
	return _scrollable(box)


func _make_shop_row(d: Items.Def) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 4)

	var header := Label.new()
	header.add_theme_font_size_override("font_size", 15)
	header.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(header)

	var about := Label.new()
	about.add_theme_font_size_override("font_size", 12)
	about.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	about.modulate = Color(1, 1, 1, 0.6)
	about.text = d.description
	row.add_child(about)

	var buttons := HFlowContainer.new()
	buttons.add_theme_constant_override("h_separation", 6)
	buttons.add_theme_constant_override("v_separation", 6)
	row.add_child(buttons)

	var gold := _shop_button(buttons, "Comprar · %s 🪙" % _short(d.price[Goods.GOLD]))
	gold.pressed.connect(func() -> void: item_buy_requested.emit(d.id, Goods.GOLD))
	var culture := _shop_button(buttons, "Comprar · %s 📜" % _short(d.price[Goods.CULTURE]))
	culture.pressed.connect(func() -> void: item_buy_requested.emit(d.id, Goods.CULTURE))
	# Un ⌛ es del mundo entero: no hay «aquí» ni «en todos», solo «Usar».
	var use := _shop_button(buttons, "Usar" if d.kind == Items.Kind.SKIP else "Usar aquí")
	use.pressed.connect(func() -> void: item_use_requested.emit(d.id, false))
	var all := _shop_button(buttons, "Usar en todos")
	all.visible = d.kind == Items.Kind.BOOST
	all.pressed.connect(func() -> void: item_use_requested.emit(d.id, true))

	var reason := Label.new()
	reason.add_theme_font_size_override("font_size", 12)
	reason.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	reason.modulate = WARN_COLOR
	row.add_child(reason)

	_shop_rows.append({
		"id": d.id, "header": header, "gold": gold, "culture": culture, "use": use, "all": all,
		"reason": reason,
	})
	return row


func _shop_button(parent: Control, text: String) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, 40)
	b.text = text
	parent.add_child(b)
	return b


static func _scrollable(content: Control) -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(content)
	return scroll


func _refresh_upgrades(node: SimNode) -> void:
	var tree := Upgrading.tree_for(node)
	# Sin mejoras a la vista, la pestaña desaparece en vez de quedarse vacía.
	_tabs.set_tab_hidden(TAB_UPGRADES, tree.is_empty())

	var items := []
	for def in tree:
		var d: Upgrades.Def = def
		var state := Upgrading.state_of(node, d.id)
		items.append(UpgradeTreeView.Item.make(
			d.id, d.icon, d.name, _cost_of(d.cost), d.describe(), d.requires,
			TREE_STATE[state],
			not node.is_delegated() and Upgrading.can_buy(node, d.id),
			Content.tier(d.tier_min).name))
	_upgrade_tree.set_items(items)


## El árbol de legado y el estado del prestigio.
##
## La pestaña **no existe** hasta que hay algo que hacer en ella: sin legado, sin nodos
## comprados y sin poder ascender, una pestaña con ocho nodos apagados y cero de moneda solo
## enseña una parte del juego que todavía no ha empezado.
func _refresh_legacy(state: WorldState) -> void:
	var reward := Ascension.reward(state)
	var ready := Ascension.can_ascend(state)
	var idle := state.legacy <= 0.0 and state.legacy_nodes.is_empty() and not ready
	_tabs.set_tab_hidden(TAB_LEGACY, idle)
	if idle:
		return

	_legacy_title.text = "🏛️ %s de legado" % _short(state.legacy)
	_legacy_subtitle.text = "era %d · cúspide %s hab · %s" % [
		state.era, _short(state.peak_pop), Content.tier(state.peak_tier).name,
	]

	# Igual que la promoción: mientras no toca, lo que se enseña es **cuánto falta**.
	_ascension_button.visible = ready
	if ready:
		_ascension_button.text = "⭐  Ascender  →  +%d 🏛️" % int(reward)
		_ascension_label.text = "Dejas atrás este mundo. Te llevas el legado y lo comprado con él."
		_ascension_label.modulate = OK_COLOR
		# El texto del modal se compone aquí, con el estado a mano, y no cuando se pulsa: el
		# HUD no guarda una referencia al mundo, y guardarla solo para esto sería abrir una
		# puerta trasera al estado desde la vista.
		# El desglose sale de las mismas dos funciones que suma `reward`: el total cuadra siempre.
		_ascension_warning = ("Ganas %d 🏛️ de legado (%d por población · %d por cultura) y empieza la era %d.\n\n"
			+ "Se pierden el asentamiento, sus edificios, su gente y todo lo almacenado. "
			+ "El árbol de legado se conserva entero.") % [int(reward),
				int(Ascension.pop_reward(state)), int(Ascension.culture_reward(state)), state.era + 1]
	else:
		_ascension_label.text = "⭐ Para ascender: %s hab de cúspide" % _progress(
			state.peak_pop, Ascension.MIN_PEAK_POP)
		_ascension_label.modulate = Color(1, 1, 1, 0.75)

	var ranks := Ascension.ranks(state)
	var items := []
	for node_def in Legacy.nodes():
		var d: Legacy.Node_ = node_def
		var rank := int(ranks.get(d.id, 0))
		var state_of := UpgradeTreeView.State.AVAILABLE
		if rank >= d.max_ranks:
			state_of = UpgradeTreeView.State.OWNED
		elif not Ascension.is_unlocked(state, d.id):
			state_of = UpgradeTreeView.State.LOCKED
		var sublabel := _pips(rank, d.max_ranks)
		if rank < d.max_ranks:
			sublabel = "%s 🏛️ %s" % [_short(d.cost_for(rank)), sublabel]
		items.append(UpgradeTreeView.Item.make(
			d.id, d.icon, d.name, sublabel, d.description, d.requires,
			state_of, Ascension.can_buy(state, d.id)))
	_legacy_tree.set_items(items)


## 🛒 La tienda contra el estado de ahora. Cada motivo sale de `Shop.buy_blocker` y
## `Shop.use_blocker`, las mismas listas que vuelven a mirar `Shop.buy`, `Shop.use_boost` y
## `SimEngine.use_skip` antes de hacer nada. Se ve siempre, también antes de Ciudad: con los
## botones apagados y diciendo por qué, la tienda enseña qué hará el oro cuando llegue.
func _refresh_shop(node: SimNode, state: WorldState, params: SimParams) -> void:
	_set_text(_shop_drip, _drip_text(state, params))
	var pay: String
	if node.tier < Content.CITY:
		pay = "🪙 y 📜 salen del Mercado y el Templo: hasta Ciudad no hay con qué pagar."
	else:
		pay = "Pagas con el almacén de %s: %s 🪙 · %s 📜" % [
			node.name, _short(node.stocks[Goods.GOLD]), _short(node.stocks[Goods.CULTURE]),
		]
	_set_text(_shop_pay, pay)

	var subtree := Shop.targets(state, node, true).size()
	for row in _shop_rows:
		var id: String = row["id"]
		var d := Items.get_def(id)
		_set_text(row["header"], "%s %s · tienes %d" % [d.icon, d.name, Shop.count_of(state, id)])
		var reasons := PackedStringArray()
		for pair in [[row["gold"], Goods.GOLD], [row["culture"], Goods.CULTURE]]:
			var blocker := Shop.buy_blocker(state, node, id, pair[1])
			_shop_gate(pair[0], blocker, "Comprar uno con %s del almacén de %s" % [
				Goods.ICONS[pair[1]], node.name])
			if not blocker.is_empty() and not reasons.has(blocker):
				reasons.append(blocker)
		var use_blocker := Shop.use_blocker(state, node, id, false, _busy)
		var use_hint := ("El mundo entero avanza %s" % OfflineReport.span(
			d.cycles * params.seconds_per_cycle)) if d.kind == Items.Kind.SKIP \
			else ("×%d durante %d ciclos en %s" % [int(d.factor), int(d.cycles), node.name])
		_shop_gate(row["use"], use_blocker, use_hint)
		if not use_blocker.is_empty():
			reasons.append("usar: " + use_blocker)
		var all: Button = row["all"]
		if all.visible:
			_set_text(all, "Usar en todos (%d)" % subtree)
			var all_blocker := Shop.use_blocker(state, node, id, true, _busy)
			_shop_gate(all, all_blocker,
				"Uno por nodo: %s y todo lo que cuelga de él, %d nodos" % [node.name, subtree])
			if not all_blocker.is_empty() and all_blocker != use_blocker:
				reasons.append("en todos: " + all_blocker)
		_set_text(row["reason"], " · ".join(reasons))
		row["reason"].visible = not reasons.is_empty()


## «⌛ siguiente en 34 min · 2/3 en reserva». Lleno, el reloj sigue corriendo y lo que caería se
## pierde (`Shop.drip`): se dice, para que la reserva llena invite a usarla.
static func _drip_text(state: WorldState, params: SimParams) -> String:
	if params.drip_interval <= 0.0:
		return ""
	var held := "%d/%d en reserva" % [state.drip_held, params.drip_cap]
	if state.drip_held >= params.drip_cap:
		return "⌛ reserva llena (%s): usa uno para que vuelva a caer" % held
	var left := maxf(params.drip_interval - (state.cycle - state.drip_cycle), 0.0)
	return "⌛ siguiente en %s · %s" % [OfflineReport.span(left * params.seconds_per_cycle), held]


## Apaga o enciende un botón de la tienda: el motivo de `*_blocker` en el consejo si está
## apagado, lo que hace si no.
static func _shop_gate(button: Button, blocker: String, hint: String) -> void:
	_set_disabled(button, not blocker.is_empty())
	var tip := hint if blocker.is_empty() else blocker
	if button.tooltip_text != tip:
		button.tooltip_text = tip


## ⚡ en 📊 Estado: el boost del nodo enfocado y cuánto le queda, en ciclos globales.
func _refresh_boost(node: SimNode, state: WorldState) -> void:
	var on := node.boost_factor > 1.0 and node.boost_until > state.cycle
	if _boost_label.visible != on:
		_boost_label.visible = on
	if on:
		_set_text(_boost_label, "⚡ ×%d · quedan %d ciclos" % [
			int(node.boost_factor), int(ceilf(node.boost_until - state.cycle))])


## Cambiar el texto de un control rehace su shaping, y con emoji cuesta: solo si cambia.
static func _set_text(control: Control, text: String) -> void:
	if control.get("text") != text:
		control.set("text", text)


## Los rangos, de un vistazo. Un «3/5» obliga a leer dos números y compararlos; los puntos se
## ven sin leerlos —hasta que son tantos que ya no caben en el nodo junto al coste, y entonces
## el número vuelve a ser lo legible.
static func _pips(rank: int, max_ranks: int) -> String:
	if max_ranks > 5:
		return "%d/%d" % [rank, max_ranks]
	return "●".repeat(rank) + "○".repeat(maxi(max_ranks - rank, 0))


static func _cost_of(cost: PackedFloat64Array) -> String:
	var parts := PackedStringArray()
	for i in Goods.COUNT:
		if cost[i] > 0.0:
			parts.append("%.0f %s" % [cost[i], Goods.ICONS[i]])
	return " ".join(parts)


func _on_step(amount: int) -> void:
	_step = amount
	for i in _step_buttons.size():
		_step_buttons[i].disabled = _step_buttons[i].text == str(amount)


## El marco del dock. **Opaco**: tapa mundo en vez de velarlo. Translúcido, el terreno de
## debajo se cuela entre los números y no se lee ni una cosa ni la otra.
##
## Las esquinas las redondea [method _layout] por el lado que da al mundo — el dock va a ras
## del borde de la ventana, así que redondearlas todas dejaría cuatro muescas de terreno en
## las esquinas de la pantalla.
func _panel() -> PanelContainer:
	var panel := PanelContainer.new()
	_dock_style = StyleBoxFlat.new()
	_dock_style.bg_color = Color(0.07, 0.09, 0.09, 0.96)
	for side in ["left", "top", "right", "bottom"]:
		_dock_style.set("content_margin_" + side, 12)
	panel.add_theme_stylebox_override("panel", _dock_style)
	return panel


# ---------------------------------------------------------------------------
# Refresco
# ---------------------------------------------------------------------------

func refresh(node: SimNode, state: WorldState, params: SimParams, snap: Integrator.Snapshot,
		speed_index: int, crowd_size: int, represents: float) -> void:
	_title.text = "%s — %s" % [node.name, node.def().name]
	_refresh_crumbs(node, state)
	_subtitle.text = "era %d · ciclo %d" % [state.era, int(state.cycle)]

	_pop_bar.pop = node.pop
	_pop_bar.housing = snap.housing
	_pop_bar.food_capacity = snap.food_capacity
	_pop_bar.queue_redraw()

	var limit := "alojamiento" if not snap.food_limited else "comida"
	var crowd_note := ""
	if crowd_size > 0 and represents > 1.01:
		crowd_note = " · %d puntos × %.1f hab" % [crowd_size, represents]
	_pop_label.text = "👥 %.1f de %.1f — limitado por %s%s" % [
		node.pop, snap.cap, limit, crowd_note,
	]
	_pop_label.modulate = WARN_COLOR if snap.starving else Color.WHITE
	_mark_famine(node.starving and node.is_delegated())

	_refresh_resources(node, params, snap)
	_refresh_promotion(node, state)
	_governor_efficiency = SimEngine.governor_efficiency_for(state, params)
	_refresh_found(node, state, params)
	_refresh_children(node, state)
	_refresh_routes(node, state, params)
	_refresh_upgrades(node)
	_refresh_legacy(state)
	_refresh_shop(node, state, params)
	_refresh_boost(node, state)
	_refresh_jobs(node, params, state)
	_refresh_heirs_note(node, state)
	_refresh_builds(node)
	for i in _speed_buttons.size():
		_speed_buttons[i].disabled = i == speed_index
	if _step_buttons.size() == 3 and not _step_buttons[0].disabled \
			and not _step_buttons[1].disabled and not _step_buttons[2].disabled:
		_on_step(_step)  # marcar el paso activo la primera vez


func _refresh_resources(node: SimNode, params: SimParams, snap: Integrator.Snapshot) -> void:
	var caps := node.storage_caps(params)
	var visible := Content.goods_for_tier(node.tier)
	for i in Goods.COUNT:
		var show := visible.has(i) or node.stocks[i] > 0.0
		if not _resource_rows.has(i):
			if not show:
				continue
			var label := Label.new()
			label.add_theme_font_size_override("font_size", 14)
			_resource_box.add_child(label)
			_resource_rows[i] = label
		var row: Label = _resource_rows[i]
		row.visible = show
		if not show:
			continue
		var cap_text := "∞" if caps[i] == INF else "%.0f" % caps[i]
		var rate := snap.rates[i]
		row.text = "%s %s %.1f / %s   %+.2f/ciclo" % [
			Goods.ICONS[i], Goods.NAMES[i], node.stocks[i], cap_text, rate,
		]
		row.modulate = Color.WHITE if rate >= 0.0 else WARN_COLOR


func _refresh_promotion(node: SimNode, state: WorldState) -> void:
	var tier_def := node.def()
	if tier_def.promote_pop <= 0.0:
		_promotion_box.visible = false
		_mark_promotion_ready(false)
		return
	_promotion_box.visible = true

	var next_name := Content.tier(node.tier + 1).name
	var ready := Promotion.can_promote(state, node)
	_promotion_button.visible = ready
	_mark_promotion_ready(ready)
	if ready:
		_promotion_button.text = "⬆️  Ascender a %s" % next_name
		_promotion_label.text = Content.tier(node.tier + 1).unlocks
		_promotion_label.modulate = OK_COLOR
		return

	# La escala siguiente aún no tiene nada que jugar. No se oculta: es lo que cuenta hacia dónde
	# va el juego. Va antes que el techo y que el progreso para no prometer un ascenso que no
	# llega, cumpla o no el umbral; el botón ya está oculto porque `can_promote` es falso.
	if not Promotion.next_tier_playable(node):
		_promotion_label.text = "🗺️ %s — próximamente\n%s" % [
			next_name, Content.tier(node.tier + 1).unlocks,
		]
		_promotion_label.modulate = Color(1, 1, 1, 0.75)
		return

	# Bloqueado por el techo de anidamiento: cumple el umbral, hijos incluidos, pero su padre no
	# da más de sí.
	var grown := Promotion.grown_children(state, node)
	# 🎭 La influencia se calcula al vuelo (`WorldState.influence_of`); solo se mira si la escala
	# la pide, para no recorrer el subárbol en cada refresco de un pueblo.
	var influence := state.influence_of(node) if tier_def.promote_influence > 0.0 else 0.0
	if tier_def.can_promote(node.total_pop, node.building_total()) \
			and grown >= tier_def.promote_children \
			and influence >= tier_def.promote_influence:
		_promotion_label.text = "⛔ %s no puede pasar de %s estando bajo su capital" % [
			node.name, tier_def.name,
		]
		_promotion_label.modulate = WARN_COLOR
		return

	var text := "⬆️ %s: %s hab · %d/%d edificios" % [
		next_name,
		_progress(node.total_pop, tier_def.promote_pop),
		node.building_total(), tier_def.promote_buildings,
	]
	# Los hijos que cuentan son los de la escala justo por debajo (`Promotion.grown_children`):
	# una ciudad necesita pueblos, y aquí se dice cuántos faltan.
	if tier_def.promote_children > 0:
		var child_tier := Content.tier(node.tier - 1)
		var noun := child_tier.name_plural if tier_def.promote_children != 1 else child_tier.name
		text += " · %d/%d %s" % [grown, tier_def.promote_children, noun.to_lower()]
		if grown < tier_def.promote_children:
			text += " (faltan %d)" % (tier_def.promote_children - grown)
	# 🎭 La puerta de Región, con el mismo patrón que los hijos. Solo cambia `text`: nada de tema.
	if tier_def.promote_influence > 0.0:
		text += " · 🎭 %.0f/%.0f influencia" % [floorf(influence), tier_def.promote_influence]
		if influence < tier_def.promote_influence:
			text += " (faltan %.0f)" % ceilf(tier_def.promote_influence - influence)
	_promotion_label.text = text
	_promotion_label.modulate = Color(1, 1, 1, 0.75)


## La fila de fundar. Solo cambia `text`, `disabled`, `visible` y `modulate`: nada de tema
## sobre controles que ya están en el árbol.
##
## Un asentamiento no tiene escala hija, y ahí la fila **se oculta entera**: enseñar «un
## asentamiento no puede tener hijos» en rojo lo haría parecer algo por arreglar.
func _refresh_found(node: SimNode, state: WorldState, params: SimParams) -> void:
	if node.tier - 1 < Content.SETTLEMENT:
		_found_box.visible = false
		return
	_found_box.visible = true

	var child_name := Content.tier(node.tier - 1).name
	var settlers := Promotion.settler_pop(params)
	var food := Promotion.settler_food(params)
	# La expedición en camino ocupa su plaza (`Promotion.free_slots`): se cuenta aparte para que
	# «2 / 4» no parezca que quedan dos libres.
	var slots := "%d / %d hijos" % [node.children.size(), node.def().child_slots]
	if state.expedition_of(node.id) != null:
		slots += " · 1 en camino"
	_found_slots.text = slots
	# La duración es la de la **próxima** expedición, que se fija al salir: lo que tardaría si se
	# pulsa ahora. Con una en camino no se enseña: el botón está apagado, la cuenta atrás va en el
	# motivo, y la que saldría después ya no tarda eso (llegar suma un hijo y la alarga). El nombre
	# de la escala hija va en el consejo: con la duración, el botón ya no cabe en el panel.
	var trip := Promotion.expedition_cycles(state, node, params) * params.seconds_per_cycle
	if state.expedition_of(node.id) != null:
		_found_button.text = "🚩 Fundar — %.0f 👤 · %.0f 🌾" % [settlers, food]
	else:
		_found_button.text = "🚩 Fundar (%s) — %.0f 👤 · %.0f 🌾" % [
			OfflineReport.span(trip), settlers, food,
		]
	# Que no parezca que el juego regala edificios: la granja y el leñador son el equipaje de
	# la fundación, y lo que se paga sale del núcleo.
	_found_button.tooltip_text = (
		"Fundar un %s se lleva %.0f colonos y %.0f 🌾 del núcleo, que salen ya y tardan %s en "
		+ "llegar. La colonia nace al llegar, con una granja y un leñador para no morirse de "
		+ "hambre: van incluidos en la fundación, no son un regalo aparte. Cada hijo alarga la "
		+ "siguiente expedición."
	) % [child_name.to_lower(), settlers, food, OfflineReport.span(trip)]

	var blocker := Promotion.found_child_blocker(state, node, params)
	if blocker.is_empty() and node.is_delegated():
		blocker = "lo lleva su gobernador: recupera el mando (🖐️) para fundar a mano"
	# Los dos botones con el mismo blocker: fundar y delegar cuesta lo mismo que fundar. El de
	# delegar suma la puerta del legado (`delegate_blocker`, su primer paso: el sello no se le
	# pide, porque sin sellos funda a mano y lo dice antes de pulsar). Solo `text`, `disabled` y
	# `tooltip_text`: está en el árbol y lleva emoji.
	_set_disabled(_found_button, not blocker.is_empty())
	_refresh_found_delegate(node, state, blocker)
	_found_reason.visible = not blocker.is_empty()
	_found_reason.text = blocker
	_refresh_accelerate(node, state, params)


## «🚩🎖️ Fundar y delegar» con su motivo (`Shop.found_and_delegate`). Sin 🎖️ Consejo sale 🔒 y
## apagado; con Consejo y sin sellos funda igual, pero la colonia nace a mano, y se dice antes.
func _refresh_found_delegate(node: SimNode, state: WorldState, found_blocker: String) -> void:
	var open := Ascension.governor_open(state)
	var sealed := Shop.count_of(state, "seal") >= 1
	_set_disabled(_found_delegate_button, not found_blocker.is_empty() or not open)
	if not open:
		_found_delegate_button.text = "🚩🎖️ Fundar y delegar · 🔒 legado"
		_found_delegate_button.tooltip_text = GovernorSys.delegate_blocker(state, node)
	elif not sealed:
		_found_delegate_button.text = "🚩🎖️ Fundar y delegar · sin 🎖️: nacerá a mano"
		_found_delegate_button.tooltip_text = (
			"No te queda ningún 🎖️ Sello: funda igual, con el mismo coste, pero la colonia nace a "
			+ "mano. Séllala después desde 🛒 y quedará delegada."
		)
	else:
		_found_delegate_button.text = "🚩🎖️ Fundar y delegar"
		_found_delegate_button.tooltip_text = (
			"Funda igual, con el mismo coste, y gasta un 🎖️ Sello al salir: la colonia nace "
			+ "sellada y en manos de un gobernador equilibrado. Para llevarla a mano, entra en "
			+ "ella y pulsa 🖐️."
		)
	if not found_blocker.is_empty():
		_found_delegate_button.tooltip_text = found_blocker


## ⏩ El botón de acelerar: solo con una expedición en camino y desde Ciudad, que es donde hay oro
## para esto. El precio es el de la **siguiente** aceleración, y el motivo de que esté apagado sale
## de `Promotion.accelerate_blocker`, la misma lista que mira `accelerate_expedition`. A un pueblo
## no se le enseña: el botón apagado diciendo «solo una ciudad» lo haría parecer algo por arreglar.
func _refresh_accelerate(node: SimNode, state: WorldState, params: SimParams) -> void:
	var shown := node.tier >= Content.CITY and state.expedition_of(node.id) != null
	if _accelerate_button.visible != shown:
		_accelerate_button.visible = shown
	if not shown:
		return
	var pct := params.accelerate_fraction * 100.0
	_accelerate_button.text = "⏩ Acelerar −%.0f %% · %s 🪙" % [
		pct, _short(ceilf(Promotion.accelerate_cost(state, node, params))),
	]
	var blocker := Promotion.accelerate_blocker(state, node, params)
	# Como fundar: un nodo delegado no se toca a mano (regla 3). El gobernador no acelera nunca, así
	# que mientras lo lleve él el oro se queda para sus mejoras.
	if blocker.is_empty() and node.is_delegated():
		blocker = "lo lleva su gobernador: recupera el mando (🖐️) para acelerar a mano"
	_set_disabled(_accelerate_button, not blocker.is_empty())
	if blocker.is_empty():
		_accelerate_button.tooltip_text = (
			"Recorta el %.0f %% de lo que le queda de viaje a la expedición. Cada aceleración "
			+ "cuesta ×%.1f la anterior."
		) % [pct, params.accelerate_growth]
	else:
		_accelerate_button.tooltip_text = blocker


## Rellena la lista de hijos. Las filas solo se crean o se liberan cuando cambia **cuántos**
## hijos vivos hay; en un ciclo normal solo se reasigna su `text`, que si no ha cambiado no
## cuesta nada.
##
## La población es `total_pop`, la del subárbol del hijo: hoy un hijo de pueblo es un
## asentamiento y da igual, pero una región que lista sus pueblos debe contar sus colonias,
## que es la cifra que cuenta para el umbral de promoción. Un hijo que ha colapsado puede
## no existir ya: se salta.
func _refresh_children(node: SimNode, state: WorldState) -> void:
	var alive: Array[SimNode] = []
	for id in node.children:
		var child := state.get_node_by_id(id)
		if child != null:
			alive.append(child)
	_children_box.visible = not alive.is_empty()
	if alive.is_empty():
		return

	while _children_rows.size() < alive.size():
		var row := _make_child_row()
		_children_box.add_child(row)
		_children_rows.append(row)
	while _children_rows.size() > alive.size():
		var extra: Button = _children_rows.pop_back()
		extra.queue_free()

	_children_title.text = "Colonias"
	for i in alive.size():
		var child := alive[i]
		# 🎖️ si está sellada, delegada o no: retomarle el mando no le quita el sello.
		_children_rows[i].text = "🏘️ %s — %s · %s 👥%s" % [
			child.name, Content.tier(child.tier).name.to_lower(), _short(child.total_pop),
			" · 🎖️" if child.governor_unlocked else "",
		]
		_children_rows[i].set_meta("child_id", child.id)


## La lista de rutas y el formulario. Las filas se crean o se liberan solo cuando cambia
## **cuántas** rutas hay, y los desplegables solo se rehacen cuando cambian los hijos o la escala.
##
## El caudal real (`Route.flow`) va a golpes entre checkpoints: una ruta cortada se queda a cero
## hasta el siguiente reparto. Por eso el rojo va por `modulate` y solo se toca cuando cambia, y
## el texto se reasigna igual que siempre, que si no ha cambiado no cuesta nada.
func _refresh_routes(node: SimNode, state: WorldState, params: SimParams) -> void:
	_route_node = node
	_route_state = state
	var kids: Array[SimNode] = []
	if node.tier >= Content.REGION:
		for id in node.children:
			var child := state.get_node_by_id(id)
			if child != null:
				kids.append(child)
	var shown := not kids.is_empty()
	if _routes_box.visible != shown:
		_routes_box.visible = shown
	if not shown:
		return

	# Las rutas que paga este nodo: las suyas con sus hijos, en orden de id.
	var mine: Array[Route] = []
	for r in state.routes:
		if r.touches(node.id) and Logistics.payer_of(state, r) == node.id:
			mine.append(r)
	while _route_rows.size() < mine.size():
		var row := _make_route_row()
		_route_list.add_child(row)
		_route_rows.append(row)
	while _route_rows.size() > mine.size():
		var extra: VBoxContainer = _route_rows.pop_back()
		extra.queue_free()

	var delegated := node.is_delegated()
	for i in mine.size():
		var r := mine[i]
		var row := _route_rows[i]
		row.set_meta("route", [r.from_id, r.to_id, r.good, r.rate])
		var from := state.get_node_by_id(r.from_id)
		var to := state.get_node_by_id(r.to_id)
		(row.get_node("what") as Label).text = "%s › %s · %s %s" % [
			from.name if from != null else "?", to.name if to != null else "?",
			Goods.ICONS[r.good], Goods.NAMES[r.good],
		]
		var flow := row.get_node("line/flow") as Label
		flow.text = "%.1f de %.1f %s/ciclo" % [r.flow, r.rate, Goods.ICONS[r.good]]
		var short := r.flow < r.rate
		var tint := WARN_COLOR if short else Color.WHITE
		if flow.modulate != tint:
			flow.modulate = tint
		var why := row.get_node("why") as Label
		var reason := Logistics.cut_reason(state, params, r) if short else ""
		why.text = reason
		if why.visible != short:
			why.visible = short
		_set_disabled(row.get_node("line/minus") as Button, delegated or r.rate <= ROUTE_STEP)
		_set_disabled(row.get_node("line/plus") as Button, delegated)
		_set_disabled(row.get_node("line/drop") as Button, delegated)

	_refresh_route_options(node, kids)
	_refresh_route_form()


## Rehace los desplegables de hijo y recurso **solo si han cambiado**: el de hijos cuando nace o
## colapsa uno, el de recursos cuando cambia la escala. Conserva la elección por id, no por índice.
func _refresh_route_options(node: SimNode, kids: Array[SimNode]) -> void:
	var ids := PackedInt32Array()
	for child in kids:
		ids.append(child.id)
	if ids != _route_child_ids:
		var picked := _route_pick(_route_child, _route_child_ids)
		_route_child.clear()
		for child in kids:
			_route_child.add_item("🏘️ %s — %s" % [
				child.name, Content.tier(child.tier).name.to_lower()])
		_route_child_ids = ids
		_route_child.select(maxi(ids.find(picked), 0))

	# Los recursos que viajan, preguntados a `route_blocker` (ni oro ni cultura) y no repetidos
	# aquí: es la única lista de condiciones.
	var goods := PackedInt32Array()
	for good in Content.goods_for_tier(node.tier):
		if Logistics.route_blocker(_route_state, kids[0].id, node.id, good).is_empty():
			goods.append(good)
	if goods != _route_goods:
		var picked := _route_pick(_route_good, _route_goods)
		_route_good.clear()
		for good in goods:
			_route_good.add_item("%s %s" % [Goods.ICONS[good], Goods.NAMES[good]])
		_route_goods = goods
		_route_good.select(maxi(goods.find(picked), 0))


static func _route_pick(option: OptionButton, values: PackedInt32Array) -> int:
	var i := option.selected
	return values[i] if i >= 0 and i < values.size() else -1


## Origen, destino y recurso de lo que dice el formulario, o vacío si no hay hijo o recurso.
func _route_form_ends() -> Array:
	if _route_node == null:
		return []
	var ci := _route_child.selected
	var gi := _route_good.selected
	if ci < 0 or ci >= _route_child_ids.size() or gi < 0 or gi >= _route_goods.size():
		return []
	var child := _route_child_ids[ci]
	var good := _route_goods[gi]
	if _route_dir.selected == 1:
		return [child, _route_node.id, good]
	return [_route_node.id, child, good]


func _on_route_form_changed(_index: int) -> void:
	_refresh_route_form()


## El botón de crear y su motivo, como «🚩 Fundar»: la frase sale de `Logistics.route_blocker`,
## la misma lista que mirará el gobernador. Lo que añade la UI es lo que no es del modelo: que la
## ruta ya existe (crearla otra vez le pisaría el caudal) y que el nodo lo lleva un gobernador.
func _refresh_route_form() -> void:
	var blocker := ""
	var ends := _route_form_ends()
	if ends.is_empty():
		blocker = "no hay ningún hijo ni recurso con el que hacer una ruta"
	else:
		blocker = Logistics.route_blocker(_route_state, ends[0], ends[1], ends[2])
		if blocker.is_empty():
			for r in _route_state.routes:
				if r.from_id == ends[0] and r.to_id == ends[1] and r.good == ends[2]:
					blocker = "esa ruta ya existe: súbele el caudal con +"
					break
	if blocker.is_empty() and _route_node.is_delegated():
		blocker = "lo lleva su gobernador: recupera el mando (🖐️) para tocar las rutas"
	_set_disabled(_route_create, not blocker.is_empty())
	_route_reason.text = blocker
	if _route_reason.visible != not blocker.is_empty():
		_route_reason.visible = not blocker.is_empty()


static func _set_disabled(button: Button, off: bool) -> void:
	if button.disabled != off:
		button.disabled = off


## Las migas de pan: dónde se está y cómo subir. Sustituyen al «‹ Volver a <padre>», que hacía lo
## mismo para un solo eslabón.
##
## **Se construyen una vez por cambio de foco** —o cuando un eslabón cambia de nombre o de escala,
## al promocionar—, con el tema puesto antes del `add_child`, y luego solo se tocan `visible` y
## `modulate`: tocarle el tema a un control que ya está en el árbol obliga a reconformar su texto.
## El refresco de cada ciclo solo recorre la cadena (siete niveles como mucho) y compara la clave.
##
## Siempre se ven, también en la raíz con un solo eslabón: así el dock no se mueve al entrar en un
## hijo ni al volver.
func _refresh_crumbs(node: SimNode, state: WorldState) -> void:
	var chain: Array[SimNode] = []
	var at := node
	while at != null and chain.size() < 64:
		chain.push_front(at)
		at = state.get_node_by_id(at.parent_id)
	var key := ""
	for link in chain:
		key += "%d:%d:%s/" % [link.id, link.tier, link.name]
	if key == _crumbs_key:
		return
	_crumbs_key = key
	_rebuild_crumbs(chain)


## La caja vacía de las migas. Los eslabones los pone [method _rebuild_crumbs].
func _build_crumbs() -> Control:
	_crumbs_clip = Control.new()
	_crumbs_clip.clip_contents = true
	_crumbs_clip.mouse_filter = Control.MOUSE_FILTER_PASS
	_crumbs_clip.resized.connect(_fit_crumbs)

	_crumbs = HBoxContainer.new()
	_crumbs.add_theme_constant_override("separation", 2)
	_crumbs.mouse_filter = Control.MOUSE_FILTER_PASS
	_crumbs_clip.add_child(_crumbs)

	_crumbs_more = Label.new()
	_crumbs_more.text = "… ›"
	_crumbs_more.add_theme_font_size_override("font_size", 13)
	_crumbs_more.modulate = CRUMB_COLOR
	_crumbs_more.visible = false
	_crumbs.add_child(_crumbs_more)
	return _crumbs_clip


## Los eslabones de `chain` (de la raíz al enfocado). El activo se resalta con `modulate` y no hace
## nada; los demás piden su nodo por `focus_requested`, la misma ruta que la lista de colonias.
##
## Los botones se reutilizan entre cambios de foco: uno nuevo solo nace —con el tema puesto antes
## del `add_child`— cuando la cadena es más honda que ninguna anterior. A los que ya están en el
## árbol solo se les cambia `text`, `tooltip_text`, `modulate` y `visible`.
func _rebuild_crumbs(chain: Array[SimNode]) -> void:
	var separation := _crumbs.get_theme_constant("separation")
	while _crumb_links.size() < chain.size():
		var index := _crumb_links.size()
		var button := Button.new()
		button.flat = true
		button.focus_mode = Control.FOCUS_NONE
		button.add_theme_font_size_override("font_size", 13)
		button.pressed.connect(_on_crumb_pressed.bind(index))
		_crumbs.add_child(button)
		var arrow := Label.new()
		arrow.text = "›"
		arrow.add_theme_font_size_override("font_size", 13)
		arrow.modulate = CRUMB_COLOR
		_crumbs.add_child(arrow)
		_crumb_links.append([button, arrow, 0.0, -1])
	_crumb_count = chain.size()
	for i in _crumb_links.size():
		var link: Array = _crumb_links[i]
		var button: Button = link[0]
		var arrow: Label = link[1]
		if i >= chain.size():
			link[3] = -1
			button.visible = false
			arrow.visible = false
			continue
		var target := chain[i]
		var active := i == chain.size() - 1
		button.text = target.name
		button.tooltip_text = target.def().name
		button.modulate = CRUMB_ACTIVE_COLOR if active else CRUMB_COLOR
		# El activo no lleva flecha detrás y no pide nada al pulsarlo.
		link[3] = -1 if active else target.id
		var width := button.get_combined_minimum_size().x + separation
		if not active:
			width += arrow.get_combined_minimum_size().x + separation
		link[2] = width
	_crumbs_clip.custom_minimum_size.y = _crumbs.get_combined_minimum_size().y
	_fit_crumbs()


func _on_crumb_pressed(index: int) -> void:
	if index < _crumb_count:
		var id: int = _crumb_links[index][3]
		if id >= 0:
			focus_requested.emit(id)


## Si la cadena no cabe a lo ancho (móvil vertical, o un dock estrecho con una jerarquía honda), se
## recorta **por la izquierda**: los primeros eslabones se esconden detrás de «… ›», y el padre y el
## enfocado se ven siempre. Si ni esos dos caben, `_crumbs_clip` corta por la derecha.
func _fit_crumbs() -> void:
	if _crumbs == null:
		return
	var available := _crumbs_clip.size.x
	var separation := _crumbs.get_theme_constant("separation")
	var total := 0.0
	for i in _crumb_count:
		total += float(_crumb_links[i][2])
	var more_width := _crumbs_more.get_combined_minimum_size().x + separation
	var hidden := 0
	if available > 0.0 and total > available:
		total += more_width
		while total > available and hidden < _crumb_count - 2:
			total -= float(_crumb_links[hidden][2])
			hidden += 1
	_crumbs_more.visible = hidden > 0
	for i in _crumb_count:
		var link: Array = _crumb_links[i]
		var keep := i >= hidden
		(link[0] as Control).visible = keep
		(link[1] as Control).visible = keep and i < _crumb_count - 1
	# Fuera de un contenedor, la fila no encoge sola al esconder eslabones.
	_crumbs.size = Vector2.ZERO


## Los eslabones visibles, de izquierda a derecha, como texto (`… › Ciudad › Pueblo`). Para los
## tests y para leer una captura sin abrirla.
func crumbs_text() -> String:
	var parts := PackedStringArray()
	if _crumbs_more.visible:
		parts.append("…")
	for i in _crumb_count:
		var button: Button = _crumb_links[i][0]
		if button.visible:
			parts.append(button.text)
	return " › ".join(parts)


## El botón del eslabón `index` de la cadena (0 = raíz), o null. Para los tests.
func crumb_button(index: int) -> Button:
	if index < 0 or index >= _crumb_count:
		return null
	return _crumb_links[index][0]


## Marca la pestaña de estado cuando se puede ascender.
##
## Ascender es *el* momento del juego y ahora vive detrás de una pestaña. Sin este aviso en el
## título, un jugador que está repartiendo gente no se entera de que ya le toca — y el eje
## vertical de un incremental no puede depender de que se acuerde de mirar.
func _mark_promotion_ready(ready: bool) -> void:
	if _promotion_ready == ready:
		return
	_promotion_ready = ready
	_set_tab_titles(_tabs_with_text)


## Marca la pestaña de estado mientras el nodo enfocado pasa hambre **y está delegado**.
##
## Es la marca persistente del aviso de hambruna; la línea `famine` del diario solo dice cuándo
## empezó, y en un diario de dos líneas se pierde. Sale del mismo campo que el evento
## (`node.starving`), y solo delegado porque con el nodo a mano el jugador ya ve la población en
## rojo y es suya la decisión. Como el ⬆️, solo se recompone el título cuando cambia: `refresh`
## corre cada ciclo y retitular pestañas no es gratis.
func _mark_famine(warn: bool) -> void:
	if _famine_warning == warn:
		return
	_famine_warning = warn
	_set_tab_titles(_tabs_with_text)


static func _progress(current: float, target: float) -> String:
	return "%s/%s" % [_short(current), _short(target)]


## Números grandes legibles: en un incremental se llega a millones enseguida.
static func _short(value: float) -> String:
	if value >= 1.0e9:
		return "%.2f G" % (value / 1.0e9)
	if value >= 1.0e6:
		return "%.2f M" % (value / 1.0e6)
	if value >= 10000.0:
		return "%.1f k" % (value / 1000.0)
	return "%.0f" % value


## Una fila por oficio con **botones de más y menos**. Es la decisión más frecuente del juego,
## así que vive en pantalla y no detrás de un menú.
##
## Antes era un deslizador de peso relativo, y era el control equivocado: un deslizador dice
## «más o menos por aquí» cuando lo que hay que decir es «seis personas a la granja». Con
## botones el número es exacto, se ve cuánta gente cabe, y queda claro que a nadie lo destinan
## por ti.
func _refresh_jobs(node: SimNode, _params: SimParams, state: WorldState = null) -> void:
	var workers := Integrator.effective_workers(node)
	var idle := Integrator.idle_population(node)

	_idle_label.text = "👤 %.0f sin destinar" % idle
	_idle_label.modulate = IDLE_COLOR if idle < 1.0 else Color.WHITE

	if _delegate_button != null:
		var delegated := node.is_delegated()
		# En cada refresco, y sin señal: si `Main` rechaza un toggle (la puerta), el botón vuelve
		# a su sitio aquí en vez de quedarse hundido.
		_delegate_button.set_pressed_no_signal(delegated)
		# La puerta es la de `Main` (`GovernorSys.delegate_blocker`). Retomar el mando no pasa
		# por ella: un nodo delegado siempre se puede soltar. Sin `state` (las sondas que llaman
		# a esto sueltos) se pinta como antes de la puerta.
		var blocker := "" if delegated or state == null \
			else GovernorSys.delegate_blocker(state, node)
		_set_disabled(_delegate_button, not blocker.is_empty())
		# El peaje se dice **antes** de pulsar: delegado ya no hace falta, lo cuenta la consola.
		# Solo `.text`, `disabled` y `tooltip_text`: el botón lleva emoji y tocarle el tema en el
		# árbol cuesta ~6 ms.
		var percent := _governor_efficiency * 100.0
		if delegated:
			_delegate_button.text = "🎖️ Gobernador"
		elif not blocker.is_empty():
			# Sin Consejo, la llave está en el legado; con él, en la 🛒 (un 🎖️ Sello por nodo).
			_delegate_button.text = "🎖️ Delegar · 🔒 legado" \
				if not Ascension.governor_open(state) else "🎖️ Delegar · 🔒 sello"
		else:
			_delegate_button.text = "🖐️ A mano · delegar al %.0f %%" % percent
		_delegate_button.tooltip_text = blocker if not blocker.is_empty() \
			else "Un gobernador reparte y construye por ti, al %.0f %% de rendimiento." % percent

	_refresh_governor(node)

	for bi in node.buildings.size():
		var is_job := node.buildings[bi] > 0 and Content.building(bi).is_workplace()
		if not _job_rows.has(bi):
			if not is_job:
				continue
			_job_rows[bi] = _make_job_row(bi)
		var row: HBoxContainer = _job_rows[bi]
		row.visible = is_job
		if not is_job:
			continue

		var capacity := Construction.capacity_of(node, bi)
		var count: Label = row.get_node("count")
		count.text = "%.0f / %.0f" % [workers[bi], capacity]
		count.modulate = OK_COLOR if workers[bi] >= capacity - 0.05 else Color.WHITE

		# Deshabilitar cuando la acción no haría nada: se ve de un vistazo si el tope es de
		# puestos construidos o de gente disponible.
		(row.get_node("minus") as Button).disabled = node.jobs[bi] <= 0.0 or node.is_delegated()
		(row.get_node("plus") as Button).disabled = node.is_delegated() \
			or node.jobs[bi] >= capacity - 0.001 or idle < 1.0


## La consola, al día con el gobernador del nodo.
##
## Todo con `set_*_no_signal` y **solo si el valor ha cambiado de verdad**: esto corre en cada
## fotograma, y escribir el valor de vuelta en un deslizador que el dedo está arrastrando lo
## clava en su sitio. Es el mismo motivo por el que el botón de delegar usa
## `set_pressed_no_signal`.
func _refresh_governor(node: SimNode) -> void:
	if _governor_box == null:
		return
	var gov := node.governor
	# Solo con gobernador. Sin 🎖️ Consejo no hay forma de ponerlo (`delegate_blocker`), así que en
	# la era 1 la consola no se pinta; si aun así lo hay —un save v5 migrado, o la primitiva de las
	# herramientas—, se enseña: es un gobernador de verdad y se tiene que poder retocar.
	_governor_box.visible = gov != null
	if gov == null:
		return
	_governor_toll.text = "Rinde al %.0f %% de lo que rindes tú" % (_governor_efficiency * 100.0)

	var normalized := gov.normalized()
	for i in GOVERNOR_PRIORITIES.size():
		var field := String(GOVERNOR_PRIORITIES[i][0])
		var slider: HSlider = _governor_sliders[field]
		var value: float = gov.get(field)
		if not is_equal_approx(slider.value, value):
			slider.set_value_no_signal(value)
		(_governor_shares[field] as Label).text = "%.0f %%" % (normalized[i] * 100.0)

	for entry in GOVERNOR_PERMISSIONS:
		var field := String(entry[0])
		var check: CheckButton = _governor_checks[field]
		var on: bool = gov.get(field)
		if check.button_pressed != on:
			check.set_pressed_no_signal(on)
		# Solo `visible`, nunca el tema: el botón ya está en el árbol y lleva emoji.
		var shown: bool = node.tier >= int(GOVERNOR_PERMISSION_MIN_TIER.get(field, 0))
		if check.visible != shown:
			check.visible = shown

	_refresh_order(gov)


## Los botones de orden y su frase, **solo si la orden o el permiso de colonizar han cambiado**.
## Cambiar de nodo enfocado con la misma orden no toca nada: se vería exactamente igual.
func _refresh_order(gov: Governor) -> void:
	var order := int(gov.order)
	var shown := order * 2 + (1 if gov.may_expand else 0)
	if shown == _order_shown:
		return
	_order_shown = shown
	for i in _order_buttons.size():
		var on := int(GOVERNOR_ORDERS[i][0]) == order
		if _order_buttons[i].button_pressed != on:
			_order_buttons[i].set_pressed_no_signal(on)
	_order_note.text = _order_text(order, gov.may_expand)
	_order_note.visible = order != Governor.Order.NONE


## La frase del tope de herederos: solo si el nodo está delegado, tiene permiso de colonizar y
## su profundidad pasa del tope. `bonuses` recorre el legado, así que no se mira si no hace falta.
func _refresh_heirs_note(node: SimNode, state: WorldState) -> void:
	if _heirs_note == null:
		return
	var gov := node.governor
	var blocked := gov != null and gov.may_expand \
			and not GovernorSys.may_found_by_heirs(state, node)
	if _heirs_note.visible != blocked:
		_heirs_note.visible = blocked


func _make_job_row(building_index: int) -> HBoxContainer:
	var def := Content.building(building_index)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var label := Label.new()
	label.text = "%s %s" % [def.icon, def.name]
	# Elástico y recortable: con un ancho mínimo fijo, la fila entera se sale de un dock
	# estrecho y aparece un scroll horizontal donde debería haber un botón.
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.add_theme_font_size_override("font_size", 13)
	row.add_child(label)

	row.add_child(_worker_button("minus", "−", building_index, -1.0))

	var count := Label.new()
	count.name = "count"
	count.custom_minimum_size = Vector2(68, 0)
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	count.add_theme_font_size_override("font_size", 13)
	row.add_child(count)

	row.add_child(_worker_button("plus", "+", building_index, 1.0))

	_job_box.add_child(row)
	return row


func _worker_button(node_name: String, text: String, building_index: int,
		direction: float) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = text
	button.custom_minimum_size = Vector2(44, 40)  # mínimo táctil de la guía de UX
	button.pressed.connect(func() -> void:
		workers_changed.emit(building_index, direction * float(_step)))
	return button


func _refresh_builds(node: SimNode) -> void:
	for bi in Content.buildings_for_tier(node.tier):
		if not _build_buttons.has(bi):
			var button := Button.new()
			button.custom_minimum_size = Vector2(0, 44)
			button.pressed.connect(func() -> void: build_requested.emit(bi))
			_build_box.add_child(button)
			_build_buttons[bi] = button
		var b: Button = _build_buttons[bi]
		var def := Content.building(bi)
		b.text = "%s %s ×%d\n%s" % [
			def.icon, def.name, node.buildings[bi], _cost_text(node, bi),
		]
		# Delegado, construye el gobernador: los botones se apagan para que quede claro que
		# ya no mandas tú, en vez de que parezca que el juego compra a tus espaldas.
		b.disabled = node.is_delegated() or not Construction.can_build(node, bi)


static func _cost_text(node: SimNode, building_index: int) -> String:
	return _cost_of(Construction.cost_of(node, building_index))


## Vacía el diario. Lo llama `Main` al cambiar de foco: el diario sigue al nodo enfocado, y
## entrar en una colonia con las dos últimas líneas del pueblo debajo las atribuiría a ella.
func clear_events() -> void:
	_feed_lines.clear()
	_feed.text = ""


func push_event(text: String) -> void:
	# Agrupar repeticiones: «construye Cabaña» ×6 seguidas no aporta seis líneas de nada.
	if not _feed_lines.is_empty():
		var last := _feed_lines[_feed_lines.size() - 1]
		if last == text or last.begins_with(text + " ×"):
			var count := 2 if last == text else int(last.get_slice(" ×", 1)) + 1
			_feed_lines[_feed_lines.size() - 1] = "%s ×%d" % [text, count]
			_feed.text = "\n".join(_feed_lines)
			return
	_feed_lines.append(text)
	if _feed_lines.size() > 2:
		_feed_lines = _feed_lines.slice(_feed_lines.size() - 2)
	_feed.text = "\n".join(_feed_lines)


func _on_speed(index: int) -> void:
	speed_requested.emit(index)


func _on_ascension_pressed() -> void:
	_confirm_body.text = _ascension_warning
	_confirm.visible = true


# ---------------------------------------------------------------------------

## Barra de población con **dos marcas**: alojamiento y capacidad alimentaria.
##
## Es la pieza de UI que hace legible la mecánica central. Un jugador que ve la población
## parada y una sola barra llena no sabe qué hacer; viendo cuál de las dos marcas está por
## debajo, sabe si le faltan casas o le falta campo.
class PopulationBar:
	extends Control

	var pop: float = 0.0
	var housing: float = 0.0
	var food_capacity: float = 0.0

	func _draw() -> void:
		var w := size.x
		var h := size.y
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.14, 0.16, 0.16))

		var scale_max := maxf(housing, 1.0)
		if food_capacity != INF:
			scale_max = maxf(scale_max, food_capacity)
		scale_max = maxf(scale_max, pop) * 1.05

		var limited_by_food := food_capacity < housing
		var fill := Color(0.45, 0.66, 0.48) if not limited_by_food else Color(0.72, 0.62, 0.32)
		draw_rect(Rect2(Vector2.ZERO, Vector2(w * pop / scale_max, h)), fill)

		_mark(housing / scale_max * w, h, Color(0.72, 0.78, 0.86), "🏠")
		if food_capacity != INF:
			_mark(food_capacity / scale_max * w, h, Color(0.88, 0.76, 0.34), "🌾")

	func _mark(x: float, h: float, color: Color, _label: String) -> void:
		draw_line(Vector2(x, 0), Vector2(x, h), color, 2.0)
