extends SceneTree

# Générateur des scènes d'acteurs : godot --headless -s res://tools/gen_actor_scenes.gd
#
# Construit les MODÈLES voxel (corps, équipement, caméra du joueur) et les
# ANIMATIONS (marche, nage, roulade, attaque...) des 4 classes et des 4
# archétypes d'ennemis, puis les enregistre dans Scènes/Acteurs/*.tscn.
# Les scènes sont ensuite la source de vérité : player.gd / enemy.gd ne font
# que récupérer les nœuds et piloter les AnimationPlayer (logique pure).
#
# ⚠ Relancer ce script ÉCRASE les scènes d'acteurs (y compris des retouches
# faites à la main dans l'éditeur). Les stats/couleurs viennent de
# Player.CLASSES et Enemy.TYPES : une seule source de vérité pour les données.
#
# Hiérarchie générée (joueur) :
#   Warrior (CharacterBody3D + player.gd, class_id préréglé)
#   ├─ Collision (capsule)
#   ├─ Model (yaw + bascule de nage, pilotés en code)
#   │  ├─ RollCenter (pivot central : la galipette tourne autour de lui)
#   │  │  ├─ Torso/Belt/Head/yeux/coiffe...
#   │  │  └─ LegL/LegR/ArmL/ArmR (pivots de membres ; l'arme pend à ArmR,
#   │  │     la lanterne et la dague de l'autre main à ArmL)
#   │  └─ Hitbox (Area3D d'attaque mêlée — hors RollCenter, ne roule pas)
#   ├─ CamPivot ─ SpringArm ─ Camera
#   ├─ Anim     (locomotion : walk/idle/swim_move/swim_idle/roll)
#   └─ GearAnim (attack/recoil — après Anim : sa pose écrase celle de la marche)

var _model: Node3D      # racine visuelle courante
var _rc: Node3D         # RollCenter courant
var _rch := 0.0         # hauteur du RollCenter (les positions "monde modèle"
						# des pièces sont converties en local via _at)

func _initialize() -> void:
	for cid in Player.CLASSES:
		_save(_build_player(cid), "res://Scènes/Acteurs/%s.tscn" % cid)
	for tid in Enemy.TYPES:
		_save(_build_enemy(tid), "res://Scènes/Acteurs/%s.tscn" % tid)
	quit(0)

func _save(actor_root: Node, path: String) -> void:
	_set_owner_rec(actor_root, actor_root)
	var ps := PackedScene.new()
	if ps.pack(actor_root) != OK:
		printerr("FAIL pack ", path)
		quit(1)
		return
	if ResourceSaver.save(ps, path) != OK:
		printerr("FAIL save ", path)
		quit(1)
		return
	print("OK   ", path)
	actor_root.free()

func _set_owner_rec(n: Node, actor_root: Node) -> void:
	for ch in n.get_children():
		ch.owner = actor_root
		_set_owner_rec(ch, actor_root)

# ---------- Briques ----------

