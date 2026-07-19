class_name FX

# Petits effets visuels réutilisables.

# Chiffre de dégâts flottant qui monte et s'efface.
static func damage_number(parent: Node, pos: Vector3, amount: int, color: Color) -> void:
	if parent == null:
		return
	var l := Label3D.new()
	l.text = str(amount)
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.font_size = 48
	l.outline_size = 10
	l.modulate = color
	parent.add_child(l)
	l.global_position = pos + Vector3(randf_range(-0.3, 0.3), 0.0, randf_range(-0.2, 0.2))
	var t := l.create_tween()
	t.set_parallel(true)
	t.tween_property(l, "global_position", l.global_position + Vector3(0, 1.2, 0), 0.6)
	t.tween_property(l, "modulate:a", 0.0, 0.45).set_delay(0.15)
	t.chain().tween_callback(l.queue_free)
