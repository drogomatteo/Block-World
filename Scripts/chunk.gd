class_name Chunk
extends Node3D

# Un chunk = une portion carrée SIZE x SIZE colonnes du monde.
# Rendu   : UN SEUL MultiMeshInstance3D (donc 1 draw call pour tous les cubes).
# Collision: UN SEUL collider trimesh (dessus + faces de falaise exposées).
# Les instances/faces sont en coordonnées LOCALES ; le nœud Chunk est placé
# à la position monde (cx*SIZE*CUBE, 0, cz*SIZE*CUBE) par world.gd.

const SIZE := 16
# Taille MONDE d'un cube : le TIERS de la taille du joueur (capsule 1.8 m).
# TerrainGen travaille en indices de cube ; tout ce qui parle en mètres passe par CUBE.
const CUBE := 0.6

var gen: TerrainGen
var cx: int
var cz: int
var water_material: Material # partagé, créé une seule fois par world.gd
var deco_view_dist := 0.0    # distance d'affichage des décos (0 = illimitée)
var deco_visible := true     # option « décorations au sol »
var tree_shadows_visible := false # ombres rondes sous les arbres (ombres OFF)
var deco_mmi: MultiMeshInstance3D        # relu par world.gd (toggles à chaud)
var tree_shadow_mmi: MultiMeshInstance3D

func build() -> void:
	_build_visual()
	_build_collision()
	_build_trees()
	_build_deco()
	_build_water()

func _build_visual() -> void:
	var box := BoxMesh.new()
	box.size = Vector3.ONE * CUBE
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true # la couleur par instance devient l'albédo
	box.material = mat

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = box

	var transforms: Array[Transform3D] = []
	var colors: Array[Color] = []
	for lx in SIZE:
		for lz in SIZE:
			var wx := cx * SIZE + lx
			var wz := cz * SIZE + lz
			var h := gen.get_height(wx, wz)
			# On ne remplit la colonne que jusqu'au plus bas voisin : inutile de
			# dessiner des cubes totalement enterrés qu'on ne verra jamais.
			var bottom := _column_bottom(wx, wz, h)
			for y in range(bottom, h + 1):
				transforms.append(Transform3D(Basis(), Vector3(lx, y, lz) * CUBE))
				colors.append(gen.get_color(wx, wz, y, h))

	mm.instance_count = transforms.size()
	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])
		mm.set_instance_color(i, colors[i])

	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	add_child(mmi)

func _build_collision() -> void:
	var faces := PackedVector3Array()
	for lx in SIZE:
		for lz in SIZE:
			var wx := cx * SIZE + lx
			var wz := cz * SIZE + lz
			var h := gen.get_height(wx, wz)
			var top := (float(h) + 0.5) * CUBE
			var x0 := (lx - 0.5) * CUBE
			var x1 := (lx + 0.5) * CUBE
			var z0 := (lz - 0.5) * CUBE
			var z1 := (lz + 0.5) * CUBE
			# Dessus (marchable). Ordre choisi pour que la normale pointe vers le HAUT
			# (au cas où Jolt ignorerait backface_collision, le sol reste solide par-dessus).
			# Les quads voisins se touchent à ±0.5 : aucun trou entre colonnes/chunks.
			_quad(faces,
				Vector3(x0, top, z0), Vector3(x0, top, z1),
				Vector3(x1, top, z1), Vector3(x1, top, z0))
			# Faces de falaise, uniquement vers un voisin plus bas (= vrai mur).
			_side(faces, wx + 1, wz, h, x1, z0, x1, z1)
			_side(faces, wx - 1, wz, h, x0, z1, x0, z0)
			_side(faces, wx, wz + 1, h, x1, z1, x0, z1)
			_side(faces, wx, wz - 1, h, x0, z0, x1, z0)

	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	# backface_collision = true => l'orientation des triangles n'a pas d'importance,
	# on entre en collision des deux côtés. Robuste et suffisant pour une base.
	shape.backface_collision = true

	var cs := CollisionShape3D.new()
	cs.shape = shape
	var body := StaticBody3D.new()
	body.add_child(cs)
	add_child(body)

func _build_trees() -> void:
	var shadow_pos: Array[Vector3] = []
	for lx in SIZE:
		for lz in SIZE:
			var wx := cx * SIZE + lx
			var wz := cz * SIZE + lz
			if gen.has_tree(wx, wz):
				var h := gen.get_height(wx, wz)
				# Arbre 100 % procédural (TreeGen) : construit cube par cube avec
				# une graine dérivée du seed et de la position — chaque arbre du
				# monde est unique, mais le même monde redonne les mêmes arbres.
				# Ses cubes font CUBE et tombent pile sur la grille du monde ; le
				# callable donne à TreeGen le relief autour du pied (racines qui
				# descendent en aval, cubes enterrés retirés en amont : jamais un
				# cube d'arbre sur un cube de terrain).
				var t := TreeGen.build(gen.world_seed, wx, wz,
					gen.get_biome(wx, wz) == TerrainGen.Biome.SNOW,
					func(dx: int, dz: int) -> int:
						return gen.get_height(wx + dx, wz + dz) - h)
				add_child(t)
				t.position = Vector3(lx * CUBE, (float(h) + 0.5) * CUBE, lz * CUBE)
				shadow_pos.append(t.position + Vector3(0, 0.04, 0))
	if shadow_pos.is_empty():
		return
	# Ombres rondes sous les troncs : un seul MultiMesh par chunk, affiché
	# uniquement quand les vraies ombres sont désactivées (sinon elles se
	# cumuleraient avec l'ombre portée du soleil).
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	# Rayon 4 m : de l'ordre du rayon des canopées procédurales (~3-4.5 m).
	mm.mesh = FX.blob_shadow_mesh(4.0)
	mm.instance_count = shadow_pos.size()
	for i in shadow_pos.size():
		mm.set_instance_transform(i, Transform3D(Basis(), shadow_pos[i]))
	tree_shadow_mmi = MultiMeshInstance3D.new()
	tree_shadow_mmi.multimesh = mm
	tree_shadow_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	tree_shadow_mmi.visible = tree_shadows_visible
	add_child(tree_shadow_mmi)

