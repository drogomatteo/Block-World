class_name Enemy
extends CharacterBody3D

# Ennemi piloté par archétype (type_id, préréglé par les scènes d'Acteurs).
# LOGIQUE UNIQUEMENT : le corps voxel et les clips d'animation (walk/idle/
# swim/roll + attack/draw) vivent dans Scènes/Acteurs/<type>.tscn
# (régénérables par tools/gen_actor_scenes.gd) ; ici on récupère les nœuds et
# on pilote les AnimationPlayer.
# IA : hors aggro ils errent ; en aggro les mêlée chassent (en sautant les
# obstacles d'un ou deux blocs), l'éclaireur approche en zigzag et esquive en
# roulade, l'archer garde ses distances en se déplaçant latéralement et tire
# en anticipant le déplacement du joueur. Les types "agiles" ont une endurance
# qui limite leurs roulades (invincibles pendant la roulade, comme le joueur).
# À la mort : lâche de l'XP (+ parfois un soin / un équipement).

const PROJECTILE_SCENE := preload("res://Scènes/Objets/projectile.tscn")
const PICKUP_SCENE := preload("res://Scènes/Objets/pickup.tscn")

const AGGRO_RANGE := 18.0
const ATTACK_RANGE := 1.9
const ATTACK_COOLDOWN := 1.1
const RANGED_KEEP := 8.0
const RANGED_COOLDOWN := 1.6
const PROJECTILE_SPEED := 16.0
const JUMP_VELOCITY := 6.2
const JUMP_COOLDOWN := 0.5
const ROLL_SPEED := 8.5
const ROLL_DURATION := 0.4
const ROLL_COST := 30.0
const STAMINA_MAX := 60.0
const STAMINA_REGEN := 14.0

const TYPES := {
	"slime": {"color": Color(0.35, 0.78, 0.35), "size": 0.7, "health": 40, "speed": 2.5, "damage": 6, "xp": 15,
		"ranged": false, "hops": true, "agile": false, "zigzag": false},
	"scout": {"color": Color(0.90, 0.80, 0.20), "size": 0.65, "health": 32, "speed": 5.5, "damage": 8, "xp": 20,
		"ranged": false, "hops": false, "agile": true, "zigzag": true},
	"brute": {"color": Color(0.80, 0.22, 0.20), "size": 1.05, "health": 120, "speed": 2.1, "damage": 20, "xp": 50,
		"ranged": false, "hops": false, "agile": false, "zigzag": false},
	"archer": {"color": Color(0.60, 0.32, 0.82), "size": 0.75, "health": 45, "speed": 3.0, "damage": 9, "xp": 32,
		"ranged": true, "hops": false, "agile": true, "zigzag": false},
}

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
@export var type_id := "slime" # préréglé par les scènes Scènes/Acteurs/*.tscn

var max_health := 40
var health := 40
var _speed := 3.0
var _damage := 8
var _xp := 15
var _ranged := false
var _hops := false
var _agile := false
var _zigzag := false
var _color := Color.WHITE
var _size := 0.7
var _attack_timer := 0.0
var _jump_timer := 0.0     # anti-rebond du saut d'obstacle / cadence des bonds du slime
var _strafe_t := 0.0       # phase des déplacements latéraux (archer/zigzag)
var _stamina := STAMINA_MAX
var _roll_timer := 0.0
var _roll_dir := Vector3.ZERO
var _wander_timer := 0.0
var _wander_dir := Vector3.ZERO
var _body_mat: StandardMaterial3D
var _base_albedo := Color.WHITE # albedo d'origine du torse (restauré après le flash)
var player: Node3D
var _gen: TerrainGen = null # récupéré sur le World parent (flottaison dans l'eau)
var _blob: MeshInstance3D = null # ombre ronde posée au sol

