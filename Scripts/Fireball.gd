class_name Fireball
extends Area3D

# Projectile utilisé par les entités qui utilisent des boules de feu.

var velocity: Vector3
var damage
var target_group  # la cible
var pass_group    # le tireur
var _life := 4.0

# À appeler AVANT add_child.
func setup(dir: Vector3, speed: float, dmg: int, target, passes) -> void:
	velocity = dir.normalized() * speed
	damage = dmg
	target_group = target
	pass_group = passes

func _physics_process(delta: float) -> void:
	global_position += velocity * delta
	_life -= delta
	if _life <= 0.0:
		queue_free()

func _on_body_entered(body: Node) -> void:
	if body.is_in_group(pass_group):
		return # traverse son propre camp (y compris le tireur)
	if body.is_in_group(target_group) and body.has_method("take_damage"):
		body.take_damage(damage, global_position)
	queue_free() # cible touchée ou décor : disparaît