func _box(parent: Node3D, box_name: String, size: Vector3, color: Color,
		pos: Vector3, metal := false, glow := false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = box_name
	var bm := BoxMesh.new()
	bm.size = size
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	if metal:
		m.metallic = 0.7
		m.roughness = 0.3
	if glow:
		m.emission_enabled = true
		m.emission = color
	bm.material = m
	mi.mesh = bm
	mi.position = pos
	parent.add_child(mi)
	return mi

# Position exprimée dans le repère du MODÈLE (comme l'ancien code), convertie
# en local RollCenter.
func _at(pos: Vector3) -> Vector3:
	return pos - Vector3(0, _rch, 0)

# Pivot de membre : le nœud est à l'articulation, la boîte pend en dessous —
# une rotation X du pivot balance le membre (marche, nage).
func _limb(limb_name: String, pivot_pos: Vector3, size: Vector3, color: Color) -> Node3D:
	var pivot := Node3D.new()
	pivot.name = limb_name
	pivot.position = _at(pivot_pos)
	_rc.add_child(pivot)
	_box(pivot, "Mesh", size, color, Vector3(0, -size.y * 0.5, 0))
	return pivot

func _new_actor(actor_name: String, script_path: String, id_prop: String, id_value: String,
		cap_radius: float, cap_height: float, cap_y: float, roll_h: float) -> CharacterBody3D:
	var actor := CharacterBody3D.new()
	actor.name = actor_name
	actor.set_script(load(script_path))
	actor.set(id_prop, id_value)

	var cs := CollisionShape3D.new()
	cs.name = "Collision"
	var cap := CapsuleShape3D.new()
	cap.radius = cap_radius
	cap.height = cap_height
	cs.shape = cap
	cs.position = Vector3(0, cap_y, 0)
	actor.add_child(cs)

	_model = Node3D.new()
	_model.name = "Model"
	actor.add_child(_model)
	_rch = roll_h
	if roll_h > 0.0:
		_rc = Node3D.new()
		_rc.name = "RollCenter"
		_rc.position = Vector3(0, roll_h, 0)
		_model.add_child(_rc)
	else:
		_rc = _model # slime : pas de roulade, pièces directement sous Model
	return actor

# ---------- Joueur ----------

func _build_player(cid: String) -> CharacterBody3D:
	var c: Dictionary = Player.CLASSES[cid]
	var col: Color = c["color"]
	var actor := _new_actor(cid.capitalize(), "res://Scripts/player.gd", "class_id", cid,
		0.4, 1.8, 0.9, 0.85)

	var skin := Color(0.94, 0.80, 0.62)
	var pants := col.darkened(0.45)
	var eye_col := Color(0.10, 0.10, 0.14)

	# Torse + ceinture + tête + yeux.
	_box(_rc, "Torso", Vector3(0.56, 0.62, 0.34), col, _at(Vector3(0, 0.86, 0)))
	_box(_rc, "Belt", Vector3(0.58, 0.09, 0.36), col.darkened(0.6), _at(Vector3(0, 0.585, 0)))
	_box(_rc, "Head", Vector3(0.45, 0.45, 0.45), skin, _at(Vector3(0, 1.40, 0)))
	_box(_rc, "EyeL", Vector3(0.07, 0.11, 0.02), eye_col, _at(Vector3(-0.10, 1.44, -0.235)))
	_box(_rc, "EyeR", Vector3(0.07, 0.11, 0.02), eye_col, _at(Vector3(0.10, 1.44, -0.235)))

	# Membres (pivot à la hanche/épaule, la boîte pend dessous) + mains.
	var _leg_l := _limb("LegL", Vector3(-0.14, 0.55, 0), Vector3(0.19, 0.55, 0.23), pants)
	var _leg_r := _limb("LegR", Vector3(0.14, 0.55, 0), Vector3(0.19, 0.55, 0.23), pants)
	var arm_l := _limb("ArmL", Vector3(-0.37, 1.10, 0), Vector3(0.16, 0.52, 0.18), col)
	var arm_r := _limb("ArmR", Vector3(0.37, 1.10, 0), Vector3(0.16, 0.52, 0.18), col)
	for arm in [arm_l, arm_r]:
		_box(arm, "Hand", Vector3(0.15, 0.12, 0.17), skin, Vector3(0, -0.50, 0))

	_headgear(cid, col, arm_l, arm_r)
	_weapon(cid, arm_l, arm_r)
	_lantern(arm_l)

	# Zone d'attaque mêlée, devant le personnage. Hors RollCenter : elle suit
	# le yaw du modèle mais ne tourne pas pendant la galipette.
	var hitbox := Area3D.new()
	hitbox.name = "Hitbox"
	var hcs := CollisionShape3D.new()
	hcs.name = "Collision"
	var hshape := BoxShape3D.new()
	hshape.size = Vector3(1.6, 1.6, 2.0)
	hcs.shape = hshape
	hcs.position = Vector3(0, 0.8, -1.1)
	hitbox.add_child(hcs)
	_model.add_child(hitbox)

	# Caméra orbitale sur SpringArm (la sphère couvre tout le cône de vue,
	# un simple rayon laissait le feuillage clipper les coins de l'écran).
	var cam_pivot := Node3D.new()
	cam_pivot.name = "CamPivot"
	cam_pivot.position = Vector3(0, 1.4, 0)
	cam_pivot.rotation.x = -0.35
	actor.add_child(cam_pivot)
	var arm := SpringArm3D.new()
	arm.name = "SpringArm"
	arm.spring_length = 5.0
	arm.margin = 0.3
	var cam_shape := SphereShape3D.new()
	cam_shape.radius = 0.45
	arm.shape = cam_shape
	cam_pivot.add_child(arm)
	var camera := Camera3D.new()
	camera.name = "Camera"
	camera.current = true
	arm.add_child(camera)

	_player_anims(actor)
	return actor

func _headgear(cid: String, col: Color, arm_l: Node3D, arm_r: Node3D) -> void:
	var metal := Color(0.72, 0.75, 0.82)
	match cid:
		"warrior":
			# Casque : dôme + rebord + protège-nez ; épaulières sur les bras.
			_box(_rc, "HelmetDome", Vector3(0.49, 0.16, 0.49), metal, _at(Vector3(0, 1.60, 0)), true)
			_box(_rc, "HelmetBrim", Vector3(0.53, 0.06, 0.53), metal.darkened(0.2), _at(Vector3(0, 1.52, 0)), true)
			_box(_rc, "NoseGuard", Vector3(0.07, 0.16, 0.04), metal, _at(Vector3(0, 1.42, -0.235)), true)
			for arm in [arm_l, arm_r]:
				_box(arm, "Pauldron", Vector3(0.24, 0.12, 0.24), metal, Vector3(0, 0.04, 0), true)
		"ranger":
			# Capuche + cape courte dans le dos.
			var hood := col.darkened(0.35)
			_box(_rc, "Hood", Vector3(0.51, 0.16, 0.51), hood, _at(Vector3(0, 1.60, 0)))
			_box(_rc, "HoodBack", Vector3(0.49, 0.30, 0.08), hood, _at(Vector3(0, 1.45, 0.24)))
			_box(_rc, "Cape", Vector3(0.44, 0.55, 0.06), hood.darkened(0.15), _at(Vector3(0, 0.92, 0.22)))
		"mage":
			# Chapeau pointu étagé.
			var hat := col.darkened(0.25)
			_box(_rc, "HatBrim", Vector3(0.60, 0.05, 0.60), hat, _at(Vector3(0, 1.635, 0)))
			_box(_rc, "Hat1", Vector3(0.36, 0.16, 0.36), hat, _at(Vector3(0, 1.73, 0)))
			_box(_rc, "Hat2", Vector3(0.22, 0.16, 0.22), hat.lightened(0.1), _at(Vector3(0, 1.87, 0)))
			_box(_rc, "HatTip", Vector3(0.10, 0.18, 0.10), hat.lightened(0.2), _at(Vector3(0, 2.02, 0)))
		"rogue":
			# Bandana + nœud dans le dos, masque sur le bas du visage.
			var band := Color(0.22, 0.22, 0.26)
			_box(_rc, "Bandana", Vector3(0.47, 0.10, 0.47), band, _at(Vector3(0, 1.56, 0)))
			_box(_rc, "Knot", Vector3(0.10, 0.16, 0.06), band, _at(Vector3(0.12, 1.48, 0.25)))
			_box(_rc, "Mask", Vector3(0.46, 0.12, 0.10), band.lightened(0.1), _at(Vector3(0, 1.30, -0.20)))

# L'arme pend à la main droite (elle suit le balancement du bras) ; le
# roublard a une seconde dague dans la main gauche (Offhand).
func _weapon(cid: String, arm_l: Node3D, arm_r: Node3D) -> void:
	var weapon := Node3D.new()
	weapon.name = "Weapon"
	weapon.position = Vector3(0.03, -0.50, -0.10)
	arm_r.add_child(weapon)
	match cid:
		"warrior":
			_box(weapon, "Blade", Vector3(0.1, 0.9, 0.1), Color(0.82, 0.84, 0.9), Vector3(0, 0.25, 0), true)
			_box(weapon, "Guard", Vector3(0.26, 0.06, 0.08), Color(0.45, 0.35, 0.2), Vector3(0, -0.12, 0))
		"ranger":
			var wood := Color(0.45, 0.30, 0.15)
			_box(weapon, "Bow", Vector3(0.07, 1.1, 0.07), wood, Vector3.ZERO)
			_box(weapon, "TipTop", Vector3(0.05, 0.30, 0.05), wood, Vector3(0, 0.62, -0.08))
			_box(weapon, "TipBottom", Vector3(0.05, 0.30, 0.05), wood, Vector3(0, -0.62, -0.08))
		"mage":
			_box(weapon, "Staff", Vector3(0.08, 1.3, 0.08), Color(0.30, 0.20, 0.12), Vector3.ZERO)
			_box(weapon, "Orb", Vector3(0.16, 0.16, 0.16), Color(1.0, 0.55, 0.15), Vector3(0, 0.72, 0), false, true)
		"rogue":
			_box(weapon, "Blade", Vector3(0.07, 0.45, 0.07), Color(0.75, 0.78, 0.85), Vector3(0, 0.12, 0), true)
	if cid == "rogue":
		var offhand := Node3D.new()
		offhand.name = "Offhand"
		offhand.position = Vector3(-0.03, -0.50, -0.10)
		arm_l.add_child(offhand)
		_box(offhand, "Blade", Vector3(0.07, 0.45, 0.07), Color(0.75, 0.78, 0.85), Vector3(0, 0.12, 0), true)

# Lanterne tenue en main gauche (touche G) : cacher le nœud éteint aussi la
# lumière (visible se propage aux enfants).
func _lantern(arm_l: Node3D) -> void:
	var lantern := Node3D.new()
	lantern.name = "Lantern"
	lantern.position = Vector3(0, -0.52, -0.16)
	lantern.visible = false
	arm_l.add_child(lantern)
	var dark := Color(0.20, 0.18, 0.16)
	_box(lantern, "Base", Vector3(0.16, 0.04, 0.16), dark, Vector3(0, -0.10, 0))
	_box(lantern, "Top", Vector3(0.16, 0.04, 0.16), dark, Vector3(0, 0.10, 0))
	_box(lantern, "Glow", Vector3(0.10, 0.16, 0.10), Color(1.0, 0.82, 0.45), Vector3.ZERO, false, true)
	_box(lantern, "Ring", Vector3(0.04, 0.05, 0.04), Color(0.25, 0.23, 0.20), Vector3(0, 0.15, 0))
	var light := OmniLight3D.new()
	light.name = "LanternLight"
	light.omni_range = 14.0
	light.light_energy = 2.2
	light.light_color = Color(1.0, 0.85, 0.55)
	light.shadow_enabled = true
	lantern.add_child(light)

# ---------- Ennemis ----------

func _build_enemy(tid: String) -> CharacterBody3D:
	var t: Dictionary = Enemy.TYPES[tid]
	var s: float = t["size"]
	var col: Color = t["color"]
	var hops: bool = t["hops"]
	var actor := _new_actor(tid.capitalize(), "res://Scripts/enemy.gd", "type_id", tid,
		s * 0.5, s * 2.0, s, 0.0 if hops else s * 0.9)

	if hops:
		_slime_body(s, col)
	else:
		_humanoid_body(tid, s, col)
		_enemy_anims(actor, tid)
	return actor

# Slime : cube gélatineux translucide avec un noyau, des yeux et une bouche.
# Pas d'AnimationPlayer : l'écrasement/étirement dépend de la physique (bond,
# atterrissage) et reste piloté en code sur Model.scale.
func _slime_body(s: float, col: Color) -> void:
	var body := _box(_model, "Body", Vector3(s * 1.15, s * 0.85, s * 1.05),
		Color(col.r, col.g, col.b, 0.82), Vector3(0, s * 0.45, 0))
	(body.mesh.material as StandardMaterial3D).transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_box(_model, "Core", Vector3(s * 0.45, s * 0.4, s * 0.4), col.darkened(0.35), Vector3(0, s * 0.4, 0))
	var eye_col := Color(0.05, 0.05, 0.05)
	_box(_model, "EyeL", Vector3(s * 0.16, s * 0.2, 0.03), eye_col, Vector3(-s * 0.24, s * 0.55, -s * 0.53))
	_box(_model, "EyeR", Vector3(s * 0.16, s * 0.2, 0.03), eye_col, Vector3(s * 0.24, s * 0.55, -s * 0.53))
	_box(_model, "Mouth", Vector3(s * 0.22, s * 0.06, 0.03), eye_col, Vector3(0, s * 0.3, -s * 0.53))

# Humanoïde paramétré par la taille : éclaireur, brute et archer partagent le
# squelette (membres sur pivots animés) et se distinguent par l'équipement.
func _humanoid_body(tid: String, s: float, col: Color) -> void:
	var hip := s * 0.75
	var pants := col.darkened(0.5)
	var eye_col := Color(0.05, 0.05, 0.05)

	var _leg_l := _limb("LegL", Vector3(-s * 0.22, hip, 0), Vector3(s * 0.28, hip, s * 0.3), pants)
	var _leg_r := _limb("LegR", Vector3(s * 0.22, hip, 0), Vector3(s * 0.28, hip, s * 0.3), pants)

	_box(_rc, "Torso", Vector3(s * 0.85, s * 0.75, s * 0.5), col, _at(Vector3(0, hip + s * 0.37, 0)))

	var arm_size := Vector3(s * 0.24, s * 0.6, s * 0.26)
	if tid == "brute":
		arm_size = Vector3(s * 0.32, s * 0.7, s * 0.34)
	var arm_l := _limb("ArmL", Vector3(-s * 0.55, hip + s * 0.70, 0), arm_size, col.darkened(0.2))
	var arm_r := _limb("ArmR", Vector3(s * 0.55, hip + s * 0.70, 0), arm_size, col.darkened(0.2))

	var head_y := hip + s * 0.75 + s * 0.32
	_box(_rc, "Head", Vector3(s * 0.6, s * 0.6, s * 0.6), col.lightened(0.15), _at(Vector3(0, head_y, 0)))
	_box(_rc, "EyeL", Vector3(s * 0.13, s * 0.15, 0.03), eye_col, _at(Vector3(-s * 0.15, head_y + s * 0.04, -s * 0.31)))
	_box(_rc, "EyeR", Vector3(s * 0.13, s * 0.15, 0.03), eye_col, _at(Vector3(s * 0.15, head_y + s * 0.04, -s * 0.31)))

	match tid:
		"scout":
			# Bandana + dague : l'agile détrousseur.
			_box(_rc, "Bandana", Vector3(s * 0.64, s * 0.12, s * 0.64), col.darkened(0.55), _at(Vector3(0, head_y + s * 0.32, 0)))
			_box(_rc, "Tail", Vector3(s * 0.14, s * 0.3, s * 0.08), col.darkened(0.55), _at(Vector3(s * 0.2, head_y + s * 0.2, s * 0.33)))
			_box(arm_r, "Dagger", Vector3(0.06, s * 0.55, 0.06), Color(0.75, 0.78, 0.85), Vector3(0, -s * 0.55, -s * 0.12), true)
		"brute":
			# Sourcils froncés, défenses, épaulières et gros poings.
			var brow := Color(0.15, 0.05, 0.05)
			var tusk := Color(0.95, 0.92, 0.85)
			_box(_rc, "BrowL", Vector3(s * 0.2, s * 0.07, 0.04), brow, _at(Vector3(-s * 0.15, head_y + s * 0.16, -s * 0.31)))
			_box(_rc, "BrowR", Vector3(s * 0.2, s * 0.07, 0.04), brow, _at(Vector3(s * 0.15, head_y + s * 0.16, -s * 0.31)))
			_box(_rc, "TuskL", Vector3(s * 0.09, s * 0.16, 0.05), tusk, _at(Vector3(-s * 0.14, head_y - s * 0.22, -s * 0.31)))
			_box(_rc, "TuskR", Vector3(s * 0.09, s * 0.16, 0.05), tusk, _at(Vector3(s * 0.14, head_y - s * 0.22, -s * 0.31)))
			for arm in [arm_l, arm_r]:
				_box(arm, "Pauldron", Vector3(s * 0.38, s * 0.14, s * 0.38), col.darkened(0.4), Vector3(0, s * 0.03, 0))
				_box(arm, "Fist", Vector3(s * 0.3, s * 0.24, s * 0.32), Color(0.85, 0.72, 0.6), Vector3(0, -s * 0.78, 0))
		"archer":
			# Arc en main gauche + carquois dans le dos.
			var wood := Color(0.45, 0.30, 0.15)
			_box(arm_l, "Bow", Vector3(0.05, s * 1.2, 0.05), wood, Vector3(0, -s * 0.55, -s * 0.15))
			_box(arm_l, "TipTop", Vector3(0.04, s * 0.25, 0.04), wood.darkened(0.2), Vector3(0, s * 0.05, -s * 0.22))
			_box(arm_l, "TipBottom", Vector3(0.04, s * 0.25, 0.04), wood.darkened(0.2), Vector3(0, -s * 1.15, -s * 0.22))
			var quiver := _box(_rc, "Quiver", Vector3(s * 0.26, s * 0.6, s * 0.2), wood.darkened(0.3), _at(Vector3(s * 0.18, hip + s * 0.5, s * 0.32)))
			quiver.rotation.z = 0.25

# ---------- Animations ----------
# Les clips reproduisent les anciennes formules procédurales, échantillonnées
# en clés (interpolation cubique pour les sinus). La CADENCE est pilotée au
# runtime par speed_scale : walk joué à speed_scale = vitesse de déplacement,
# comme l'ancien phase += delta * vitesse.

const RC := "Model/RollCenter"

func _track(a: Animation, path: String, keys: Array, cubic := false) -> void:
	var ti := a.add_track(Animation.TYPE_VALUE)
	a.track_set_path(ti, NodePath(path))
	if cubic:
		a.track_set_interpolation_type(ti, Animation.INTERPOLATION_CUBIC)
	for k in keys:
		a.track_insert_key(ti, k[0], k[1])

# Clés d'un sinus amp*sin(freq*t + phase) sur [0, length].
func _sine(length: float, freq: float, amp: float, phase := 0.0, absolute := false, samples := 24) -> Array:
	var keys := []
	for i in samples + 1:
		var kt := length * i / samples
		var v := amp * sin(freq * kt + phase)
		keys.append([kt, absf(v) if absolute else v])
	return keys

func _anim(length: float, looped := true) -> Animation:
	var a := Animation.new()
	a.length = length
	if looped:
		a.loop_mode = Animation.LOOP_LINEAR
	return a

func _add_player(parent: Node, player_name: String, lib: AnimationLibrary) -> void:
	var ap := AnimationPlayer.new()
	ap.name = player_name
	ap.add_animation_library("", lib)
	parent.add_child(ap)

func _player_anims(actor: Node) -> void:
	var lib := AnimationLibrary.new()
	var limbs := [RC + "/LegL", RC + "/LegR", RC + "/ArmL", RC + "/ArmR"]

	# Marche : jambes/bras en opposition + rebond du corps. Une période de
	# sinus par cycle ; speed_scale = vitesse => phase = 1.6 * t * vitesse,
	# amplitudes 0.55 (jambes) et 0.55*0.8 (bras), comme avant.
	var wt := TAU / 1.6
	var walk := _anim(wt)
	_track(walk, limbs[0] + ":rotation:x", _sine(wt, 1.6, 0.55), true)
	_track(walk, limbs[1] + ":rotation:x", _sine(wt, 1.6, -0.55), true)
	_track(walk, limbs[2] + ":rotation:x", _sine(wt, 1.6, -0.44), true)
	_track(walk, limbs[3] + ":rotation:x", _sine(wt, 1.6, 0.44), true)
	_track(walk, "Model:position:y", _sine(wt, 1.6, 0.07, 0.0, true), true)
	lib.add_animation("walk", walk)

	# Nage : les bras PAGAIENT en alternance (aller-retour, comme les ennemis
	# — l'ancien moulinet à tour complet faisait des bras d'hélice), jambes
	# qui battent + houle. Joué à speed_scale 4.5.
	var st := TAU / 1.5
	var swim := _anim(st)
	_track(swim, limbs[2] + ":rotation:x", _sine(st, 1.5, 0.9), true)
	_track(swim, limbs[3] + ":rotation:x", _sine(st, 1.5, -0.9), true)
	_track(swim, limbs[0] + ":rotation:x", _sine(st, 3.0, 0.45), true)
	_track(swim, limbs[1] + ":rotation:x", _sine(st, 3.0, -0.45), true)
	_track(swim, "Model:position:y", _sine(st, 1.5, 0.05), true)
	lib.add_animation("swim_move", swim)

	# Surplace : petits mouvements des bras et des jambes pour flotter.
	var it := TAU
	var idle_swim := _anim(it)
	_track(idle_swim, limbs[2] + ":rotation:x", _sine(it, 1.0, 0.35), true)
	_track(idle_swim, limbs[3] + ":rotation:x", _sine(it, 1.0, -0.35), true)
	_track(idle_swim, limbs[0] + ":rotation:x", _sine(it, 2.0, 0.25), true)
	_track(idle_swim, limbs[1] + ":rotation:x", _sine(it, 2.0, -0.25), true)
	_track(idle_swim, "Model:position:y", _sine(it, 1.0, 0.05), true)
	lib.add_animation("swim_idle", idle_swim)

	# Repos : tout revient à zéro (le fondu du play() fait la transition).
	var idle := _anim(0.25, false)
	for l in limbs:
		_track(idle, l + ":rotation:x", [[0.0, 0.0]])
	_track(idle, "Model:position:y", [[0.0, 0.0]])
	lib.add_animation("idle", idle)

	# Galipette : tour complet autour du centre du corps, membres repliés.
	var roll := _anim(0.45, false)
	_track(roll, RC + ":rotation:x", [[0.0, 0.0], [0.45, -TAU]])
	_track(roll, limbs[2] + ":rotation:x", [[0.08, 1.3]])
	_track(roll, limbs[3] + ":rotation:x", [[0.08, 1.3]])
	_track(roll, limbs[0] + ":rotation:x", [[0.08, 1.1]])
	_track(roll, limbs[1] + ":rotation:x", [[0.08, 1.1]])
	lib.add_animation("roll", roll)

	var reset := _anim(0.0, false)
	for l in limbs:
		_track(reset, l + ":rotation:x", [[0.0, 0.0]])
	_track(reset, RC + ":rotation:x", [[0.0, 0.0]])
	_track(reset, "Model:position:y", [[0.0, 0.0]])
	lib.add_animation("RESET", reset)

	_add_player(actor, "Anim", lib)

	# Armes : joué PAR-DESSUS la locomotion (GearAnim est après Anim dans
	# l'arbre, sa pose gagne tant qu'un clip tourne).
	var glib := AnimationLibrary.new()
	var wpath := RC + "/ArmR/Weapon"
	var attack := _anim(0.24, false)
	_track(attack, wpath + ":rotation:x", [[0.0, deg_to_rad(-130.0)], [0.12, deg_to_rad(40.0)], [0.24, 0.0]])
	glib.add_animation("attack", attack)
	var recoil := _anim(0.15, false)
	_track(recoil, wpath + ":position:z", [[0.0, -0.07], [0.15, -0.25]])
	glib.add_animation("recoil", recoil)
	_add_player(actor, "GearAnim", glib)

func _enemy_anims(actor: Node, tid: String) -> void:
	var lib := AnimationLibrary.new()
	var limbs := [RC + "/LegL", RC + "/LegR", RC + "/ArmL", RC + "/ArmR"]

	# Marche : speed_scale = _speed * 1.8 (l'ancienne cadence).
	var wt := TAU
	var walk := _anim(wt)
	_track(walk, limbs[0] + ":rotation:x", _sine(wt, 1.0, 0.6), true)
	_track(walk, limbs[1] + ":rotation:x", _sine(wt, 1.0, -0.6), true)
	_track(walk, limbs[2] + ":rotation:x", _sine(wt, 1.0, -0.36), true)
	_track(walk, limbs[3] + ":rotation:x", _sine(wt, 1.0, 0.36), true)
	lib.add_animation("walk", walk)

	# Nage : bras qui pagaient en alternance + battements de jambes.
	var st := TAU / 1.5
	var swim := _anim(st)
	_track(swim, limbs[2] + ":rotation:x", _sine(st, 1.5, 0.9), true)
	_track(swim, limbs[3] + ":rotation:x", _sine(st, 1.5, -0.9), true)
	_track(swim, limbs[0] + ":rotation:x", _sine(st, 3.0, 0.4), true)
	_track(swim, limbs[1] + ":rotation:x", _sine(st, 3.0, -0.4), true)
	lib.add_animation("swim", swim)

	var idle := _anim(0.25, false)
	for l in limbs:
		_track(idle, l + ":rotation:x", [[0.0, 0.0]])
	lib.add_animation("idle", idle)

	var roll := _anim(0.4, false)
	_track(roll, RC + ":rotation:x", [[0.0, 0.0], [0.4, -TAU]])
	for l in limbs:
		_track(roll, l + ":rotation:x", [[0.08, 1.2]])
	lib.add_animation("roll", roll)

	var reset := _anim(0.0, false)
	for l in limbs:
		_track(reset, l + ":rotation:x", [[0.0, 0.0]])
	_track(reset, RC + ":rotation:x", [[0.0, 0.0]])
	lib.add_animation("RESET", reset)

	_add_player(actor, "Anim", lib)

	# Coup de bras télégraphié (mêlée) ; l'archer a en plus le recul d'arc.
	var glib := AnimationLibrary.new()
	var attack := _anim(0.3, false)
	_track(attack, limbs[3] + ":rotation:x", [[0.0, -2.2], [0.3, 0.0]])
	glib.add_animation("attack", attack)
	if tid == "archer":
		var draw := _anim(0.4, false)
		_track(draw, limbs[2] + ":rotation:x", [[0.0, -1.4], [0.4, 0.0]])
		glib.add_animation("draw", draw)
	_add_player(actor, "GearAnim", glib)
