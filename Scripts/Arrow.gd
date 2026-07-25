class_name Arrow
extends Area3D

# Projectile utilisé par les entités qui utilisent des flèches
# La flèche est affectée par la gravité

var velocity
var damage
var target_group  # la cible
var pass_group    # le tireur
var _life := 4.0
var _bullet_drop := 1
var speed_y

# À appeler AVANT add_child.
func setup(dir: Vector3, speed: float, dmg: int, target, passes) -> void:
	velocity = dir.normalized() * speed
	damage = dmg
	target_group = target
	pass_group = passes
	speed_y = dir.normalized().dot(Vector3(0 , -1, 0)) * speed
	look_at_from_position(position, dir)

func _physics_process(delta: float) -> void:
	global_position += velocity * delta
	speed_y += _bullet_drop * delta
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
