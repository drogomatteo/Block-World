class_name Player
extends CharacterBody3D

# Personnage jouable en 3e personne, façon Cube World.
# La classe (class_id, à définir AVANT add_child) détermine les stats, l'arme,
# l'attaque de base (mêlée ou projectile) et la compétence spéciale (clic droit).
# Tout le "rig" (corps, arme, caméra orbitale, hitbox) est construit en code.

const JUMP_VELOCITY := 6.5
const CAM_DISTANCE := 5.0
const DASH_SPEED := 18.0
const DASH_DURATION := 0.22

# Nage : on bascule en nage quand les pieds sont à SWIM_ENTER_DEPTH sous la
# surface (eau à hauteur de poitrine) ; la flottabilité ramène vers FLOAT_DEPTH
# (tête hors de l'eau). Espace = remonter, viser le fond + avancer = plonger.
# L'HYSTÉRÉSIS (sortie moins profonde que l'entrée) évite que le corps bascule
# en boucle nage/marche quand on flotte à la frontière en visant vers le haut.
const SWIM_ENTER_DEPTH := 1.05
const SWIM_EXIT_DEPTH := 0.80
const FLOAT_DEPTH := 1.25
const SWIM_SPEED_FACTOR := 0.65
const SWIM_UP_SPEED := 3.5
const WATER_DRAG := 25.0    # amortissement vertical (freine aussi le plongeon d'entrée)
const SWIM_ACCEL := 20.0    # accélération horizontale dans l'eau

# Endurance : consommée par le sprint (Maj) et la roulade (Ctrl), régénère
# après un court délai. La roulade rend invincible pendant sa durée (esquive).
const STAMINA_MAX := 100.0
const STAMINA_SPRINT_DRAIN := 16.0
const STAMINA_REGEN := 22.0
const STAMINA_REGEN_DELAY := 0.7
const ROLL_COST := 30.0
const ROLL_SPEED := 11.0
const ROLL_DURATION := 0.45

const CLASSES := {
	"warrior": {
		"name": "Guerrier", "color": Color(0.20, 0.42, 0.78),
		"health": 130, "damage": 34, "speed": 6.0, "attack_cooldown": 0.5,
		"ranged": false,
		"special_name": "Tourbillon", "special_cooldown": 5.0,
	},
	"ranger": {
		"name": "Rôdeur", "color": Color(0.22, 0.55, 0.28),
		"health": 90, "damage": 22, "speed": 6.5, "attack_cooldown": 0.55,
		"ranged": true, "projectile_speed": 26.0, "projectile_color": Color(0.45, 0.9, 0.35),
		"special_name": "Salve", "special_cooldown": 4.0,
	},
	"mage": {
		"name": "Mage", "color": Color(0.45, 0.25, 0.65),
		"health": 80, "damage": 30, "speed": 6.0, "attack_cooldown": 0.7,
		"ranged": true, "projectile_speed": 17.0, "projectile_color": Color(1.0, 0.55, 0.15),
		"special_name": "Nova", "special_cooldown": 6.0,
	},
	"rogue": {
		"name": "Roublard", "color": Color(0.35, 0.35, 0.38),
		"health": 95, "damage": 16, "speed": 7.5, "attack_cooldown": 0.25,
		"ranged": false,
		"special_name": "Ruée", "special_cooldown": 3.0,
	},
}

var class_id := "warrior" # à définir AVANT add_child
var gen: TerrainGen = null # posé par world.gd : sonde le terrain pour savoir où est l'eau

var mouse_sensitivity := 0.005 # réglable depuis le menu Options

var swimming := false # état de nage, lu par world.gd et les tests

var stamina := STAMINA_MAX # lue par world.gd pour la jauge du HUD
var _stamina_delay := 0.0  # délai avant régénération
var _roll_timer := 0.0
var _roll_dir := Vector3.ZERO

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

# Stats — initialisées depuis CLASSES dans _ready().
var max_health := 100
var health := 100
var attack_damage := 30
var attack_cooldown := 0.45
var move_speed := 6.0
var special_cooldown := 5.0
var special_timer := 0.0 # lu par world.gd pour la jauge du HUD
var _ranged := false
var _proj_speed := 20.0
var _proj_color := Color.WHITE
var _attack_timer := 0.0

var level := 1
var xp := 0
var xp_to_next := 100

# Équipement porté (un objet Items par slot, ou null) et sac à dos.
var equipment := {"weapon": null, "armor": null, "amulet": null}
var inventory: Array = []