# Décorations (herbe, fleurs, cactus, rochers) : un seul MultiMesh de plus
# par chunk, mise à l'échelle par instance via la Basis du transform.
func _build_deco() -> void:
	var transforms: Array[Transform3D] = []
	var colors: Array[Color] = []
	for lx in SIZE:
		for lz in SIZE:
			var wx := cx * SIZE + lx
			var wz := cz * SIZE + lz
			var d := gen.get_decoration(wx, wz)
			if d.is_empty():
				continue
			var h := gen.get_height(wx, wz)
			var size: Vector3 = d["size"] # taille MONDE (les décos ne rétrécissent pas avec les cubes)
			var pos := Vector3(lx * CUBE, (float(h) + 0.5) * CUBE + size.y * 0.5, lz * CUBE)
			transforms.append(Transform3D(Basis().scaled(size), pos))
			colors.append(d["color"])
	if transforms.is_empty():
		return

	var box := BoxMesh.new()
	box.size = Vector3.ONE
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	box.material = mat

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = box
	mm.instance_count = transforms.size()
	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])
		mm.set_instance_color(i, colors[i])

	deco_mmi = MultiMeshInstance3D.new()
	deco_mmi.multimesh = mm
	deco_mmi.visible = deco_visible
	if deco_view_dist > 0.0:
		# Les petites décos disparaissent (en fondu) bien avant la limite des
		# chunks : invisible de loin de toute façon, et ça allège le rendu.
		deco_mmi.visibility_range_end = deco_view_dist
		deco_mmi.visibility_range_end_margin = 4.0
		deco_mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(deco_mmi)

# L'eau est un BLOC comme les autres, SANS COLLISION : chaque colonne immergée
# porte un bloc d'eau de surface, aligné sur la grille du monde, dont on émet
# la face du dessus (les faces latérales et le dessous sont toujours contre du
# terrain ou un autre bloc d'eau : jamais visibles, on ne les génère pas). Le
# dessus du bloc est posé au niveau WATER_Y (bloc de surface partiel, comme le
# gameplay l'attend).
# Aucun StaticBody : on traverse l'eau librement (la nage sonde le terrain).
func _build_water() -> void:
	if water_material == null:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any := false
	var y := TerrainGen.WATER_Y * CUBE # dessus du bloc d'eau de surface
	for lx in SIZE:
		for lz in SIZE:
			var wx := cx * SIZE + lx
			var wz := cz * SIZE + lz
			if float(gen.get_height(wx, wz)) + 0.5 >= TerrainGen.WATER_Y:
				continue # colonne émergée : pas de bloc d'eau ici
			any = true
			var x0 := (lx - 0.5) * CUBE
			var x1 := (lx + 0.5) * CUBE
			var z0 := (lz - 0.5) * CUBE
			var z1 := (lz + 0.5) * CUBE
			_water_vertex(st, Vector3(x0, y, z0), Vector2(0, 0))
			_water_vertex(st, Vector3(x1, y, z0), Vector2(1, 0))
			_water_vertex(st, Vector3(x1, y, z1), Vector2(1, 1))
			_water_vertex(st, Vector3(x0, y, z0), Vector2(0, 0))
			_water_vertex(st, Vector3(x1, y, z1), Vector2(1, 1))
			_water_vertex(st, Vector3(x0, y, z1), Vector2(0, 1))
	if not any:
		return
	st.generate_tangents() # requis par le NORMAL_MAP du shader d'eau
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = water_material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

func _water_vertex(st: SurfaceTool, v: Vector3, uv: Vector2) -> void:
	st.set_normal(Vector3.UP)
	# UV locales au bloc (0..1 par face). Les vaguelettes du shader, elles,
	# s'ancrent en coordonnées MONDE (via MODEL_MATRIX) : aucune couture entre
	# blocs ni entre chunks.
	st.set_uv(uv)
	st.add_vertex(v)

func _column_bottom(wx: int, wz: int, h: int) -> int:
	var m := h
	m = mini(m, gen.get_height(wx + 1, wz))
	m = mini(m, gen.get_height(wx - 1, wz))
	m = mini(m, gen.get_height(wx, wz + 1))
	m = mini(m, gen.get_height(wx, wz - 1))
	return m

func _quad(faces: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	faces.append(a); faces.append(b); faces.append(c)
	faces.append(a); faces.append(c); faces.append(d)

func _side(faces: PackedVector3Array, nwx: int, nwz: int, h: int, xa: float, za: float, xb: float, zb: float) -> void:
	var nh := gen.get_height(nwx, nwz)
	if nh >= h:
		return # voisin aussi haut ou plus haut : rien d'exposé
	var y_top := (float(h) + 0.5) * CUBE
	var y_bot := (float(nh) + 0.5) * CUBE
	_quad(faces,
		Vector3(xa, y_bot, za), Vector3(xb, y_bot, zb),
		Vector3(xb, y_top, zb), Vector3(xa, y_top, za))
