extends Camera3D
# Caméra libre : clic gauche pour capturer la souris, Échap pour la libérer.
# Déplacement ZQSD (positions physiques, donc indépendant de la disposition
# clavier), Espace / Maj pour monter / descendre, molette pour la vitesse.

@export var mouse_sensitivity : float = 0.002
@export var speed : float = 20.0

const SPEED_MIN : float = 2.0
const SPEED_MAX : float = 200.0

var yaw : float = 0.0
var pitch : float = 0.0

func _ready() -> void:
	yaw = rotation.y
	pitch = rotation.x

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			MOUSE_BUTTON_WHEEL_UP:
				speed = minf(speed * 1.2, SPEED_MAX)
			MOUSE_BUTTON_WHEEL_DOWN:
				speed = maxf(speed / 1.2, SPEED_MIN)
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		yaw -= event.relative.x * mouse_sensitivity
		pitch = clampf(pitch - event.relative.y * mouse_sensitivity, -PI / 2 + 0.01, PI / 2 - 0.01)
		rotation = Vector3(pitch, yaw, 0.0)

func _process(delta: float) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	var dir := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		dir -= basis.z
	if Input.is_physical_key_pressed(KEY_S):
		dir += basis.z
	if Input.is_physical_key_pressed(KEY_A):
		dir -= basis.x
	if Input.is_physical_key_pressed(KEY_D):
		dir += basis.x
	if Input.is_physical_key_pressed(KEY_SPACE):
		dir += Vector3.UP
	if Input.is_physical_key_pressed(KEY_SHIFT):
		dir -= Vector3.UP
	if dir != Vector3.ZERO:
		position += dir.normalized() * speed * delta
