class_name Projectile
extends Area3D

# Projectile générique, utilisé par les ennemis (archer) comme par le joueur
# (rôdeur, mage). Vole en ligne droite, blesse le groupe cible au contact,
# traverse le camp du tireur, disparaît sur le décor ou en fin de vie.

var velocity := Vector3.ZERO
var damage := 8
var target_group := "player"   # groupe blessé au contact
var pass_group := "enemies"    # groupe traversé (le camp du tireur)
var color := Color(0.7, 0.4, 0.95)
var _life := 4.0
var bullet_drop := 1
var speed_y

# À appeler AVANT add_child.
func setup(dir: Vector3, speed: float, dmg: int, target := "player",
		col := Color(0.7, 0.4, 0.95), passes := "enemies") -> void:
	velocity = dir.normalized() * speed
	damage = dmg
	target_group = target
	color = col
	pass_group = passes
	speed_y = dir.normalized().dot(Vector3(0 , -1, 0)) * speed

func _ready() -> void:
	var cs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = 0.25
	cs.shape = sph
	add_child(cs)

	var mesh := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.18
	sm.height = 0.36
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	sm.material = mat
	mesh.mesh = sm
	add_child(mesh)

	body_entered.connect(_on_body_entered)

func _physics_process(delta: float) -> void:
	global_position += velocity * delta
	speed_y += bullet_drop * delta
	global_position.y -= speed_y * delta
	_life -= delta
	if _life <= 0.0:
		queue_free()

func _on_body_entered(body: Node) -> void:
	if body.is_in_group(pass_group):
		return # traverse son propre camp (y compris le tireur)
	if body.is_in_group(target_group) and body.has_method("take_damage"):
		body.take_damage(damage, global_position)
	queue_free() # cible touchée ou décor : disparaît