var model: Node3D          # tous les visuels (s'écrase pour le slime)
var _roll_center: Node3D   # pivot central de la galipette (humanoïdes)
var _anim: AnimationPlayer      # locomotion (null pour le slime)
var _gear_anim: AnimationPlayer # attaque / recul d'arc (par-dessus la marche)
var _arm_l: Node3D
var _arm_r: Node3D
var _leg_l: Node3D
var _leg_r: Node3D

func _ready() -> void:
	add_to_group("enemies")
	var t: Dictionary = TYPES.get(type_id, TYPES["slime"])
	_color = t["color"]
	_size = t["size"]
	max_health = t["health"]
	health = max_health
	_speed = t["speed"]
	_damage = t["damage"]
	_xp = t["xp"]
	_ranged = t["ranged"]
	_hops = t["hops"]
	_agile = t["agile"]
	_zigzag = t["zigzag"]
	var parent := get_parent()
	if parent != null:
		_gen = parent.get("gen")
	_strafe_t = randf() * TAU # déphase les ennemis entre eux

	# Corps et animations : dans la scène d'archétype. On récupère les nœuds
	# pilotés, et on rend le mesh du corps unique à CETTE instance — sinon le
	# flash de dégâts blanchirait tous les ennemis partageant la ressource.
	model = $Model
	_anim = get_node_or_null("Anim")
	_gear_anim = get_node_or_null("GearAnim")
	var body_mesh: MeshInstance3D
	if _hops:
		body_mesh = $Model/Body
	else:
		_roll_center = $Model/RollCenter
		_leg_l = $Model/RollCenter/LegL
		_leg_r = $Model/RollCenter/LegR
		_arm_l = $Model/RollCenter/ArmL
		_arm_r = $Model/RollCenter/ArmR
		body_mesh = $Model/RollCenter/Torso
	body_mesh.mesh = body_mesh.mesh.duplicate(true)
	_body_mat = body_mesh.mesh.material
	_base_albedo = _body_mat.albedo_color

	# Ombre ronde sous l'ennemi, dimensionnée sur son gabarit.
	_blob = FX.blob_shadow(_size * 0.8)
	add_child(_blob)

# ---------- IA ----------

