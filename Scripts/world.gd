extends Node3D

# Chef d'orchestre :
#  - possède le générateur (TerrainGen),
#  - streame les chunks autour du joueur (chargement/déchargement),
#  - fait apparaître le joueur et les ennemis,
#  - gère un HUD minimal (barre de PV + aide).

const TREE_SCENE := preload("res://Scènes/tree.tscn")

# Le niveau de l'eau vit dans TerrainGen.WATER_Y : la génération (arbres,
# décorations, couleur des blocs immergés) doit connaître le même seuil.

# Eau animée : le matériau est créé UNE fois ici et partagé par tous les
# chunks (chaque chunk ne construit des quads d'eau qu'au-dessus de ses
# colonnes immergées — voir Chunk._build_water). Les vaguelettes sont ancrées
# en coordonnées MONDE : aucune couture entre chunks.
const WATER_SHADER := """
shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled, specular_schlick_ggx;

uniform vec3 deep_color : source_color = vec3(0.08, 0.25, 0.45);
uniform vec3 shallow_color : source_color = vec3(0.20, 0.50, 0.70);

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX.y += sin(world_pos.x * 0.35 + TIME * 1.1) * cos(world_pos.z * 0.30 + TIME * 0.8) * 0.07;
}

void fragment() {
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	ALBEDO = mix(deep_color, shallow_color, fresnel);
	ALPHA = clamp(0.55 + fresnel * 0.35, 0.0, 0.92);
	METALLIC = 0.25;
	ROUGHNESS = 0.06;
	SPECULAR = 0.6;
	vec2 nw = vec2(
		sin(world_pos.x * 1.8 + TIME * 1.4) + sin(world_pos.x * 3.1 - TIME * 0.9),
		sin(world_pos.z * 2.1 + TIME * 1.2) + sin(world_pos.z * 3.3 - TIME * 0.7));
	NORMAL_MAP = normalize(vec3(nw * 0.12, 1.0)) * 0.5 + 0.5;
}
"""

# Au-delà de cette distance, un ennemi est recyclé (despawn).
const ENEMY_DESPAWN_DIST := 50.0

@export var render_distance: int = 6     # rayon de chunks chargés autour du joueur
										 # (chunks de 8 m depuis les blocs fins)
@export var chunk_build_per_frame: int = 2
@export var max_enemies: int = 6
@export var enemy_spawn_interval: float = 4.0
@export var day_length: float = 900.0    # durée du cycle jour/nuit (secondes)

var gen: TerrainGen
var player: Player
var chunk_size: int
var loaded_chunks := {}                   # Vector2i -> Chunk
var build_queue: Array = []               # Vector2i en attente de construction
var current_center := Vector2i(99999, 99999)
var _enemy_timer := 0.0
var _hud: CanvasLayer
var _hp_bar: ProgressBar
var _xp_bar: ProgressBar
var _level_label: Label
var _class_label: Label
var _special_bar: ProgressBar
var _stamina_bar: ProgressBar
var _water_mat: ShaderMaterial
var _options: OptionsMenu
var _day_night: DayNight
var _underwater := false            # la caméra est-elle sous la surface ?
var _underwater_rect: ColorRect     # teinte plein écran quand on est immergé
var _menu: MainMenu                 # menu principal (null une fois en jeu)
var _current_char := {}             # personnage en cours (sauvegardé via MainMenu)

func _ready() -> void:
	_setup_input()
	chunk_size = Chunk.SIZE

	_make_hud()
	_make_underwater_overlay()
	_make_water_material()

	# Créé dès maintenant : les réglages sauvegardés (résolution, plein écran,
	# qualité...) s'appliquent au lancement, pas seulement une fois en jeu.
	_options = OptionsMenu.new()
	_options.world = self
	add_child(_options)

	# Menu principal (personnages + mondes) : la génération n'existe qu'une
	# fois un monde choisi — sa graine vient de l'entrée de monde sauvegardée.
	_menu = MainMenu.new()
	_menu.options = _options
	_menu.start_game.connect(_on_start_game)
	add_child(_menu)

func _on_start_game(character: Dictionary, world_entry: Dictionary) -> void:
	_current_char = character
	start_session(character, int(world_entry.get("seed", 0)))