var _pitch := -0.35
var _bob_t := 0.0 # phase de l'animation de marche

# Ruée (roublard)
var _dash_timer := 0.0
var _dash_dir := Vector3.ZERO
var _dash_hit: Array = []

var model: Node3D          # tourne vers la direction de déplacement
var weapon: Node3D         # arme tenue en main droite (pivot des animations)
var hitbox: Area3D         # zone d'attaque mêlée, enfant du modèle
var cam_pivot: Node3D      # yaw + pitch pilotés à la souris
var camera: Camera3D
var _lantern: Node3D       # lanterne tenue en main gauche (touche G)
var _lantern_light: OmniLight3D
# Membres animés (pivots aux hanches/épaules, la boîte du membre pend dessous).
var _arm_l: Node3D
var _arm_r: Node3D
var _leg_l: Node3D
var _leg_r: Node3D
var _offhand: Node3D       # dague main gauche du roublard (reconstruite avec l'arme)

signal health_changed(current: int, maximum: int)
signal xp_changed(current_xp: int, needed: int, level: int)
signal leveled_up(level: int)
signal inventory_changed
signal died

func _ready() -> void:
	add_to_group("player")
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	var c: Dictionary = CLASSES.get(class_id, CLASSES["warrior"])
	attack_cooldown = c["attack_cooldown"]
	special_cooldown = c["special_cooldown"]
	_ranged = c["ranged"]
	_proj_speed = c.get("projectile_speed", 20.0)
	_proj_color = c.get("projectile_color", Color.WHITE)
	_recompute_stats()
	health = max_health

	_build_body()
	_build_model(c["color"])
	_build_camera()
	_build_lantern()

func _build_body() -> void:
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	cs.shape = cap
	cs.position = Vector3(0, 0.9, 0) # origine du CharacterBody = aux pieds
	add_child(cs)

# Corps voxel articulé façon Cube World : jambes et bras sur des pivots animés,
# visage, ceinture, et une coiffe propre à chaque classe.
func _build_model(class_color: Color) -> void:
	model = Node3D.new()
	add_child(model)

	var skin := Color(0.94, 0.80, 0.62)
	var pants := class_color.darkened(0.45)

	# Torse + ceinture.
	model.add_child(_box(Vector3(0.56, 0.62, 0.34), class_color, Vector3(0, 0.86, 0)))
	model.add_child(_box(Vector3(0.58, 0.09, 0.36), class_color.darkened(0.6), Vector3(0, 0.585, 0)))

	# Jambes (pivot à la hanche, la jambe pend dessous).
	_leg_l = _limb(Vector3(-0.14, 0.55, 0), Vector3(0.19, 0.55, 0.23), pants)
	_leg_r = _limb(Vector3(0.14, 0.55, 0), Vector3(0.19, 0.55, 0.23), pants)

	# Bras (pivot à l'épaule) avec une petite main couleur peau.
	_arm_l = _limb(Vector3(-0.37, 1.10, 0), Vector3(0.16, 0.52, 0.18), class_color)
	_arm_r = _limb(Vector3(0.37, 1.10, 0), Vector3(0.16, 0.52, 0.18), class_color)
	for arm in [_arm_l, _arm_r]:
		arm.add_child(_box(Vector3(0.15, 0.12, 0.17), skin, Vector3(0, -0.50, 0)))

	# Tête + yeux.
	model.add_child(_box(Vector3(0.45, 0.45, 0.45), skin, Vector3(0, 1.40, 0)))
	var eye_col := Color(0.10, 0.10, 0.14)
	model.add_child(_box(Vector3(0.07, 0.11, 0.02), eye_col, Vector3(-0.10, 1.44, -0.235)))
	model.add_child(_box(Vector3(0.07, 0.11, 0.02), eye_col, Vector3(0.10, 1.44, -0.235)))

	_build_headgear(class_color)
	_build_weapon()

	hitbox = Area3D.new()
	var hcs := CollisionShape3D.new()
	var hshape := BoxShape3D.new()
	hshape.size = Vector3(1.6, 1.6, 2.0)
	hcs.shape = hshape
	hcs.position = Vector3(0, 0.8, -1.1) # devant le personnage
	hitbox.add_child(hcs)
	model.add_child(hitbox)