func _physics_process(delta: float) -> void:
	_attack_timer = maxf(0.0, _attack_timer - delta)
	_jump_timer = maxf(0.0, _jump_timer - delta)
	if _gen != null:
		var bh := _gen.get_height(roundi(global_position.x / Chunk.CUBE), roundi(global_position.z / Chunk.CUBE))
		var gy := (float(bh) + 0.5) * Chunk.CUBE # dessus du terrain (déjà calculé pour l'ombre)
		# Sol analytique : hors de la zone de chunks chargés il n'y a aucun
		# collider — le générateur retient l'ennemi au niveau du terrain au
		# lieu de le laisser tomber dans le vide. Seulement hors zone chargée :
		# sur un chunk chargé, la vraie collision fait foi (près d'un muret, la
		# colonne arrondie pourrait être la voisine plus haute).
		var w := get_parent()
		if global_position.y < gy and w != null and w.has_method("has_chunk_at") \
				and not w.has_chunk_at(global_position):
			global_position.y = gy
			velocity.y = maxf(velocity.y, 0.0)
		# L'ombre ronde colle au sol sous l'ennemi (même en saut/flottaison).
		if _blob != null:
			_blob.global_position = Vector3(global_position.x, gy + 0.03, global_position.z)
	_strafe_t += delta
	if _agile:
		_stamina = minf(STAMINA_MAX, _stamina + STAMINA_REGEN * delta)

	# Dans l'eau (colonne immergée + assez profond) : flottaison, pas de gravité.
	var depth := _water_depth()
	var in_water := depth > _size

	if not in_water and not is_on_floor():
		velocity.y -= gravity * delta

	# Roulade en cours : trajectoire forcée + invincibilité. La galipette est
	# le clip "roll" (lancé par _try_roll), autour du pivot RollCenter.
	if _roll_timer > 0.0:
		_roll_timer -= delta
		velocity.x = _roll_dir.x * ROLL_SPEED
		velocity.z = _roll_dir.z * ROLL_SPEED
		move_and_slide()
		return

	if player == null or not is_instance_valid(player):
		player = get_tree().get_first_node_in_group("player")

	# Hors du rayon d'affichage (limite des chunks/brume), l'ennemi n'est plus
	# DESSINÉ ni animé — mais il continue de vivre : position, IA, physique.
	# Il réapparaît en entrant dans le rayon. Hystérésis ±2 m anti-clignotement.
	if player != null and is_instance_valid(player):
		var wrld := get_parent()
		if wrld != null and wrld.has_method("view_dist_m"):
			var vd: float = wrld.view_dist_m()
			var pdist := global_position.distance_to(player.global_position)
			if visible and pdist > vd + 2.0:
				visible = false
				if _anim != null:
					_anim.pause() # squelette figé : zéro coût d'animation caché
			elif not visible and pdist < vd - 2.0:
				visible = true
				if _anim != null and _anim.current_animation != "":
					_anim.play(_anim.current_animation)

	var move := Vector3.ZERO
	var speed := _speed
	if player != null and is_instance_valid(player):
		var to_player: Vector3 = player.global_position - global_position
		var dist := to_player.length()
		to_player.y = 0.0
		var flat := to_player.normalized() if to_player.length() > 0.05 else Vector3.ZERO
		var side := flat.cross(Vector3.UP)

		if dist <= AGGRO_RANGE and flat != Vector3.ZERO:
			rotation.y = lerp_angle(rotation.y, atan2(-flat.x, -flat.z), 8.0 * delta)
			if _ranged:
				# Archer : distance idéale + déplacement latéral permanent,
				# roulade de dégagement si le joueur arrive au contact.
				move = side * sin(_strafe_t * 1.6) * 0.7
				if dist < RANGED_KEEP - 1.5:
					move -= flat
				elif dist > RANGED_KEEP + 2.0:
					move = flat
				if dist < 4.0 and _try_roll((side if sin(_strafe_t * 3.7) > 0.0 else -side) - flat):
					move_and_slide()
					return
				_try_shoot()
			elif dist <= ATTACK_RANGE:
				_try_melee()
			else:
				move = flat
				# Éclaireur : approche en zigzag, esquive parfois en roulade.
				if _zigzag:
					move = (flat + side * sin(_strafe_t * 2.6) * 0.8).normalized()
					if dist < 7.0 and randf() < 0.45 * delta and _try_roll(side * signf(sin(_strafe_t))):
						move_and_slide()
						return
		else:
			# Hors aggro : errance tranquille (pause ou balade lente).
			_wander_timer -= delta
			if _wander_timer <= 0.0:
				_wander_timer = randf_range(1.5, 3.5)
				_wander_dir = Vector3.ZERO if randf() < 0.45 \
					else Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0)).normalized()
			move = _wander_dir
			speed = _speed * 0.45
			if move.length() > 0.1:
				rotation.y = lerp_angle(rotation.y, atan2(-move.x, -move.z), 6.0 * delta)

	# Anti-agglutinement : répulsion douce entre ennemis proches.
	move += _separation() * 0.8
	if move.length() > 1.0:
		move = move.normalized()

	if _hops:
		# Slime : se déplace uniquement par bonds.
		if is_on_floor():
			if move.length() > 0.1 and _jump_timer <= 0.0:
				velocity = Vector3(move.x * _speed * 1.8, 4.8, move.z * _speed * 1.8)
				_jump_timer = randf_range(0.55, 0.95)
			else:
				velocity.x = move_toward(velocity.x, 0.0, 20.0 * delta)
				velocity.z = move_toward(velocity.z, 0.0, 20.0 * delta)
		# en l'air : on garde l'élan du bond
	else:
		velocity.x = move.x * speed
		velocity.z = move.z * speed

	if in_water:
		# Remonte flotter la tête à la surface (les lacs ne noient personne).
		velocity.y = move_toward(velocity.y,
			clampf((TerrainGen.WATER_Y * Chunk.CUBE - _size * 1.3 - global_position.y) * 3.0, -1.0, 3.0), 15.0 * delta)

	move_and_slide()

	# Bloqué contre un mur en avançant : saute — les marches d'un ou deux blocs
	# n'arrêtent plus la poursuite.
	if not _hops and is_on_floor() and is_on_wall() and move.length() > 0.2 and _jump_timer <= 0.0:
		velocity.y = JUMP_VELOCITY
		_jump_timer = JUMP_COOLDOWN

	if visible: # caché hors du rayon d'affichage : on n'anime pas dans le vide
		_animate(delta, move, in_water)

