class_name OptionsMenu
extends CanvasLayer

# Menu de pause / options (Échap), organisé en pages : une page principale
# qui renvoie vers les sous-menus Affichage, Graphismes & performances et Jeu.
# Les réglages sont appliqués immédiatement et persistés dans user://settings.cfg.
# Créé DÈS LE DÉMARRAGE par world.gd (player est null pendant le choix de
# classe, world.gd l'assigne ensuite via attach_player).
# process_mode = ALWAYS => il continue de fonctionner alors que l'arbre est en pause.

const SETTINGS_PATH := "user://settings.cfg"
const RESOLUTIONS: Array[Vector2i] = [
	Vector2i(1152, 648), Vector2i(1280, 720), Vector2i(1600, 900),
	Vector2i(1920, 1080), Vector2i(2560, 1440),
]
const FPS_OPTIONS := [0, 60, 120, 144] # 0 = illimité
const SHADOW_SIZES := [1024, 2048, 4096]

var world = null      # référence au nœud World (non typée : accès dynamique)
var player = null     # null tant que la classe n'est pas choisie

# Valeurs par défaut ; écrasées par le fichier de config s'il existe.
var settings := {
	"fullscreen": false,
	"res_index": 1,        # 1280x720
	"ui_scale": 1.0,
	"render_scale": 1.0,   # échelle de rendu 3D (l'interface reste nette)
	"upscale_mode": 0,     # 0 bilinéaire, 1 FSR 1.0, 2 FSR 2.2
	"msaa": 0,             # 0 off, 1 = 2x, 2 = 4x
	"shadows": 1,          # index dans SHADOW_SIZES
	"vsync": true,
	"fps_index": 0,        # index dans FPS_OPTIONS
	"mouse_sens": 0.005,
	"volume": 1.0,
	"render_distance": 6,
}

var is_open := false
var _panel: Control
var _pages := {} # nom de page -> Control
var _res_btn: OptionButton
var _menu_btn: Button # « retour au menu » : caché tant qu'on n'est pas en partie

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 10
	_load_settings()
	_build()
	_apply_all()
	_set_open(false)

# Appelé par world.gd quand le joueur est créé (après le choix de classe).
func attach_player(p) -> void:
	player = p
	_apply_game()

# ---------- Persistance ----------

func _load_settings() -> void:
	var cf := ConfigFile.new()
	if cf.load(SETTINGS_PATH) != OK:
		return
	for key in settings.keys():
		settings[key] = cf.get_value("settings", key, settings[key])

func _save_settings() -> void:
	var cf := ConfigFile.new()
	for key in settings.keys():
		cf.set_value("settings", key, settings[key])
	cf.save(SETTINGS_PATH)

# Modifie un réglage, l'applique, le sauvegarde.
# (surtout pas "_set" : c'est une méthode virtuelle native d'Object)
func _update_setting(key: String, value, apply: Callable) -> void:
	settings[key] = value
	apply.call()
	_save_settings()

# ---------- Application des réglages ----------

func _apply_all() -> void:
	_apply_window()
	_apply_ui_scale()
	_apply_render_scale()
	_apply_upscale_mode()
	_apply_msaa()
	_apply_shadows()
	_apply_vsync()
	_apply_fps()
	_apply_game()

func _apply_window() -> void:
	# NB : sans effet si le jeu tourne intégré à l'éditeur (voir avertissement
	# affiché dans la page Affichage).
	if settings.fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(RESOLUTIONS[settings.res_index])
		# Recentre la fenêtre sur l'écran.
		var srect := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen())
		var wsize := DisplayServer.window_get_size()
		DisplayServer.window_set_position(srect.position + (srect.size - wsize) / 2)
	if _res_btn != null:
		_res_btn.disabled = settings.fullscreen

func _apply_ui_scale() -> void:
	get_tree().root.content_scale_factor = settings.ui_scale

func _apply_render_scale() -> void:
	get_tree().root.scaling_3d_scale = settings.render_scale

func _apply_upscale_mode() -> void:
	get_tree().root.scaling_3d_mode = settings.upscale_mode as Viewport.Scaling3DMode

func _apply_msaa() -> void:
	get_tree().root.msaa_3d = settings.msaa as Viewport.MSAA