# Pivot de membre : le nœud est à l'articulation, la boîte pend en dessous —
# une rotation X du pivot balance le membre (marche, nage).
func _limb(pivot_pos: Vector3, size: Vector3, color: Color) -> Node3D:
	var pivot := Node3D.new()
	pivot.position = pivot_pos
	model.add_child(pivot)
	pivot.add_child(_box(size, color, Vector3(0, -size.y * 0.5, 0)))
	return pivot

# Coiffe / signe distinctif par classe.
func _build_headgear(class_color: Color) -> void:
	var metal := Color(0.72, 0.75, 0.82)
	match class_id:
		"warrior":
			# Casque : dôme + rebord + protège-nez.
			model.add_child(_box(Vector3(0.49, 0.16, 0.49), metal, Vector3(0, 1.60, 0), true))
			model.add_child(_box(Vector3(0.53, 0.06, 0.53), metal.darkened(0.2), Vector3(0, 1.52, 0), true))
			model.add_child(_box(Vector3(0.07, 0.16, 0.04), metal, Vector3(0, 1.42, -0.235), true))
			# Épaulières montées sur les bras (elles suivent le balancement).
			for arm in [_arm_l, _arm_r]:
				arm.add_child(_box(Vector3(0.24, 0.12, 0.24), metal, Vector3(0, 0.04, 0), true))
		"ranger":
			# Capuche + cape courte dans le dos.
			var hood := class_color.darkened(0.35)
			model.add_child(_box(Vector3(0.51, 0.16, 0.51), hood, Vector3(0, 1.60, 0)))
			model.add_child(_box(Vector3(0.49, 0.30, 0.08), hood, Vector3(0, 1.45, 0.24)))
			model.add_child(_box(Vector3(0.44, 0.55, 0.06), hood.darkened(0.15), Vector3(0, 0.92, 0.22)))
		"mage":
			# Chapeau pointu étagé.
			var hat := class_color.darkened(0.25)
			model.add_child(_box(Vector3(0.60, 0.05, 0.60), hat, Vector3(0, 1.635, 0)))
			model.add_child(_box(Vector3(0.36, 0.16, 0.36), hat, Vector3(0, 1.73, 0)))
			model.add_child(_box(Vector3(0.22, 0.16, 0.22), hat.lightened(0.1), Vector3(0, 1.87, 0)))
			model.add_child(_box(Vector3(0.10, 0.18, 0.10), hat.lightened(0.2), Vector3(0, 2.02, 0)))
		"rogue":
			# Bandana + nœud dans le dos, et un masque sur le bas du visage.
			var band := Color(0.22, 0.22, 0.26)
			model.add_child(_box(Vector3(0.47, 0.10, 0.47), band, Vector3(0, 1.56, 0)))
			model.add_child(_box(Vector3(0.10, 0.16, 0.06), band, Vector3(0.12, 1.48, 0.25)))
			model.add_child(_box(Vector3(0.46, 0.12, 0.10), band.lightened(0.1), Vector3(0, 1.30, -0.20)))

# L'arme est accrochée à la main droite (elle suit le balancement du bras) ;
# le roublard a une seconde dague dans la main gauche (_offhand).
func _build_weapon() -> void:
	weapon = Node3D.new()
	weapon.position = Vector3(0.03, -0.50, -0.10)
	_arm_r.add_child(weapon)
	match class_id:
		"warrior":
			weapon.add_child(_box(Vector3(0.1, 0.9, 0.1), Color(0.82, 0.84, 0.9), Vector3(0, 0.25, 0), true))
			weapon.add_child(_box(Vector3(0.26, 0.06, 0.08), Color(0.45, 0.35, 0.2), Vector3(0, -0.12, 0)))
		"ranger":
			weapon.add_child(_box(Vector3(0.07, 1.1, 0.07), Color(0.45, 0.30, 0.15), Vector3.ZERO))
			weapon.add_child(_box(Vector3(0.05, 0.30, 0.05), Color(0.45, 0.30, 0.15), Vector3(0, 0.62, -0.08)))
			weapon.add_child(_box(Vector3(0.05, 0.30, 0.05), Color(0.45, 0.30, 0.15), Vector3(0, -0.62, -0.08)))
		"mage":
			weapon.add_child(_box(Vector3(0.08, 1.3, 0.08), Color(0.30, 0.20, 0.12), Vector3.ZERO))
			weapon.add_child(_glow_box(Vector3(0.16, 0.16, 0.16), Color(1.0, 0.55, 0.15), Vector3(0, 0.72, 0)))
		"rogue":
			weapon.add_child(_box(Vector3(0.07, 0.45, 0.07), Color(0.75, 0.78, 0.85), Vector3(0, 0.12, 0), true))
	if class_id == "rogue":
		_offhand = Node3D.new()
		_offhand.position = Vector3(-0.03, -0.50, -0.10)
		_arm_l.add_child(_offhand)
		_offhand.add_child(_box(Vector3(0.07, 0.45, 0.07), Color(0.75, 0.78, 0.85), Vector3(0, 0.12, 0), true))