# Démarre une partie : crée le générateur, le monde et le joueur (avec la
# progression sauvegardée du personnage). Appelé par le menu et par les tests.
func start_session(character: Dictionary, seed_value: int) -> void:
	if _menu != null:
		_menu.queue_free()
		_menu = null

	gen = TerrainGen.new(seed_value)
	_make_day_night()
	# On construit tout de suite le chunk de spawn : sinon le joueur tombe dans le vide.
	_build_chunk(Vector2i(0, 0))

	var id: String = character.get("class_id", "warrior")
	player = Player.new()
	player.class_id = id
	player.gen = gen # la nage sonde le terrain pour savoir où est l'eau
	add_child(player)
	player.global_position = Vector3(0.25, _ground_y(0.0, 0.0) + 3.0, 0.25)

	# Restaure la progression sauvegardée (niveau, XP, équipement, sac).
	player.level = int(character.get("level", 1))
	player.xp = int(character.get("xp", 0))
	player.xp_to_next = int(character.get("xp_to_next", 100))
	if character.get("equipment") is Dictionary:
		player.equipment = character["equipment"]
	if character.get("inventory") is Array:
		player.inventory = character["inventory"]
	player._recompute_stats()
	player.health = player.max_health
	player._refresh_weapon_visual()

	player.health_changed.connect(_on_player_health_changed)
	player.xp_changed.connect(_on_player_xp_changed)
	player.leveled_up.connect(_on_player_leveled_up)
	player.died.connect(_on_player_died)
	player.broadcast_stats()
	# Sauvegarde automatique aux moments qui comptent.
	player.leveled_up.connect(func(_lvl): save_progress())
	player.inventory_changed.connect(save_progress)

	_class_label.text = Player.CLASSES[id]["name"]
	_hud.visible = true

	_options.attach_player(player)

	var inv := InventoryUI.new()
	inv.player = player
	add_child(inv)

	current_center = _player_chunk()
	_refresh_chunk_list()

# Recopie la progression du joueur dans le personnage et la persiste.
func save_progress() -> void:
	if player == null or _current_char.is_empty():
		return
	_current_char["level"] = player.level
	_current_char["xp"] = player.xp
	_current_char["xp_to_next"] = player.xp_to_next
	_current_char["equipment"] = player.equipment
	_current_char["inventory"] = player.inventory
	MainMenu.save_character(_current_char)

# Retour au menu principal (bouton du menu pause) : on sauvegarde puis on
# recharge la scène — tout l'état de la partie est reconstruit proprement.
func exit_to_menu() -> void:
	save_progress()
	get_tree().paused = false
	get_tree().reload_current_scene()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save_progress()

# Déplacement en ZQSD (clavier AZERTY). Configuré ici en code pour ne pas risquer
# de corrompre project.godot ; ça remplace l'usage des flèches directionnelles.
func _setup_input() -> void:
	_bind_key("move_forward", KEY_Z)
	_bind_key("move_back", KEY_S)
	_bind_key("move_left", KEY_Q)
	_bind_key("move_right", KEY_D)
	_bind_key("inventory", KEY_I)
	_bind_key("lantern", KEY_G)
	_bind_key("roll", KEY_CTRL)

func _bind_key(action: String, keycode: Key) -> void:
	if InputMap.has_action(action):
		InputMap.action_erase_events(action)
	else:
		InputMap.add_action(action)
	var ev := InputEventKey.new()
	ev.keycode = keycode
	InputMap.action_add_event(action, ev)

func set_render_distance(v: int) -> void:
	render_distance = clampi(v, 1, 12)
	# Avant la création du joueur, current_center n'est pas encore valide :
	# rafraîchir maintenant déchargerait le chunk de spawn.
	if player != null:
		_refresh_chunk_list()

func _process(delta: float) -> void:
	if player == null:
		return
	var pc := _player_chunk()
	if pc != current_center:
		current_center = pc
		_refresh_chunk_list()
	_process_build_queue()
	_handle_enemy_spawns(delta)
	_update_underwater()
	if _special_bar != null and player.special_cooldown > 0.0:
		_special_bar.value = 1.0 - player.special_timer / player.special_cooldown
	if _stamina_bar != null:
		_stamina_bar.max_value = Player.STAMINA_MAX
		_stamina_bar.value = player.stamina

# ---------- Streaming des chunks ----------

# Hauteur MONDE du dessus du terrain au point monde (wx, wz).
# TerrainGen travaille en indices de cube : conversion via Chunk.CUBE.
func _ground_y(wx: float, wz: float) -> float:
	return (float(gen.get_height(roundi(wx / Chunk.CUBE), roundi(wz / Chunk.CUBE))) + 0.5) * Chunk.CUBE

func _player_chunk() -> Vector2i:
	var w := chunk_size * Chunk.CUBE # emprise monde d'un chunk
	return Vector2i(
		floori(player.global_position.x / w),
		floori(player.global_position.z / w))