func _apply_shadows() -> void:
	var s: int = SHADOW_SIZES[settings.shadows]
	RenderingServer.directional_shadow_atlas_set_size(s, true)
	get_tree().root.positional_shadow_atlas_size = s

func _apply_vsync() -> void:
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if settings.vsync else DisplayServer.VSYNC_DISABLED)

func _apply_fps() -> void:
	Engine.max_fps = FPS_OPTIONS[settings.fps_index]

func _apply_game() -> void:
	if player != null:
		player.mouse_sensitivity = settings.mouse_sens
	var master := AudioServer.get_bus_index("Master")
	AudioServer.set_bus_volume_db(master, linear_to_db(maxf(settings.volume, 0.0001)))
	if world != null and world.has_method("set_render_distance"):
		world.set_render_distance(int(settings.render_distance))

# ---------- Construction de l'interface ----------

func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)
	_panel = dim

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.add_child(center)

	var frame := PanelContainer.new()
	frame.custom_minimum_size = Vector2(500, 0)
	center.add_child(frame)

	_pages["main"] = _build_main_page()
	_pages["display"] = _build_display_page()
	_pages["graphics"] = _build_graphics_page()
	_pages["game"] = _build_game_page()
	for page in _pages.values():
		frame.add_child(page)
	_show_page("main")

func _show_page(page_name: String) -> void:
	for key in _pages:
		_pages[key].visible = (key == page_name)