# Profondeur des pieds sous la surface (0 si la colonne n'a pas d'eau).
# TerrainGen travaille en indices de cube : conversion via Chunk.CUBE.
func _water_depth() -> float:
	if _gen == null:
		return 0.0
	var h := _gen.get_height(roundi(global_position.x / Chunk.CUBE), roundi(global_position.z / Chunk.CUBE))
	if float(h) + 0.5 >= TerrainGen.WATER_Y:
		return 0.0
	return TerrainGen.WATER_Y * Chunk.CUBE - global_position.y

func _separation() -> Vector3:
	var push := Vector3.ZERO
	for e in get_tree().get_nodes_in_group("enemies"):
		if e == self or not (e is Node3D):
			continue
		var d: Vector3 = global_position - e.global_position
		d.y = 0.0
		var l: float = d.length()
		if l < 1.4 and l > 0.001:
			push += d / (l * l)
	return push.limit_length(1.0)

# Roulade d'esquive (types agiles) : coûte de l'endurance.
# Dans l'eau, elle n'est permise que si l'ennemi a PIED (contact au sol) —
# même règle que le joueur : pas d'esquive en pleine flottaison.
func _try_roll(dir: Vector3) -> bool:
	if not _agile or _stamina < ROLL_COST or _roll_timer > 0.0:
		return false
	if _water_depth() > _size and not is_on_floor():
		return false
	dir.y = 0.0
	if dir.length() < 0.01:
		return false
	_stamina -= ROLL_COST
	_roll_dir = dir.normalized()
	_roll_timer = ROLL_DURATION
	_play_move("roll", 1.0, 0.1)
	return true

# Pilote le clip de locomotion (voir la scène) : speed règle la cadence,
# le changement de clip est fondu. Le slime n'a pas d'AnimationPlayer.
func _play_move(anim_name: String, speed: float, blend := 0.25) -> void:
	if _anim == null:
		return
	_anim.speed_scale = speed
	if _anim.current_animation != anim_name:
		_anim.play(anim_name, blend)

func _animate(delta: float, move: Vector3, in_water := false) -> void:
	if _hops:
		# Slime : s'étire en l'air, s'écrase à l'atterrissage. Piloté en code
		# (pas un clip) : la pose dépend de la physique (bond, chute, flottaison).
		var target_s := 1.0
		if in_water:
			target_s = 1.0 + sin(_strafe_t * 3.0) * 0.06 # ondule en flottant
		elif not is_on_floor():
			target_s = 1.18
		elif _jump_timer > 0.3:
			target_s = 0.84
		model.scale.y = lerpf(model.scale.y, target_s, minf(12.0 * delta, 1.0))
		return
	if _leg_l == null:
		return
	if in_water:
		# Nage : le corps bascule vers l'avant (physique -> code), bras/jambes
		# par le clip "swim" — cohérent avec le crawl du joueur.
		model.rotation.x = lerpf(model.rotation.x, -0.9 if move.length() > 0.1 else -0.25, 4.0 * delta)
		_play_move("swim", 4.0)
		return
	model.rotation.x = lerpf(model.rotation.x, 0.0, minf(8.0 * delta, 1.0)) # se redresse hors de l'eau
	if move.length() > 0.1 and is_on_floor():
		# Le GearAnim (coup de bras, arc) repasse par-dessus les bras du clip.
		_play_move("walk", _speed * 1.8)
	else:
		_play_move("idle", 1.0)