func _build_camera() -> void:
	cam_pivot = Node3D.new()
	cam_pivot.position = Vector3(0, 1.4, 0)
	cam_pivot.rotation.x = _pitch
	add_child(cam_pivot)

	# SpringArm3D : pousse la caméra vers +Z jusqu'à CAM_DISTANCE mais la
	# rapproche s'il y a un obstacle — la caméra ne traverse plus le terrain.
	var arm := SpringArm3D.new()
	arm.spring_length = CAM_DISTANCE
	arm.margin = 0.3
	# Cast avec une SPHÈRE plutôt que le rayon par défaut : un rayon passe à
	# côté des obstacles hors-axe (feuillage d'arbre...) alors que les coins du
	# champ de vision les traversent — la sphère couvre tout le cône de vue.
	var cam_shape := SphereShape3D.new()
	cam_shape.radius = 0.45
	arm.shape = cam_shape
	arm.add_excluded_object(get_rid()) # ne pas se cogner sur sa propre capsule
	cam_pivot.add_child(arm)

	# La caméra regarde son -Z, donc vers le personnage.
	camera = Camera3D.new()
	arm.add_child(camera)
	camera.current = true

# Lanterne tenue en main gauche (touche G) : éclaire tout autour du personnage.
# Cacher le nœud éteint aussi la lumière (visible se propage aux enfants).
func _build_lantern() -> void:
	_lantern = Node3D.new()
	_lantern.position = Vector3(0, -0.52, -0.16) # pend à la main gauche
	_lantern.visible = false
	_arm_l.add_child(_lantern)
	# Socle et toit sombres, cœur lumineux visible entre les deux, petit anneau.
	_lantern.add_child(_box(Vector3(0.16, 0.04, 0.16), Color(0.20, 0.18, 0.16), Vector3(0, -0.10, 0)))
	_lantern.add_child(_box(Vector3(0.16, 0.04, 0.16), Color(0.20, 0.18, 0.16), Vector3(0, 0.10, 0)))
	_lantern.add_child(_glow_box(Vector3(0.10, 0.16, 0.10), Color(1.0, 0.82, 0.45), Vector3.ZERO))
	_lantern.add_child(_box(Vector3(0.04, 0.05, 0.04), Color(0.25, 0.23, 0.20), Vector3(0, 0.15, 0)))

	_lantern_light = OmniLight3D.new()
	_lantern_light.omni_range = 14.0
	_lantern_light.light_energy = 2.2
	_lantern_light.light_color = Color(1.0, 0.85, 0.55)
	_lantern_light.shadow_enabled = true
	_lantern.add_child(_lantern_light)

func toggle_lantern() -> void:
	_lantern.visible = not _lantern.visible

