class_name Arrow
extends Area3D

# Projectile utilisé par les entités qui utilisent des flèches.
# Tir balistique : la flèche subit BULLET_DROP et pique du nez en retombant.
# Les tireurs compensent la chute via ballistic_dir().

const BULLET_DROP := 1.0 # gravité des flèches (m/s²)

var velocity: Vector3
var damage
var target_group  # la cible
var pass_group    # le tireur
var _life := 4.0

# Direction de tir pour qu'une flèche partie de `from` à `speed` retombe
# exactement sur `to` malgré BULLET_DROP. Deux angles font mouche : on prend
# l'arc BAS (tir tendu), pas la cloche. Cible hors de portée : 45° vers elle
# (portée maximale), au moins la flèche part du bon côté.
static func ballistic_dir(from: Vector3, to: Vector3, speed: float) -> Vector3:
	var diff := to - from
	var flat := Vector3(diff.x, 0.0, diff.z)
	var d := flat.length()
	if BULLET_DROP <= 0.0 or d < 0.01:
		return diff.normalized() if diff.length() > 0.01 else Vector3.FORWARD
	var s2 := speed * speed
	var disc := s2 * s2 - BULLET_DROP * (BULLET_DROP * d * d + 2.0 * diff.y * s2)
	if disc < 0.0:
		return (flat.normalized() + Vector3.UP).normalized()
	var tan_a := (s2 - sqrt(disc)) / (BULLET_DROP * d)
	return (flat.normalized() + Vector3.UP * tan_a).normalized()

# À appeler AVANT add_child.
func setup(dir: Vector3, speed: float, dmg: int, target, passes) -> void:
	velocity = dir.normalized() * speed
	damage = dmg
	target_group = target
	pass_group = passes

func _physics_process(delta: float) -> void:
	velocity.y -= BULLET_DROP * delta
	global_position += velocity * delta
	# La flèche s'aligne sur sa trajectoire (pique du nez en retombant).
	# look_at plante si l'axe visé est colinéaire au up : garde-fou.
	if absf(velocity.normalized().dot(Vector3.UP)) < 0.99:
		look_at(global_position + velocity)
	_life -= delta
	if _life <= 0.0:
		queue_free()

func _on_body_entered(body: Node) -> void:
	if body.is_in_group(pass_group):
		return # traverse son propre camp (y compris le tireur)
	if body.is_in_group(target_group) and body.has_method("take_damage"):
		body.take_damage(damage, global_position)
	queue_free() # cible touchée ou décor : disparaît