# Squelette commun à toutes les pages (titre + espacement).
func _page(title_text: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	var title := Label.new()
	title.text = title_text
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	box.add_child(title)
	return box

func _add_back(box: VBoxContainer) -> void:
	box.add_child(HSeparator.new())
	var back := Button.new()
	back.text = "← Retour"
	back.pressed.connect(func(): _show_page("main"))
	box.add_child(back)

func _build_main_page() -> Control:
	var box := _page("Options")

	for entry in [["Affichage", "display"], ["Graphismes & performances", "graphics"], ["Jeu", "game"]]:
		var btn := Button.new()
		btn.text = entry[0]
		var target: String = entry[1]
		btn.pressed.connect(func(): _show_page(target))
		box.add_child(btn)

	var controls := Label.new()
	controls.text = "Déplacement : Z Q S D     Courir : Maj     Sauter : Espace     Roulade : Ctrl\nAttaquer : Clic gauche     Spécial : Clic droit     Inventaire : I     Lanterne : G"
	controls.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	controls.add_theme_color_override("font_color", Color(0.78, 0.78, 0.82))
	box.add_child(controls)

	box.add_child(HSeparator.new())

	var resume := Button.new()
	resume.text = "Reprendre"
	resume.pressed.connect(func(): _set_open(false))
	box.add_child(resume)

	# Visible seulement en partie (au menu principal il n'y a rien à quitter).
	_menu_btn = Button.new()
	_menu_btn.text = "Sauvegarder et retour au menu"
	_menu_btn.pressed.connect(func():
		_set_open(false)
		if world != null and world.has_method("exit_to_menu"):
			world.exit_to_menu())
	box.add_child(_menu_btn)

	var quit := Button.new()
	quit.text = "Quitter le jeu"
	quit.pressed.connect(func():
		if world != null and world.has_method("save_progress"):
			world.save_progress()
		get_tree().quit())
	box.add_child(quit)
	return box

func _build_display_page() -> Control:
	var box := _page("Affichage")

	if Engine.is_embedded_in_editor():
		var warn := Label.new()
		warn.text = "⚠ Le jeu tourne intégré à l'éditeur Godot : le plein écran et la résolution ne peuvent pas s'appliquer. Désactive « Intégrer la fenêtre de jeu » dans l'éditeur, ou lance un export du jeu."
		warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		warn.custom_minimum_size = Vector2(460, 0)
		warn.add_theme_color_override("font_color", Color(1.0, 0.72, 0.3))
		box.add_child(warn)

	box.add_child(_make_check("Plein écran", settings.fullscreen,
		func(v: bool): _update_setting("fullscreen", v, _apply_window)))

	var res_labels: Array = []
	for r in RESOLUTIONS:
		res_labels.append("%d × %d" % [r.x, r.y])
	_res_btn = _option_button(res_labels, settings.res_index,
		func(i: int): _update_setting("res_index", i, _apply_window))
	_res_btn.disabled = settings.fullscreen
	box.add_child(_make_option_row("Résolution (fenêtré)", _res_btn))

	box.add_child(_make_slider("Taille de l'interface", 0.75, 1.5, 0.05,
		settings.ui_scale, func(v: float): _update_setting("ui_scale", v, _apply_ui_scale)))

	_add_back(box)
	return box

func _build_graphics_page() -> Control:
	var box := _page("Graphismes & performances")

	box.add_child(_make_slider("Échelle de rendu 3D (plus bas = plus rapide)", 0.5, 1.0, 0.05,
		settings.render_scale, func(v: float): _update_setting("render_scale", v, _apply_render_scale)))

	box.add_child(_make_option_row("Upscaling",
		_option_button(["Bilinéaire", "FSR 1.0", "FSR 2.2"], settings.upscale_mode,
			func(i: int): _update_setting("upscale_mode", i, _apply_upscale_mode))))

	box.add_child(_make_option_row("Anti-aliasing (MSAA)",
		_option_button(["Désactivé", "2×", "4×"], settings.msaa,
			func(i: int): _update_setting("msaa", i, _apply_msaa))))

	box.add_child(_make_option_row("Qualité des ombres",
		_option_button(["Basse", "Moyenne", "Haute"], settings.shadows,
			func(i: int): _update_setting("shadows", i, _apply_shadows))))

	box.add_child(_make_check("VSync", settings.vsync,
		func(v: bool): _update_setting("vsync", v, _apply_vsync)))

	box.add_child(_make_option_row("Limite d'images/s",
		_option_button(["Illimitée", "60", "120", "144"], settings.fps_index,
			func(i: int): _update_setting("fps_index", i, _apply_fps))))

	box.add_child(_make_slider("Distance de rendu (chunks)", 1, 12, 1,
		float(settings.render_distance),
		func(v: float): _update_setting("render_distance", int(v), _apply_game)))

	_add_back(box)
	return box

func _build_game_page() -> Control:
	var box := _page("Jeu")

	box.add_child(_make_slider("Sensibilité souris", 0.001, 0.02, 0.0005,
		settings.mouse_sens, func(v: float): _update_setting("mouse_sens", v, _apply_game)))

	box.add_child(_make_slider("Volume", 0.0, 1.0, 0.05,
		settings.volume, func(v: float): _update_setting("volume", v, _apply_game)))

	_add_back(box)
	return box

# ---------- Petites briques d'interface ----------

func _make_slider(label_text: String, min_v: float, max_v: float, step: float, value: float, cb: Callable) -> Control:
	var row := VBoxContainer.new()
	var lbl := Label.new()
	lbl.text = label_text
	row.add_child(lbl)
	var slider := HSlider.new()
	slider.min_value = min_v
	slider.max_value = max_v
	slider.step = step
	slider.value = value
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(cb)
	row.add_child(slider)
	return row

func _make_check(label_text: String, pressed: bool, cb: Callable) -> Control:
	var check := CheckButton.new()
	check.text = label_text
	check.button_pressed = pressed
	check.toggled.connect(cb)
	return check

func _option_button(items: Array, selected: int, cb: Callable) -> OptionButton:
	var btn := OptionButton.new()
	for item in items:
		btn.add_item(item)
	btn.selected = clampi(selected, 0, items.size() - 1)
	btn.item_selected.connect(cb)
	return btn

func _make_option_row(label_text: String, btn: OptionButton) -> Control:
	var row := HBoxContainer.new()
	var lbl := Label.new()
	lbl.text = label_text
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)
	btn.custom_minimum_size = Vector2(160, 0)
	row.add_child(btn)
	return row

# ---------- Ouverture / fermeture ----------

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_set_open(not is_open)
		get_viewport().set_input_as_handled()

func _set_open(open: bool) -> void:
	is_open = open
	_panel.visible = open
	get_tree().paused = open
	if open:
		_show_page("main") # on retombe toujours sur la page principale
		if _menu_btn != null:
			_menu_btn.visible = player != null
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		# Pendant le choix de classe (pas encore de joueur), la souris reste libre.
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if player != null else Input.MOUSE_MODE_VISIBLE
