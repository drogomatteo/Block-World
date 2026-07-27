extends Node3D

const CHUNCK_SCENE = preload("res://Scènes/Cubes/Cubes.tscn")

func _ready() -> void:
	RenderingServer.set_debug_generate_wireframes(true)

	for cx in range(-3, 3):
		for cz in range(-3, 3):
			var chunk = CHUNCK_SCENE.instantiate()
			chunk.chunk_position = Vector3i(cx, 0, cz)
			chunk.position = Vector3(cx * Chunk.width, 0, cz * Chunk.depth) * Chunk.cube_size
			add_child(chunk)
			chunk.generate_chunk()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F1:
		var vp := get_viewport()
		if vp.debug_draw == Viewport.DEBUG_DRAW_WIREFRAME:
			vp.debug_draw = Viewport.DEBUG_DRAW_DISABLED
		else:
			vp.debug_draw = Viewport.DEBUG_DRAW_WIREFRAME