func _refresh_chunk_list() -> void:
	var needed := {}
	for dx in range(-render_distance, render_distance + 1):
		for dz in range(-render_distance, render_distance + 1):
			var key := Vector2i(current_center.x + dx, current_center.y + dz)
			needed[key] = true
			if not loaded_chunks.has(key) and not build_queue.has(key):
				build_queue.append(key)
	# Décharge les chunks hors de portée.
	for key in loaded_chunks.keys():
		if not needed.has(key):
			loaded_chunks[key].queue_free()
			loaded_chunks.erase(key)
	# Nettoie la file et priorise les chunks les plus proches.
	build_queue = build_queue.filter(func(k): return needed.has(k))
	build_queue.sort_custom(_closer_to_center)

func _closer_to_center(a: Vector2i, b: Vector2i) -> bool:
	return (a - current_center).length_squared() < (b - current_center).length_squared()

func _process_build_queue() -> void:
	var budget := chunk_build_per_frame
	while budget > 0 and not build_queue.is_empty():
		var key: Vector2i = build_queue.pop_front()
		if loaded_chunks.has(key):
			continue
		_build_chunk(key)
		budget -= 1

func _build_chunk(key: Vector2i) -> void:
	if loaded_chunks.has(key):
		return
	var c := Chunk.new()
	c.gen = gen
	c.cx = key.x
	c.cz = key.y
	c.tree_scene = TREE_SCENE
	c.water_material = _water_mat
	c.position = Vector3(key.x * chunk_size, 0, key.y * chunk_size) * Chunk.CUBE
	add_child(c)
	c.build()
	loaded_chunks[key] = c

# ---------- Ennemis ----------

func _handle_enemy_spawns(delta: float) -> void:
	_enemy_timer -= delta
	if _enemy_timer > 0.0:
		return
	_enemy_timer = enemy_spawn_interval
	# Recycle les ennemis abandonnés : trop loin du joueur (souvent sur des
	# chunks déchargés) ou tombés dans le vide. Sans ça, le plafond max_enemies
	# reste occupé à vie par les monstres du spawn et plus rien n'apparaît
	# quand on explore.
	var alive := 0
	for e in get_tree().get_nodes_in_group("enemies"):
		if not (e is Node3D) or not is_instance_valid(e):
			continue
		if e.global_position.distance_to(player.global_position) > ENEMY_DESPAWN_DIST \
				or e.global_position.y < -30.0:
			e.queue_free()
		else:
			alive += 1
	if alive >= max_enemies:
		return
	var ang := randf() * TAU
	var r := randf_range(10.0, 22.0)
	var ex := player.global_position.x + cos(ang) * r
	var ez := player.global_position.z + sin(ang) * r
	var ey := _ground_y(ex, ez) + 2.0
	var e := Enemy.new()
	e.type_id = _pick_enemy_type()
	add_child(e)
	e.global_position = Vector3(ex, ey, ez)

func _pick_enemy_type() -> String:
	var r := randf()
	if r < 0.4:
		return "slime"
	elif r < 0.7:
		return "scout"
	elif r < 0.9:
		return "archer"
	return "brute"

# ---------- HUD ----------

