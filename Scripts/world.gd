extends Node3D

# Chef d'orchestre :
#  - possède le générateur (TerrainGen),
#  - streame les chunks autour du joueur (chargement/déchargement),
#  - fait apparaître le joueur et les ennemis,
#  - gère un HUD minimal (barre de PV + aide).

# Toutes les briques du jeu sont des SCÈNES (Scènes/...) instanciées ici :
# plus aucun objet n'est créé via Classe.new() — on voit dans l'éditeur à quoi
# chaque script correspond. Les presets (class_id, type_id...) vivent dans les
# .tscn ; les paramètres dynamiques (seed, joueur...) restent posés en code
# entre instantiate() et add_child().
const TERRAIN_GEN_SCENE := preload("res://Scènes/Monde/terrain_gen.tscn")
const CHUNK_SCENE := preload("res://Scènes/Monde/chunk.tscn")
const DAY_NIGHT_SCENE := preload("res://Scènes/Monde/day_night.tscn")
const UI_SCENE := preload("res://Scènes/UI/ui.tscn")
const MAIN_MENU_SCENE := preload("res://Scènes/UI/main_menu.tscn")
const OPTIONS_MENU_SCENE := preload("res://Scènes/UI/options_menu.tscn")
const INVENTORY_UI_SCENE := preload("res://Scènes/UI/inventory_ui.tscn")
const PLAYER_SCENES := {
	"warrior": preload("res://Scènes/Acteurs/warrior.tscn"),
	"ranger": preload("res://Scènes/Acteurs/ranger.tscn"),
	"mage": preload("res://Scènes/Acteurs/mage.tscn"),
	"rogue": preload("res://Scènes/Acteurs/rogue.tscn"),
}
const ENEMY_SCENES := {
	"slime": preload("res://Scènes/Acteurs/slime.tscn"),
	"scout": preload("res://Scènes/Acteurs/scout.tscn"),
	"brute": preload("res://Scènes/Acteurs/brute.tscn"),
	"archer": preload("res://Scènes/Acteurs/archer.tscn"),
}

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
										 # (chunks de 9.6 m : 16 cubes de 0.6 m)
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
var _spawn_pos := Vector3.ZERO      # point d'apparition (terre ferme la plus proche de l'origine)

func _ready() -> void:
	chunk_size = Chunk.SIZE

	_make_hud()
	_make_underwater_overlay()
	_make_water_material()

	# Créé dès maintenant : les réglages sauvegardés (résolution, plein écran,
	# qualité...) s'appliquent au lancement, pas seulement une fois en jeu.
	_options = OPTIONS_MENU_SCENE.instantiate() as OptionsMenu
	_options.world = self
	add_child(_options)

	# Menu principal (personnages + mondes) : la génération n'existe qu'une
	# fois un monde choisi — sa graine vient de l'entrée de monde sauvegardée.
	_menu = MAIN_MENU_SCENE.instantiate() as MainMenu
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

	# La scène ne peut pas passer la graine au constructeur : setup() AVANT usage.
	gen = TERRAIN_GEN_SCENE.instantiate() as TerrainGen
	gen.setup(seed_value)
	add_child(gen)
	_make_day_night()
	# Le biome océan peut couvrir l'origine : on apparaît sur la terre ferme
	# la plus proche. Puis on construit tout de suite le chunk de spawn,
	# sinon le joueur tombe dans le vide.
	_spawn_pos = _find_spawn_pos()
	var w := chunk_size * Chunk.CUBE
	_build_chunk(Vector2i(floori(_spawn_pos.x / w), floori(_spawn_pos.z / w)))

	# Une scène par classe (class_id préréglé dedans).
	var id: String = character.get("class_id", "warrior")
	var scene: PackedScene = PLAYER_SCENES.get(id, PLAYER_SCENES["warrior"])
	player = scene.instantiate() as Player
	player.gen = gen # la nage sonde le terrain pour savoir où est l'eau
	add_child(player)
	player.global_position = _spawn_pos

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

	var inv := INVENTORY_UI_SCENE.instantiate() as InventoryUI
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

# Colonne émergée (hors plage) la plus proche de l'origine, en spirale par
# anneaux de 8 cubes. Déterministe : même seed => même point d'apparition.
func _find_spawn_pos() -> Vector3:
	for ring in 256:
		var d := ring * 8
		var pts: Array[Vector2i] = []
		if ring == 0:
			pts.append(Vector2i(0, 0))
		for i in range(-ring, ring + 1):
			if ring > 0:
				pts.append_array([Vector2i(i * 8, -d), Vector2i(i * 8, d),
					Vector2i(-d, i * 8), Vector2i(d, i * 8)])
		for p in pts:
			if float(gen.get_height(p.x, p.y)) + 0.5 >= TerrainGen.WATER_Y + 1.0:
				return Vector3(p.x * Chunk.CUBE + 0.25,
					(float(gen.get_height(p.x, p.y)) + 0.5) * Chunk.CUBE + 3.0,
					p.y * Chunk.CUBE + 0.25)
	return Vector3(0.25, _ground_y(0.0, 0.0) + 3.0, 0.25) # improbable : tout est océan

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
	var c := CHUNK_SCENE.instantiate() as Chunk
	c.gen = gen
	c.cx = key.x
	c.cz = key.y
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
	# Une scène par archétype (type_id préréglé dedans).
	var e := ENEMY_SCENES[_pick_enemy_type()].instantiate() as Enemy
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

# Le HUD (jauges PV/XP/spécial/endurance + labels, styles compris) est
# entièrement décrit dans Scènes/UI/ui.tscn : ici on ne fait plus que
# l'instancier et récupérer les nœuds à mettre à jour en jeu.
func _make_hud() -> void:
	_hud = UI_SCENE.instantiate() as CanvasLayer # invisible tant qu'aucune partie n'est lancée
	add_child(_hud)
	_hp_bar = _hud.get_node("HPBar")
	_xp_bar = _hud.get_node("XPBar")
	_level_label = _hud.get_node("LevelLabel")
	_class_label = _hud.get_node("ClassLabel")
	_special_bar = _hud.get_node("SpecialBar")
	_stamina_bar = _hud.get_node("StaminaBar")

func _make_water_material() -> void:
	var sh := Shader.new()
	sh.code = WATER_SHADER
	_water_mat = ShaderMaterial.new()
	_water_mat.shader = sh
	# L'eau se dessine EN DERNIER parmi les objets transparents : sinon, selon
	# l'angle de vue, la surface (depth_draw_always) passe avant la coque
	# gélatineuse du slime immergé et la découpe (coque invisible sous l'eau).
	_water_mat.render_priority = 1

# Le cycle jour/nuit pilote la lumière et l'environnement déjà posés dans world.tscn.
func _make_day_night() -> void:
	_day_night = DAY_NIGHT_SCENE.instantiate() as DayNight
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
	player.global_position = _spawn_pos
	player.velocity = Vector3.ZERO
