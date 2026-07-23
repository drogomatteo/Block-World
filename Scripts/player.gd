class_name Player
extends CharacterBody3D

# Personnage jouable en 3e personne, façon Cube World. LOGIQUE UNIQUEMENT :
# le corps voxel, l'arme, la caméra orbitale, la hitbox et les clips
# d'animation (walk/idle/swim/roll + attack/recoil) vivent dans les scènes de
# classe Scènes/Acteurs/*.tscn (régénérables par tools/gen_actor_scenes.gd).
# Ici on récupèhtre les nœuds, on pilote les AnimationPlayer (play/speed_scale)
# et on applique les stats de CLASSES (class_id préréglé par la scène).

const PROJECTILE_SCENE := preload("res://Scènes/Objets/projectile.tscn")

const JUMP_VELOCITY := 6.5
const DASH_SPEED := 18.0
const DASH_DURATION := 0.22

# Auto-montée : une marche d'AU PLUS un cube n'est pas un obstacle — le joueur
# est posé INSTANTANÉMENT dessus, sans saut ni perte de vitesse. Pilotée par
# les COLLISIONS réelles (après move_and_slide), pas par une prédiction sur le
# terrain. Au-delà d'un cube (mur de 2+), il faut toujours sauter.
const AUTO_STEP_MAX := 1.1  # hauteur max de marche, en cubes (marge d'arrondi)

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

@export var class_id := "warrior" # préréglé par les scènes Scènes/Acteurs/*.tscn
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
var _offhand: Node3D       # dague main gauche du roublard (null pour les autres)
var _roll_center: Node3D   # pivot au centre du corps, animé par le clip "roll"
var _anim: AnimationPlayer      # locomotion : walk / idle / swim_move / swim_idle / roll
var _gear_anim: AnimationPlayer # arme : attack / recoil (joué par-dessus la locomotion)
var _weapon_base_mesh := {}     # mesh d'origine (scène) de chaque partie de l'arme

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

	# Le corps, l'arme, la caméra et les animations sont dans la scène de
	# classe : on ne fait que récupérer les nœuds que la logique pilote.
	model = $Model
	_roll_center = $Model/RollCenter
	_leg_l = $Model/RollCenter/LegL
	_leg_r = $Model/RollCenter/LegR
	_arm_l = $Model/RollCenter/ArmL
	_arm_r = $Model/RollCenter/ArmR
	weapon = _arm_r.get_node("Weapon")
	_offhand = _arm_l.get_node_or_null("Offhand")
	_lantern = _arm_l.get_node("Lantern")
	_lantern_light = _lantern.get_node("LanternLight")
	hitbox = $Model/Hitbox
	cam_pivot = $CamPivot
	camera = $CamPivot/SpringArm/Camera
	_anim = $Anim
	_gear_anim = $GearAnim

	cam_pivot.rotation.x = _pitch
	# Ne pas cogner la caméra sur sa propre capsule (RID connu qu'au runtime).
	($CamPivot/SpringArm as SpringArm3D).add_excluded_object(get_rid())

	# Les meshes de l'arme deviennent uniques à CETTE instance : la lueur de
	# rareté (équipement) ne doit pas contaminer les ressources partagées de
	# la scène, rechargées telles quelles à la prochaine partie.
	for mi in _weapon_meshes():
		_weapon_base_mesh[mi] = mi.mesh
		mi.mesh = mi.mesh.duplicate(true)

func _weapon_meshes() -> Array:
	var parts := weapon.get_children()
	if _offhand != null:
		parts.append_array(_offhand.get_children())
	return parts.filter(func(n): return n is MeshInstance3D and n.mesh != null)

func toggle_lantern() -> void:
	_lantern.visible = not _lantern.visible

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
	elif event.is_action_pressed("Lantern"):
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

	# Roulade (Ctrl) : trajectoire forcée, esquive (take_damage ignore les
	# dégâts tant que _roll_timer > 0). La galipette est le clip "roll",
	# lancé par _start_roll.
	if _roll_timer > 0.0:
		_roll_timer -= delta
		velocity.x = _roll_dir.x * ROLL_SPEED
		velocity.z = _roll_dir.z * ROLL_SPEED
		# Si la roulade part de la nage, le corps était basculé : on le redresse.
		model.rotation.x = lerpf(model.rotation.x, 0.0, 8.0 * delta)
		move_and_slide()
		return

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

	if Input.is_action_pressed("Jump") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	var input_dir := Input.get_vector("Go left", "Go right", "Go forward", "Go backward")

	# Déplacement relatif à l'orientation de la caméra (on ignore le pitch).
	var cam_basis := cam_pivot.global_transform.basis
	var forward := -cam_basis.z
	forward.y = 0.0
	forward = forward.normalized()
	var right := cam_basis.x
	right.y = 0.0
	right = right.normalized()
	var move_dir := (right * input_dir.x - forward * input_dir.y).normalized()

	if Input.is_action_just_pressed("Roll") and is_on_floor() and stamina >= ROLL_COST:
		_start_roll(move_dir)
		return

	# Le sprint consomme de l'endurance ; à sec, on retombe à la vitesse normale.
	var sprinting := Input.is_action_pressed("Run") and stamina > 0.5 and move_dir.length() > 0.01
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
		# Rebond + balancement des membres : clip "walk", cadencé par la vitesse.
		_play_move("walk", speed)
	else:
		velocity.x = move_toward(velocity.x, 0.0, speed)
		velocity.z = move_toward(velocity.z, 0.0, speed)
		_play_move("idle", 1.0)

	move_and_slide()
	_auto_step(move_dir)

