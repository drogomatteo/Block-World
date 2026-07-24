class_name FX

# Petits effets visuels réutilisables.

# Texture d'ombre douce (disque dégradé noir -> transparent), créée une fois
# et partagée par toutes les ombres rondes (entités, arbres).
static var _blob_tex: GradientTexture2D

# Maillage d'ombre ronde : un plan horizontal portant le disque dégradé,
# sans éclairage — visible même quand les vraies ombres sont désactivées.
static func blob_shadow_mesh(radius: float) -> PlaneMesh:
	if _blob_tex == null:
		# Plateau sombre jusqu'à ~55 % du rayon puis fondu : sans le plateau,
		# le dégradé s'estompe dès le centre et l'ombre est quasi invisible.
		var g := Gradient.new()
		g.offsets = PackedFloat32Array([0.0, 0.55, 1.0])
		g.colors = PackedColorArray([Color(0, 0, 0, 0.42), Color(0, 0, 0, 0.34), Color(0, 0, 0, 0.0)])
		_blob_tex = GradientTexture2D.new()
		_blob_tex.gradient = g
		_blob_tex.fill = GradientTexture2D.FILL_RADIAL
		_blob_tex.fill_from = Vector2(0.5, 0.5)
		_blob_tex.fill_to = Vector2(0.5, 0.0)
		_blob_tex.width = 64
		_blob_tex.height = 64
	var pm := PlaneMesh.new()
	pm.size = Vector2.ONE * (radius * 2.0)
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = _blob_tex
	pm.material = mat
	return pm

# Ombre ronde prête à poser sous une entité (à repositionner chaque frame
# sur le sol via le générateur de terrain).
static func blob_shadow(radius: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = blob_shadow_mesh(radius)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

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