func _make_hud() -> void:
	var layer := CanvasLayer.new()
	layer.visible = false # affiché quand la classe est choisie
	add_child(layer)
	_hud = layer

	var bar := ProgressBar.new()
	bar.min_value = 0
	bar.max_value = 100
	bar.value = 100
	bar.custom_minimum_size = Vector2(240, 26)
	bar.position = Vector2(24, 24)
	bar.show_percentage = false
	_style_bar(bar, Color(0.85, 0.25, 0.25))
	layer.add_child(bar)
	_hp_bar = bar

	var hp_label := Label.new()
	hp_label.text = "PV"
	hp_label.position = Vector2(30, 26)
	layer.add_child(hp_label)

	var xp_bar := ProgressBar.new()
	xp_bar.min_value = 0
	xp_bar.max_value = 100
	xp_bar.value = 0
	xp_bar.custom_minimum_size = Vector2(240, 14)
	xp_bar.position = Vector2(24, 56)
	xp_bar.show_percentage = false
	_style_bar(xp_bar, Color(0.25, 0.75, 0.95))
	layer.add_child(xp_bar)
	_xp_bar = xp_bar

	var level_label := Label.new()
	level_label.text = "Niv. 1"
	level_label.position = Vector2(276, 22)
	layer.add_child(level_label)
	_level_label = level_label

	var class_label := Label.new()
	class_label.text = ""
	class_label.position = Vector2(276, 46)
	layer.add_child(class_label)
	_class_label = class_label

	# Jauge de la compétence spéciale (clic droit) : pleine = prête.
	var sp_bar := ProgressBar.new()
	sp_bar.min_value = 0.0
	sp_bar.max_value = 1.0
	sp_bar.value = 1.0
	sp_bar.custom_minimum_size = Vector2(240, 10)
	sp_bar.position = Vector2(24, 78)
	sp_bar.show_percentage = false
	_style_bar(sp_bar, Color(0.95, 0.80, 0.30))
	layer.add_child(sp_bar)
	_special_bar = sp_bar

	var sp_label := Label.new()
	sp_label.text = "Spécial (clic droit)"
	sp_label.position = Vector2(276, 70)
	layer.add_child(sp_label)

	# Jauge d'endurance (sprint Maj + roulade Ctrl).
	var st_bar := ProgressBar.new()
	st_bar.min_value = 0.0
	st_bar.max_value = 100.0
	st_bar.value = 100.0
	st_bar.custom_minimum_size = Vector2(240, 10)
	st_bar.position = Vector2(24, 94)
	st_bar.show_percentage = false
	_style_bar(st_bar, Color(0.40, 0.80, 0.40))
	layer.add_child(st_bar)
	_stamina_bar = st_bar

	var st_label := Label.new()
	st_label.text = "Endurance (Maj / Ctrl roulade)"
	st_label.position = Vector2(276, 88)
	layer.add_child(st_label)

func _make_water_material() -> void:
	var sh := Shader.new()
	sh.code = WATER_SHADER
	_water_mat = ShaderMaterial.new()
	_water_mat.shader = sh

# Le cycle jour/nuit pilote la lumière et l'environnement déjà posés dans world.tscn.
func _make_day_night() -> void:
	_day_night = DayNight.new()
	_day_night.sun = $DirectionalLight3D
	_day_night.environment = ($WorldEnvironment as WorldEnvironment).environment
	_day_night.day_length = day_length
	add_child(_day_night)

# Teinte bleutée plein écran affichée quand la caméra est sous l'eau.
# Sur un CanvasLayer 0 : sous le HUD (layer 1 par défaut) et les menus.
func _make_underwater_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 0
	add_child(layer)
	_underwater_rect = ColorRect.new()
	_underwater_rect.color = Color(0.05, 0.22, 0.35, 0.30)
	_underwater_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_underwater_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_underwater_rect.visible = false
	layer.add_child(_underwater_rect)

# Bascule l'ambiance sous-marine quand la CAMÉRA passe sous la surface d'une
# colonne immergée (l'eau n'existe que là où le terrain est sous WATER_Y).
func _update_underwater() -> void:
	var uw := false
	var cam := player.camera
	if cam != null:
		var cp := cam.global_position
		uw = cp.y < TerrainGen.WATER_Y * Chunk.CUBE \
			and float(gen.get_height(roundi(cp.x / Chunk.CUBE), roundi(cp.z / Chunk.CUBE))) + 0.5 < TerrainGen.WATER_Y
	if uw == _underwater:
		return
	_underwater = uw
	_underwater_rect.visible = uw
	if _day_night != null:
		_day_night.underwater = uw

func _style_bar(bar: ProgressBar, fill: Color) -> void:
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.05, 0.05, 0.08, 0.6)
	bg.set_corner_radius_all(4)
	var fg := StyleBoxFlat.new()
	fg.bg_color = fill
	fg.set_corner_radius_all(4)
	bar.add_theme_stylebox_override("background", bg)
	bar.add_theme_stylebox_override("fill", fg)

func _on_player_health_changed(current: int, maximum: int) -> void:
	if _hp_bar != null:
		_hp_bar.max_value = maximum
		_hp_bar.value = current

func _on_player_xp_changed(current_xp: int, needed: int, lvl: int) -> void:
	if _xp_bar != null:
		_xp_bar.max_value = needed
		_xp_bar.value = current_xp
	if _level_label != null:
		_level_label.text = "Niv. %d" % lvl

func _on_player_leveled_up(_lvl: int) -> void:
	if _level_label != null:
		var t := create_tween()
		_level_label.scale = Vector2(1.6, 1.6)
		t.tween_property(_level_label, "scale", Vector2.ONE, 0.3)

func _on_player_died() -> void:
	player.global_position = Vector3(0.25, _ground_y(0.0, 0.0) + 3.0, 0.25)
	player.velocity = Vector3.ZERO
