class_name Chunk
extends Node3D

# Un chunk = une portion carrée SIZE x SIZE colonnes du monde.
# Rendu   : UN SEUL MultiMeshInstance3D (donc 1 draw call pour tous les cubes).
# Collision: UN SEUL collider trimesh (dessus + faces de falaise exposées).
# Les instances/faces sont en coordonnées LOCALES ; le nœud Chunk est placé
# à la position monde (cx*SIZE*CUBE, 0, cz*SIZE*CUBE) par world.gd.

const SIZE := 16
# Taille MONDE d'un cube (des blocs plus fins, façon Cube World). TerrainGen
# travaille en indices de cube ; tout ce qui parle en mètres passe par CUBE.
const CUBE := 0.5

var gen: TerrainGen
var cx: int
var cz: int
var tree_scene: PackedScene
var water_material: Material # partagé, créé une seule fois par world.gd

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
	if tree_scene == null:
		return
	for lx in SIZE:
		for lz in SIZE:
			var wx := cx * SIZE + lx
			var wz := cz * SIZE + lz
			if gen.has_tree(wx, wz):
				var h := gen.get_height(wx, wz)
				var t := tree_scene.instantiate()
				add_child(t)
				# Position à l'échelle cube ; l'arbre garde sa taille MONDE
				# (il couvre plusieurs petits blocs, comme dans Cube World).
				t.position = Vector3(lx * CUBE, (float(h) + 0.5) * CUBE, lz * CUBE)
				# Variation de taille déterministe : forêt moins uniforme.
				var s := 0.8 + gen.rand01(wx, wz, 13) * 0.6
				t.scale = Vector3(s, s, s)

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

	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	add_child(mmi)

# Surface d'eau : un quad par colonne immergée, rien ailleurs. Les lacs ont
# donc une vraie étendue locale (fini l'océan infini qui suivait le joueur).
# Les sommets sont déplacés par le vertex shader du matériau (vaguelettes en
# coordonnées monde) : les bords coïncident entre colonnes et entre chunks.
func _build_water() -> void:
	if water_material == null:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any := false
	var y := TerrainGen.WATER_Y * CUBE # niveau monde de l'eau
	for lx in SIZE:
		for lz in SIZE:
			var wx := cx * SIZE + lx
			var wz := cz * SIZE + lz
			if float(gen.get_height(wx, wz)) + 0.5 >= TerrainGen.WATER_Y:
				continue # colonne émergée : pas d'eau ici
			any = true
			var x0 := (lx - 0.5) * CUBE
			var x1 := (lx + 0.5) * CUBE
			var z0 := (lz - 0.5) * CUBE
			var z1 := (lz + 0.5) * CUBE
			_water_vertex(st, Vector3(x0, y, z0))
			_water_vertex(st, Vector3(x1, y, z0))
			_water_vertex(st, Vector3(x1, y, z1))
			_water_vertex(st, Vector3(x0, y, z0))
			_water_vertex(st, Vector3(x1, y, z1))
			_water_vertex(st, Vector3(x0, y, z1))
	if not any:
		return
	st.generate_tangents() # requis par le NORMAL_MAP du shader d'eau
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = water_material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

func _water_vertex(st: SurfaceTool, v: Vector3) -> void:
	st.set_normal(Vector3.UP)
	# UV en coordonnées monde : nécessaire pour generate_tangents().
	st.set_uv(Vector2(cx * SIZE * CUBE + v.x, cz * SIZE * CUBE + v.z))
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
