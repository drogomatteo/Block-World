extends Camera3D

@export var target : Vector3 = Vector3(0.0, 8.0, 0.0)
@export var radius : float = 60.0
@export var height : float = 40.0
@export var speed : float = 0.2

var angle : float = 0.0

func _process(delta: float) -> void:
	angle += speed * delta
	position = target + Vector3(cos(angle) * radius, height, sin(angle) * radius)
	look_at(target)
