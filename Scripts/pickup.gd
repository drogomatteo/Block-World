class_name Pickup
extends Area3D

# Objet à ramasser lâché par les ennemis : orbe d'XP, orbe de soin, ou pièce
# d'équipement (marquée d'un faisceau lumineux coloré selon sa rareté).
# kind / amount / item sont à définir AVANT add_child (lus dans _ready).

enum Kind { XP, HEALTH, ITEM }

const MAGNET_RADIUS := 3.5
const MAGNET_SPEED := 9.0
const LIFETIME := 25.0
const ITEM_LIFETIME := 60.0 # l'équipement reste plus longtemps au sol

var kind := Kind.XP
var amount := 10
var item := {} # objet généré par Items.roll_item si kind == ITEM

var _mesh: MeshInstance3D
var _t := 0.0
var _life := LIFETIME
var _target: Node3D

func _ready() -> void:
	if kind == Kind.ITEM:
		_life = ITEM_LIFETIME

	var cs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = 0.6
	cs.shape = sph
	add_child(cs)

	var col: Color
	match kind:
		Kind.HEALTH:
			col = Color(1.0, 0.3, 0.4)
		Kind.ITEM:
			col = Items.RARITY_COLORS[item.get("rarity", 0)]
		_:
			col = Color(0.2, 0.9, 1.0)

	_mesh = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3.ONE * (0.38 if kind == Kind.ITEM else 0.3)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.emission_enabled = true
	mat.emission = col
	bm.material = mat
	_mesh.mesh = bm
	_mesh.position.y = 0.4
	add_child(_mesh)

	if kind == Kind.ITEM:
		_add_beam(col)

	body_entered.connect(_on_body_entered)

# Colonne de lumière verticale au-dessus de l'objet, façon loot d'action-RPG.
func _add_beam(col: Color) -> void:
	var beam := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.14, 2.6, 0.14)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(col.r, col.g, col.b, 0.35)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = col
	bm.material = mat
	beam.mesh = bm
	beam.position.y = 1.5
	add_child(beam)

func _physics_process(delta: float) -> void:
	_t += delta
	_mesh.rotation.y += delta * 2.5
	_mesh.position.y = 0.4 + sin(_t * 3.0) * 0.12

	_life -= delta
	if _life <= 0.0:
		queue_free()
		return

	if _target == null or not is_instance_valid(_target):
		_target = get_tree().get_first_node_in_group("player")
	if _target != null and is_instance_valid(_target):
		var dest: Vector3 = _target.global_position + Vector3(0, 0.8, 0)
		if global_position.distance_to(dest) < MAGNET_RADIUS:
			global_position = global_position.move_toward(dest, MAGNET_SPEED * delta)

func _on_body_entered(body: Node) -> void:
	if not body.is_in_group("player"):
		return
	match kind:
		Kind.XP:
			if body.has_method("gain_xp"):
				body.gain_xp(amount)
		Kind.HEALTH:
			if body.has_method("heal"):
				body.heal(amount)
		Kind.ITEM:
			if body.has_method("add_item"):
				body.add_item(item)
	queue_free()
