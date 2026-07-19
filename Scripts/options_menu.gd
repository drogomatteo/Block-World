class_name OptionsMenu
extends CanvasLayer

# Menu de pause / options (Échap), organisé en pages : une page principale
# qui renvoie vers les sous-menus Affichage, Graphismes & performances et Jeu.
# LOGIQUE UNIQUEMENT : les pages (boutons, curseurs, cases, listes déroulantes)
# vivent dans Scènes/UI/options_menu.tscn — ici on initialise les contrôles
# depuis settings, on connecte les signaux et on applique/persiste les
# réglages (user://settings.cfg). Instancié DÈS LE DÉMARRAGE par world.gd
# (player est null pendant le menu principal, posé ensuite via attach_player).
# layer 10 et process_mode ALWAYS (fonctionne pendant la pause) : dans la scène.

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

# ---------- Branchement de l'interface (la structure est dans la scène) ----------

func _build() -> void:
	_panel = $Dim
	_pages = {"main": %MainPage, "display": %DisplayPage,
		"graphics": %GraphicsPage, "game": %GamePage}
	_res_btn = %ResBtn
	_menu_btn = %MenuBtn

	# Valeurs initiales AVANT de connecter les signaux : les setters
	# (button_pressed, value) émettent toggled/value_changed et
	# déclencheraient des sauvegardes fantômes.
	%EditorWarn.visible = Engine.is_embedded_in_editor()
	%FullscreenCheck.button_pressed = settings.fullscreen
	_res_btn.selected = clampi(int(settings.res_index), 0, RESOLUTIONS.size() - 1)
	_res_btn.disabled = settings.fullscreen
	%UIScaleSlider.value = settings.ui_scale
	%RenderScaleSlider.value = settings.render_scale
	%UpscaleBtn.selected = clampi(int(settings.upscale_mode), 0, 2)
	%MsaaBtn.selected = clampi(int(settings.msaa), 0, 2)
	%ShadowsBtn.selected = clampi(int(settings.shadows), 0, SHADOW_SIZES.size() - 1)
	%VsyncCheck.button_pressed = settings.vsync
	%FpsBtn.selected = clampi(int(settings.fps_index), 0, FPS_OPTIONS.size() - 1)
	%RenderDistSlider.value = float(settings.render_distance)
	%MouseSensSlider.value = settings.mouse_sens
	%VolumeSlider.value = settings.volume

	# Navigation.
	%DisplayNavBtn.pressed.connect(func(): _show_page("display"))
	%GraphicsNavBtn.pressed.connect(func(): _show_page("graphics"))
	%GameNavBtn.pressed.connect(func(): _show_page("game"))
	for back in [%DisplayBackBtn, %GraphicsBackBtn, %GameBackBtn]:
		back.pressed.connect(func(): _show_page("main"))
	%ResumeBtn.pressed.connect(func(): _set_open(false))
	# « Retour au menu » : visible seulement en partie (géré par _set_open).
	_menu_btn.pressed.connect(func():
		_set_open(false)
		if world != null and world.has_method("exit_to_menu"):
			world.exit_to_menu())
	%QuitBtn.pressed.connect(func():
		if world != null and world.has_method("save_progress"):
			world.save_progress()
		get_tree().quit())

	# Réglages : chaque contrôle applique + sauvegarde immédiatement.
	%FullscreenCheck.toggled.connect(func(v: bool): _update_setting("fullscreen", v, _apply_window))
	_res_btn.item_selected.connect(func(i: int): _update_setting("res_index", i, _apply_window))
	%UIScaleSlider.value_changed.connect(func(v: float): _update_setting("ui_scale", v, _apply_ui_scale))
	%RenderScaleSlider.value_changed.connect(func(v: float): _update_setting("render_scale", v, _apply_render_scale))
	%UpscaleBtn.item_selected.connect(func(i: int): _update_setting("upscale_mode", i, _apply_upscale_mode))
	%MsaaBtn.item_selected.connect(func(i: int): _update_setting("msaa", i, _apply_msaa))
	%ShadowsBtn.item_selected.connect(func(i: int): _update_setting("shadows", i, _apply_shadows))
	%VsyncCheck.toggled.connect(func(v: bool): _update_setting("vsync", v, _apply_vsync))
	%FpsBtn.item_selected.connect(func(i: int): _update_setting("fps_index", i, _apply_fps))
	%RenderDistSlider.value_changed.connect(func(v: float): _update_setting("render_distance", int(v), _apply_game))
	%MouseSensSlider.value_changed.connect(func(v: float): _update_setting("mouse_sens", v, _apply_game))
	%VolumeSlider.value_changed.connect(func(v: float): _update_setting("volume", v, _apply_game))

	_show_page("main")

func _show_page(page_name: String) -> void:
	for key in _pages:
		_pages[key].visible = (key == page_name)

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