# ---------- Attaques ----------

func _try_melee() -> void:
	if _attack_timer > 0.0:
		return
	_attack_timer = ATTACK_COOLDOWN
	# Coup de bras télégraphié : clip du GearAnim (par-dessus la marche).
	if _gear_anim != null:
		_gear_anim.stop()
		_gear_anim.play("attack")
	if player != null and player.has_method("take_damage"):
		player.take_damage(_damage, global_position)

func _try_shoot() -> void:
	if _attack_timer > 0.0:
		return
	_attack_timer = RANGED_COOLDOWN
	var origin := global_position + Vector3(0, _size, 0)
	# Tir "en avance" : vise là où le joueur SERA, d'après sa vitesse actuelle.
	var target: Vector3 = player.global_position + Vector3(0, 1.0, 0)
	var pv: Vector3 = player.velocity if "velocity" in player else Vector3.ZERO
	var flight_time := origin.distance_to(target) / PROJECTILE_SPEED
	target += Vector3(pv.x, 0.0, pv.z) * flight_time * 0.85
	var dir := (target - origin).normalized()
	# Recul du bras d'arc : clip du GearAnim.
	if _gear_anim != null:
		_gear_anim.stop()
		_gear_anim.play("draw")
	var p := PROJECTILE_SCENE.instantiate() as Projectile
	p.setup(dir, PROJECTILE_SPEED, _damage, "player", Color(0.7, 0.4, 0.95), "enemies")
	get_parent().add_child(p)
	p.global_position = origin + dir * 0.6

# ---------- Dégâts / mort / butin ----------

func take_damage(amount: int, from: Vector3 = Vector3.ZERO) -> void:
	if _roll_timer > 0.0:
		return # esquive réussie
	health -= amount
	FX.damage_number(get_parent(), global_position + Vector3(0, _size * 1.8, 0), amount, Color(1.0, 0.85, 0.25))
	var knock := global_position - from
	knock.y = 0.0
	if knock.length() > 0.01:
		velocity += knock.normalized() * 5.0
	velocity.y = 3.0
	_flash()
	if health <= 0:
		_die()

func _die() -> void:
	_drop_loot()
	queue_free()

func _drop_loot() -> void:
	var parent := get_parent()
	if parent == null:
		return
	var xp := PICKUP_SCENE.instantiate() as Pickup
	xp.kind = Pickup.Kind.XP
	xp.amount = _xp
	parent.add_child(xp)
	xp.global_position = global_position + Vector3(0, 0.6, 0)
	if randf() < 0.25:
		var hp := PICKUP_SCENE.instantiate() as Pickup
		hp.kind = Pickup.Kind.HEALTH
		hp.amount = 25
		parent.add_child(hp)
		hp.global_position = global_position + Vector3(0.4, 0.6, 0.2)
	# Équipement : plus probable sur les brutes ; niveau de l'objet = niveau du joueur.
	var drop_chance := 0.35 if type_id == "brute" else 0.18
	if randf() < drop_chance:
		var lvl := 1
		if player != null and is_instance_valid(player):
			var v = player.get("level")
			if v != null:
				lvl = v
		var it := PICKUP_SCENE.instantiate() as Pickup
		it.kind = Pickup.Kind.ITEM
		it.item = Items.roll_item(lvl)
		parent.add_child(it)
		it.global_position = global_position + Vector3(-0.3, 0.6, -0.2)

func _flash() -> void:
	if _body_mat == null:
		return
	_body_mat.albedo_color = Color(1, 1, 1, _base_albedo.a)
	var t := create_tween()
	t.tween_property(_body_mat, "albedo_color", _base_albedo, 0.2)