# ---------- Auto-montée ----------

# Appelée APRÈS move_and_slide : on n'agit que si le corps a RÉELLEMENT buté
# contre un mur bas face au déplacement (get_slide_collision), plus aucune
# prédiction sur le terrain — donc jamais soulevé « pour rien » sans finir sur
# le bloc. La place au-dessus de la marche est validée avec la vraie capsule
# (test_move) : marche décentrée gravie, fente plus étroite que le corps, mur
# de 2+ cubes ou tronc d'arbre refusés d'office. Si c'est libre : on monte,
# on avance sur la marche et on redescend au contact du sol.
func _auto_step(move_dir: Vector3) -> void:
	if not is_on_floor() or move_dir.length() < 0.01:
		return
	var blocked := false
	for i in get_slide_collision_count():
		var n := get_slide_collision(i).get_normal()
		if n.y < 0.5 and n.dot(move_dir) < -0.5:
			blocked = true
			break
	if not blocked:
		return
	var up := Vector3.UP * (Chunk.CUBE * AUTO_STEP_MAX)
	var fwd := move_dir * 0.25
	if test_move(global_transform, up) \
			or test_move(global_transform.translated(up), fwd):
		return # pas la place au-dessus : vrai obstacle, il faudra sauter
	global_position += up + fwd
	move_and_collide(Vector3.DOWN * (Chunk.CUBE * AUTO_STEP_MAX + 0.05))

# ---------- Animations / roulade ----------

# Pilote le clip de locomotion : speed règle la cadence (speed_scale, l'ancien
# phase += delta * vitesse) et le changement de clip est fondu pour éviter les
# sauts de pose.
func _play_move(anim_name: String, speed: float, blend := 0.25) -> void:
	_anim.speed_scale = speed
	if _anim.current_animation != anim_name:
		_anim.play(anim_name, blend)

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
	_play_move("roll", 1.0, 0.1)

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
	var speed := move_speed * SWIM_SPEED_FACTOR * (1.4 if Input.is_action_pressed("Run") else 1.0)
	var input_dir := Input.get_vector("Go left", "Go right", "Go forward", "Go backward")

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

	# Roulade dans l'eau : autorisée seulement si on a PIED (contact au sol) —
	# en pleine flottaison, pas d'appui, donc pas d'esquive.
	if Input.is_action_just_pressed("Roll") and is_on_floor() and stamina >= ROLL_COST:
		var flat := Vector3(move_dir.x, 0.0, move_dir.z)
		_start_roll(flat)
		return

	if Input.is_action_just_pressed("Jump") and depth < SWIM_ENTER_DEPTH + 0.3:
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
		if Input.is_action_pressed("Jump"):
			target_v = SWIM_UP_SPEED
		velocity.y = move_toward(velocity.y, target_v, WATER_DRAG * delta)

	# Le modèle bascule à l'horizontale quand on nage ; crawl (moulinets +
	# battements) ou surplace : clips de la scène.
	var moving := input_dir.length() > 0.01
	var tilt := -1.25 if moving else -0.35
	model.rotation.x = lerpf(model.rotation.x, tilt, 5.0 * delta)
	_play_move("swim_move" if moving else "swim_idle", 4.5 if moving else 2.0)

	move_and_slide()

# ---------- Attaques ----------

func _try_attack() -> void:
	if _attack_timer > 0.0 or _roll_timer > 0.0:
		return # pas d'attaque pendant la roulade (esquive, pas offensive)
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
	var p := PROJECTILE_SCENE.instantiate() as Projectile
	p.setup(dir, _proj_speed, int(round(attack_damage * damage_mult)), "enemies", _proj_color, "player")
	get_parent().add_child(p)
	p.global_position = global_position + Vector3(0, 1.2, 0) + dir * 0.9

func _try_special() -> void:
	if special_timer > 0.0 or _roll_timer > 0.0:
		return # pas de spécial pendant la roulade non plus
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

# Coup d'arme / recul d'arc : clips du GearAnim de la scène, joués par-dessus
# la locomotion (le GearAnim est après Anim dans l'arbre : sa pose gagne).
func _swing() -> void:
	_gear_anim.stop()
	_gear_anim.play("attack")

func _recoil() -> void:
	_gear_anim.stop()
	_gear_anim.play("recoil")

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

# Rafraîchit l'arme de la scène : repart du mesh d'origine, puis si une arme
# est équipée, la fait luire de la couleur de sa rareté (feedback du loot).
func _refresh_weapon_visual() -> void:
	for mi in _weapon_meshes():
		mi.mesh = _weapon_base_mesh[mi].duplicate(true)
	var it = equipment["weapon"]
	if it == null:
		return
	var col: Color = Items.RARITY_COLORS[it["rarity"]]
	for mi in _weapon_meshes():
		if mi.mesh.material is StandardMaterial3D:
			var m: StandardMaterial3D = mi.mesh.material
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