func _box(size: Vector3, color: Color, pos: Vector3, metal := false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	if metal:
		m.metallic = 0.7
		m.roughness = 0.3
	bm.material = m
	mi.mesh = bm
	mi.position = pos
	return mi

func _glow_box(size: Vector3, color: Color, pos: Vector3) -> MeshInstance3D:
	var mi := _box(size, color, pos)
	var m: StandardMaterial3D = mi.mesh.material
	m.emission_enabled = true
	m.emission = color
	return mi

func _unhandled_input(event: InputEvent) -> void:
	# Échap et la capture de la souris sont gérés par OptionsMenu.
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		cam_pivot.rotation.y -= event.relative.x * mouse_sensitivity
		_pitch = clamp(_pitch - event.relative.y * mouse_sensitivity, deg_to_rad(-70), deg_to_rad(50))
		cam_pivot.rotation.x = _pitch
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_try_attack()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_try_special()
	elif event.is_action_pressed("lantern"):
		toggle_lantern()

func _physics_process(delta: float) -> void:
	_attack_timer = maxf(0.0, _attack_timer - delta)
	special_timer = maxf(0.0, special_timer - delta)

	# Endurance : régénère après un court délai sans dépense.
	_stamina_delay = maxf(0.0, _stamina_delay - delta)
	if _stamina_delay <= 0.0:
		stamina = minf(STAMINA_MAX, stamina + STAMINA_REGEN * delta)

	# Hystérésis : on entre en nage plus profond (poitrine) qu'on n'en sort.
	var depth := water_depth()
	swimming = depth > (SWIM_EXIT_DEPTH if swimming else SWIM_ENTER_DEPTH)

	if not swimming and not is_on_floor():
		velocity.y -= gravity * delta

	# Roulade (Ctrl) : trajectoire forcée, galipette du modèle, esquive
	# (take_damage ignore les dégâts tant que _roll_timer > 0).
	if _roll_timer > 0.0:
		_roll_timer -= delta
		velocity.x = _roll_dir.x * ROLL_SPEED
		velocity.z = _roll_dir.z * ROLL_SPEED
		_roll_pose(1.0 - maxf(_roll_timer, 0.0) / ROLL_DURATION)
		move_and_slide()
		return
	# Sortie de roulade : -TAU est identique à 0 visuellement mais pas pour le
	# lissage — on replie l'angle pour éviter un « rembobinage » du corps.
	model.rotation.x = wrapf(model.rotation.x, -PI, PI)
	model.position.x = 0.0
	model.position.z = 0.0

	# Ruée du roublard : trajectoire forcée + dégâts sur le passage.
	if _dash_timer > 0.0:
		_dash_timer -= delta
		velocity.x = _dash_dir.x * DASH_SPEED
		velocity.z = _dash_dir.z * DASH_SPEED
		_dash_damage()
		move_and_slide()
		return

	if swimming:
		_swim_process(delta, depth)
		return
	model.rotation.x = lerpf(model.rotation.x, 0.0, 8.0 * delta) # se redresse en sortant de l'eau

	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")

	# Déplacement relatif à l'orientation de la caméra (on ignore le pitch).
	var cam_basis := cam_pivot.global_transform.basis
	var forward := -cam_basis.z
	forward.y = 0.0
	forward = forward.normalized()
	var right := cam_basis.x
	right.y = 0.0
	right = right.normalized()
	var move_dir := (right * input_dir.x - forward * input_dir.y).normalized()

	if Input.is_action_just_pressed("roll") and is_on_floor() and stamina >= ROLL_COST:
		_start_roll(move_dir)
		return

	# Le sprint consomme de l'endurance ; à sec, on retombe à la vitesse normale.
	var sprinting := Input.is_key_pressed(KEY_SHIFT) and stamina > 0.5 and move_dir.length() > 0.01
	if sprinting:
		stamina = maxf(0.0, stamina - STAMINA_SPRINT_DRAIN * delta)
		_stamina_delay = STAMINA_REGEN_DELAY
	var speed := move_speed * (1.5 if sprinting else 1.0)

	if move_dir.length() > 0.01:
		velocity.x = move_dir.x * speed
		velocity.z = move_dir.z * speed
		# Le modèle pivote pour "regarder" la direction du mouvement.
		var target := atan2(-move_dir.x, -move_dir.z)
		model.rotation.y = lerp_angle(model.rotation.y, target, 12.0 * delta)
		# Rebond de marche + balancement bras/jambes.
		_bob_t += delta * speed
		model.position.y = absf(sin(_bob_t * 1.6)) * 0.07
		_swing_limbs(sin(_bob_t * 1.6) * 0.55, 0.8)
	else:
		velocity.x = move_toward(velocity.x, 0.0, speed)
		velocity.z = move_toward(velocity.z, 0.0, speed)
		model.position.y = move_toward(model.position.y, 0.0, delta)
		_relax_limbs(delta)

	move_and_slide()

# ---------- Membres / roulade ----------

# Balancement opposé jambes/bras (marche) ; arm_scale atténue les bras.
func _swing_limbs(swing: float, arm_scale: float) -> void:
	_leg_l.rotation.x = swing
	_leg_r.rotation.x = -swing
	_arm_l.rotation.x = -swing * arm_scale
	_arm_r.rotation.x = swing * arm_scale

func _relax_limbs(delta: float) -> void:
	for limb in [_leg_l, _leg_r, _arm_l, _arm_r]:
		limb.rotation.x = lerpf(limb.rotation.x, 0.0, minf(10.0 * delta, 1.0))

# Pose de galipette : le modèle tourne autour du CENTRE du corps (pas des
# pieds, son origine) — on compense avec un offset — et les membres se replient.
const ROLL_PIVOT_HEIGHT := 0.85

func _roll_pose(progress: float) -> void:
	model.rotation.x = -TAU * progress
	var c := Vector3.UP * ROLL_PIVOT_HEIGHT
	model.position = c - model.basis * c # le centre reste en place pendant la rotation
	for limb in [_arm_l, _arm_r]:
		limb.rotation.x = lerpf(limb.rotation.x, 1.3, 0.5)
	for limb in [_leg_l, _leg_r]:
		limb.rotation.x = lerpf(limb.rotation.x, 1.1, 0.5)

# Roulade : direction du déplacement demandé, sinon vers où regarde le modèle.
func _start_roll(move_dir: Vector3) -> void:
	var dir := move_dir
	if dir.length() < 0.01:
		dir = -model.global_transform.basis.z
		dir.y = 0.0
	_roll_dir = dir.normalized()
	_roll_timer = ROLL_DURATION
	stamina = maxf(0.0, stamina - ROLL_COST)
	_stamina_delay = STAMINA_REGEN_DELAY
	model.rotation.y = atan2(-_roll_dir.x, -_roll_dir.z) # face à la roulade
	_relax_limbs(1.0)

# ---------- Nage ----------

# Profondeur des pieds sous la surface de l'eau (0 si la colonne n'a pas d'eau :
# l'eau n'existe que là où le terrain passe sous WATER_Y — voir Chunk._build_water).
# TerrainGen travaille en indices de cube : conversion via Chunk.CUBE.
func water_depth() -> float:
	if gen == null:
		return 0.0
	var h := gen.get_height(roundi(global_position.x / Chunk.CUBE), roundi(global_position.z / Chunk.CUBE))
	if float(h) + 0.5 >= TerrainGen.WATER_Y:
		return 0.0
	return TerrainGen.WATER_Y * Chunk.CUBE - global_position.y

func _swim_process(delta: float, depth: float) -> void:
	var speed := move_speed * SWIM_SPEED_FACTOR * (1.4 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")

	# Contrairement à la marche, on garde le pitch de la caméra : viser le fond
	# et avancer fait plonger, viser la surface fait remonter.
	var cam_basis := cam_pivot.global_transform.basis
	var forward := -cam_basis.z
	var right := cam_basis.x
	right.y = 0.0
	right = right.normalized()
	var move_dir := right * input_dir.x - forward * input_dir.y
	if move_dir.length() > 0.01:
		move_dir = move_dir.normalized()
		var target := atan2(-move_dir.x, -move_dir.z)
		model.rotation.y = lerp_angle(model.rotation.y, target, 10.0 * delta)

	velocity.x = move_toward(velocity.x, move_dir.x * speed, SWIM_ACCEL * delta)
	velocity.z = move_toward(velocity.z, move_dir.z * speed, SWIM_ACCEL * delta)

	if Input.is_action_just_pressed("ui_accept") and depth < SWIM_ENTER_DEPTH + 0.3:
		velocity.y = JUMP_VELOCITY * 0.85 # près de la surface : bond pour sortir sur la rive
	else:
		# Flottabilité : on tend vers la profondeur d'équilibre (tête hors de l'eau).
		var target_v := clampf((TerrainGen.WATER_Y * Chunk.CUBE - FLOAT_DEPTH - global_position.y) * 2.5, -1.2, 2.5)
		# La nage vers le haut s'estompe près de la surface : viser le ciel ne
		# hisse pas hors de l'eau (sinon on oscille nage/marche) — le bond Espace, si.
		var lift := move_dir.y * speed
		if lift > 0.0:
			lift *= clampf((depth - SWIM_EXIT_DEPTH) / 0.5, 0.0, 1.0)
		target_v += lift
		if Input.is_action_pressed("ui_accept"):
			target_v = SWIM_UP_SPEED
		velocity.y = move_toward(velocity.y, target_v, WATER_DRAG * delta)

	# Le modèle bascule à l'horizontale quand on nage, avec une petite houle.
	var moving := input_dir.length() > 0.01
	var tilt := -1.25 if moving else -0.35
	model.rotation.x = lerpf(model.rotation.x, tilt, 5.0 * delta)
	_bob_t += delta * (4.5 if moving else 2.0)
	model.position.y = sin(_bob_t) * 0.05
	if moving:
		# Crawl : moulinets des bras en alternance + battements de jambes rapides.
		_arm_l.rotation.x = fposmod(_bob_t * 1.6, TAU)
		_arm_r.rotation.x = fposmod(_bob_t * 1.6 + PI, TAU)
		_leg_l.rotation.x = sin(_bob_t * 3.5) * 0.45
		_leg_r.rotation.x = -sin(_bob_t * 3.5) * 0.45
	else:
		# Surplace : petits mouvements des bras et des jambes pour flotter.
		_arm_l.rotation.x = sin(_bob_t) * 0.35
		_arm_r.rotation.x = -sin(_bob_t) * 0.35
		_leg_l.rotation.x = sin(_bob_t * 1.4) * 0.25
		_leg_r.rotation.x = -sin(_bob_t * 1.4) * 0.25

	move_and_slide()

# ---------- Attaques ----------

func _try_attack() -> void:
	if _attack_timer > 0.0:
		return
	_attack_timer = attack_cooldown
	if _ranged:
		_recoil()
		_shoot(1.0, 0.0)
	else:
		_swing()
		for body in hitbox.get_overlapping_bodies():
			if body.is_in_group("enemies") and body.has_method("take_damage"):
				body.take_damage(attack_damage, global_position)

# Tire un projectile dans la direction visée par la caméra (pitch inclus).
func _shoot(damage_mult: float, yaw_offset: float) -> void:
	var dir := -camera.global_transform.basis.z
	if yaw_offset != 0.0:
		dir = dir.rotated(Vector3.UP, yaw_offset)
	model.rotation.y = atan2(-dir.x, -dir.z) # le perso se tourne vers sa cible
	var p := Projectile.new()
	p.setup(dir, _proj_speed, int(round(attack_damage * damage_mult)), "enemies", _proj_color, "player")
	get_parent().add_child(p)
	p.global_position = global_position + Vector3(0, 1.2, 0) + dir * 0.9

func _try_special() -> void:
	if special_timer > 0.0:
		return
	special_timer = special_cooldown
	match class_id:
		"warrior":
			_special_spin()
		"ranger":
			_special_volley()
		"mage":
			_special_nova()
		"rogue":
			_special_dash()

# Guerrier — Tourbillon : dégâts à 360° autour de soi.
func _special_spin() -> void:
	_swing()
	_burst_effect(Color(0.85, 0.88, 1.0, 0.6), 3.4)
	_damage_around(3.4, 1.3)

# Rôdeur — Salve : 5 flèches en éventail.
func _special_volley() -> void:
	_recoil()
	for deg in [-16.0, -8.0, 0.0, 8.0, 16.0]:
		_shoot(0.8, deg_to_rad(deg))

# Mage — Nova : explosion de feu autour de soi.
func _special_nova() -> void:
	_burst_effect(Color(1.0, 0.5, 0.1, 0.7), 4.5)
	_damage_around(4.5, 1.6)

# Roublard — Ruée : fonce en avant en blessant les ennemis traversés.
func _special_dash() -> void:
	_dash_timer = DASH_DURATION
	_dash_hit.clear()
	var f := -model.global_transform.basis.z
	f.y = 0.0
	_dash_dir = f.normalized() if f.length() > 0.01 else Vector3.FORWARD
	_swing()

func _dash_damage() -> void:
	for e in get_tree().get_nodes_in_group("enemies"):
		if e in _dash_hit:
			continue
		if e is Node3D and e.global_position.distance_to(global_position) <= 1.8 and e.has_method("take_damage"):
			_dash_hit.append(e)
			e.take_damage(int(round(attack_damage * 1.5)), global_position)

func _damage_around(radius: float, mult: float) -> void:
	for e in get_tree().get_nodes_in_group("enemies"):
		if e is Node3D and e.global_position.distance_to(global_position) <= radius and e.has_method("take_damage"):
			e.take_damage(int(round(attack_damage * mult)), global_position)

# Anneau lumineux qui s'étend au sol (feedback visuel des spéciaux de zone).
func _burst_effect(col: Color, radius: float) -> void:
	var fx := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 1.0
	cm.bottom_radius = 1.0
	cm.height = 0.15
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(col.r, col.g, col.b)
	cm.material = mat
	fx.mesh = cm
	add_child(fx)
	fx.position = Vector3(0, 0.5, 0)
	fx.scale = Vector3(0.1, 1, 0.1)
	var t := create_tween()
	t.set_parallel(true)
	t.tween_property(fx, "scale", Vector3(radius, 1.0, radius), 0.3)
	t.tween_property(mat, "albedo_color:a", 0.0, 0.3)
	t.chain().tween_callback(fx.queue_free)

func _swing() -> void:
	var t := create_tween()
	weapon.rotation_degrees = Vector3(-130, 0, 0)
	t.tween_property(weapon, "rotation_degrees:x", 40.0, 0.12)
	t.tween_property(weapon, "rotation_degrees:x", 0.0, 0.12)

func _recoil() -> void:
	weapon.position.z = -0.07 # petit recul de l'arme vers l'arrière
	var t := create_tween()
	t.tween_property(weapon, "position:z", -0.25, 0.15)

# ---------- Équipement / inventaire ----------

# Stats finales = base de classe + progression de niveau + bonus d'équipement.
func _recompute_stats() -> void:
	var c: Dictionary = CLASSES.get(class_id, CLASSES["warrior"])
	var bonus_hp := 0
	var bonus_dmg := 0
	var bonus_speed := 0.0
	for slot in equipment:
		var it = equipment[slot]
		if it != null:
			bonus_hp += it.get("health", 0)
			bonus_dmg += it.get("damage", 0)
			bonus_speed += it.get("speed", 0.0)
	max_health = int(c["health"]) + 20 * (level - 1) + bonus_hp
	attack_damage = int(c["damage"]) + 6 * (level - 1) + bonus_dmg
	move_speed = float(c["speed"]) + bonus_speed
	health = mini(health, max_health)
	health_changed.emit(health, max_health)

# Appelé par Pickup quand on ramasse un objet au sol.
func add_item(item: Dictionary) -> void:
	inventory.append(item)
	inventory_changed.emit()

func equip_from_inventory(index: int) -> void:
	if index < 0 or index >= inventory.size():
		return
	var item: Dictionary = inventory[index]
	var slot: String = item["slot"]
	inventory.remove_at(index)
	if equipment[slot] != null:
		inventory.append(equipment[slot]) # l'ancien objet retourne au sac
	equipment[slot] = item
	_recompute_stats()
	if slot == "weapon":
		_refresh_weapon_visual()
	inventory_changed.emit()

func unequip(slot: String) -> void:
	if equipment.get(slot) == null:
		return
	inventory.append(equipment[slot])
	equipment[slot] = null
	_recompute_stats()
	if slot == "weapon":
		_refresh_weapon_visual()
	inventory_changed.emit()

func discard_item(index: int) -> void:
	if index < 0 or index >= inventory.size():
		return
	inventory.remove_at(index)
	inventory_changed.emit()

# Reconstruit l'arme visible ; si une arme est équipée, elle luit de la
# couleur de sa rareté (feedback visuel du loot).
func _refresh_weapon_visual() -> void:
	weapon.queue_free()
	if _offhand != null:
		_offhand.queue_free()
		_offhand = null
	_build_weapon()
	var it = equipment["weapon"]
	if it == null:
		return
	var col: Color = Items.RARITY_COLORS[it["rarity"]]
	var parts := weapon.get_children()
	if _offhand != null:
		parts.append_array(_offhand.get_children())
	for child in parts:
		if child is MeshInstance3D and child.mesh != null and child.mesh.material is StandardMaterial3D:
			var m: StandardMaterial3D = child.mesh.material
			m.emission_enabled = true
			m.emission = col
			m.emission_energy_multiplier = 0.4

# ---------- Stats / progression ----------

# Émet l'état courant : appelé par world.gd une fois le HUD branché.
func broadcast_stats() -> void:
	health_changed.emit(health, max_health)
	xp_changed.emit(xp, xp_to_next, level)

func gain_xp(amount: int) -> void:
	xp += amount
	while xp >= xp_to_next:
		xp -= xp_to_next
		_level_up()
	xp_changed.emit(xp, xp_to_next, level)

func _level_up() -> void:
	level += 1
	xp_to_next = int(round(xp_to_next * 1.35))
	_recompute_stats()
	health = max_health # remontée à fond au level-up
	health_changed.emit(health, max_health)
	leveled_up.emit(level)

func heal(amount: int) -> void:
	health = mini(max_health, health + amount)
	health_changed.emit(health, max_health)

func take_damage(amount: int, _from: Vector3 = Vector3.ZERO) -> void:
	if _roll_timer > 0.0:
		return # esquive : invincible pendant la roulade
	health = maxi(0, health - amount)
	FX.damage_number(get_parent(), global_position + Vector3(0, 1.9, 0), amount, Color(1.0, 0.3, 0.25))
	health_changed.emit(health, max_health)
	if health <= 0:
		_die()

func _die() -> void:
	health = max_health
	health_changed.emit(health, max_health)
	died.emit() # world.gd replace le joueur au spawn
