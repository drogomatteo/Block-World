extends SceneTree
# Smoke test du maillage de chunk : godot --headless -s res://tests/smoke.gd

var checks := 0
var fails := 0

func check(name: String, ok: bool) -> void:
	checks += 1
	if not ok:
		fails += 1
		print("  ÉCHEC : ", name)
	else:
		print("  ok    : ", name)

func _init() -> void:
	var chunk = load("res://Scènes/Cubes/Cubes.tscn").instantiate()
	chunk.chunk_position = Vector3i(0, 0, 0)
	root.add_child(chunk)
	chunk.generate_chunk()

	# --- Faces exposées d'après les masques -------------------------------
	# Les tranches au-dessus de top_solid_y sont vides : on s'arrête là pour
	# ne pas balayer les ~250 tranches d'air d'un chunk de hauteur 256.
	var exposed_total := 0
	for direction in Chunk.DIRECTIONS:
		var info: Dictionary = chunk.axis_info(direction)
		var slices : int = info["slices"]
		if direction == Vector3.UP or direction == Vector3.DOWN:
			slices = chunk.top_solid_y + 1
		for s in range(slices):
			var mask: Array = chunk.build_mask(direction, s)
			for u in range(info["u"]):
				for v in range(info["v"]):
					if mask[u][v] != -1:
						exposed_total += 1
	check("des faces exposées existent (%d)" % exposed_total, exposed_total > 0)

	# --- Le maillage produit (binary greedy mesher : rectangles indexés) ---
	var mesh: ArrayMesh = chunk.mesh
	check("1 surface", mesh != null and mesh.get_surface_count() == 1)
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var quad_count := verts.size() / 4
	check("maillage indexé : 4 sommets et 6 indices par rectangle (%d rects)" % quad_count,
		verts.size() % 4 == 0 and indices.size() == quad_count * 6)
	check("1 couleur par sommet", colors.size() == verts.size())
	check("1 facteur d'AO par sommet (UV.x)", uvs.size() == verts.size())
	check("fusion effective : %d sommets < %d (6 par face)" % [verts.size(), exposed_total * 6],
		verts.size() < exposed_total * 6)

	# Chaque rectangle doit couvrir uniquement des faces exposées valides, sans
	# chevauchement, et l'ensemble doit couvrir exactement les faces exposées.
	var covered := {}
	var quads_ok := true
	var normal_ok := true
	var color_ok := true
	var alpha_ok := true
	var ao_ok := true
	var occluded_corners := 0
	for q in range(0, verts.size(), 4):
		var n: Vector3 = normals[q]
		if absf(n.length() - 1.0) > 0.01 or absf(n.x) + absf(n.y) + absf(n.z) > 1.01:
			normal_ok = false
		# normale recalée sur l'axe exact (le buffer les compresse en octaédrique)
		var axis_n: Vector3 = Chunk.DIRECTIONS[0]
		for dir in Chunk.DIRECTIONS:
			if n.dot(dir) > n.dot(axis_n):
				axis_n = dir
		# winding : face avant = horaire, donc la normale géométrique est opposée
		var geo_n: Vector3 = (verts[q + 1] - verts[q]).cross(verts[q + 2] - verts[q]).normalized()
		if geo_n.dot(axis_n) > -0.99:
			normal_ok = false
		# les 4 sommets partagent la couleur du rectangle
		for j in range(1, 4):
			if colors[q + j] != colors[q]:
				color_ok = false
		# cellules couvertes : bornes du rectangle en unités de blocs
		var bmin: Vector3 = verts[q] / Chunk.cube_size
		var bmax: Vector3 = bmin
		for j in range(1, 4):
			bmin = bmin.min(verts[q + j] / Chunk.cube_size)
			bmax = bmax.max(verts[q + j] / Chunk.cube_size)
		var a := Vector3i(axis_n)
		var lo := Vector3i()
		var hi := Vector3i()
		for axis in range(3):
			if a[axis] != 0:
				lo[axis] = roundi(bmin[axis] - 0.5 * a[axis])
				hi[axis] = lo[axis]
			else:
				lo[axis] = roundi(bmin[axis] + 0.5)
				hi[axis] = roundi(bmax[axis] - 0.5)
		for cx in range(lo.x, hi.x + 1):
			for cy in range(lo.y, hi.y + 1):
				for cz in range(lo.z, hi.z + 1):
					var cell_key := [Vector3i(cx, cy, cz), a]
					if covered.has(cell_key):
						quads_ok = false  # chevauchement de rectangles
					covered[cell_key] = true
					var id: int = chunk.block_at(cx, cy, cz)
					if id == 0 or not chunk.is_air(cx + a.x, cy + a.y, cz + a.z):
						quads_ok = false  # face couverte alors qu'elle n'est pas exposée
					# couleur conforme à la table BLOCKS, tolérance 1/255 (RGBA8)
					var expected: Color = chunk.block_color_for_face(id, axis_n)
					var d: Color = colors[q] - expected
					if absf(d.r) > 1.0 / 255 or absf(d.g) > 1.0 / 255 or absf(d.b) > 1.0 / 255:
						color_ok = false
					# l'alpha transporte l'id du bloc vers le shader de teinte
					if roundi(colors[q].a * 255.0) != id:
						alpha_ok = false

		# AO : le facteur de lumière de chaque coin (UV.x) doit correspondre à
		# la règle des 3 voisins, recalculée ici depuis les voxels (chemin
		# indépendant du mesher). La fusion n'unissant que des motifs d'AO
		# identiques, le coin du rectangle = le coin de sa cellule de coin.
		for j in range(4):
			var vv: Vector3 = verts[q + j] / Chunk.cube_size
			var cell := Vector3i()
			var t1 := Vector3i()  # directions de coin sur les 2 axes tangents
			var t2 := Vector3i()
			var first_tangent := true
			for axis in range(3):
				if a[axis] != 0:
					cell[axis] = lo[axis]
				else:
					var at_min: bool = absf(vv[axis] - bmin[axis]) < 0.1
					cell[axis] = lo[axis] if at_min else hi[axis]
					if first_tangent:
						t1[axis] = -1 if at_min else 1
						first_tangent = false
					else:
						t2[axis] = -1 if at_min else 1
			var p: Vector3i = cell + a  # le plan devant la face
			var s1 := 0 if chunk.block_at(p.x + t1.x, p.y + t1.y, p.z + t1.z) == 0 else 1
			var s2 := 0 if chunk.block_at(p.x + t2.x, p.y + t2.y, p.z + t2.z) == 0 else 1
			var cc := 0 if chunk.block_at(p.x + t1.x + t2.x, p.y + t1.y + t2.y, p.z + t1.z + t2.z) == 0 else 1
			var lvl: int = 3 if (s1 == 1 and s2 == 1) else s1 + s2 + cc
			if absf(uvs[q + j].x - ChunkMesher.AO_LIGHT[lvl]) > 0.02:
				ao_ok = false
			if lvl > 0:
				occluded_corners += 1
	check("rectangles <-> faces exposées : bijection (%d cellules)" % covered.size(),
		quads_ok and covered.size() == exposed_total)
	check("AO des coins = règle des 3 voisins recalculée (%d coins occlus)" % occluded_corners,
		ao_ok and occluded_corners > 0)
	check("normales sur axes + winding horaire (face avant)", normal_ok)
	check("couleur des faces = table BLOCKS selon la direction", color_ok)
	check("alpha des sommets = id du bloc (pour le shader de teinte)", alpha_ok)

	# --- Matériau ----------------------------------------------------------
	var mat: Material = mesh.surface_get_material(0)
	check("matériau de surface posé en code (ShaderMaterial)", mat is ShaderMaterial)
	check("shader des chunks chargé",
		mat != null and mat.shader != null
		and mat.shader.resource_path == "res://Ressource/Shaders/chunk.gdshader")
	check("matériau partagé entre chunks (static)", mat == Chunk.block_material)
	check("plus de material_override dans la scène", chunk.material_override == null)

	# --- Arbres ------------------------------------------------------------
	# Présence : du bois et des feuilles quelque part dans une petite zone
	var wood_found := false
	var leaves_found := false
	var zone := [chunk]
	for cpos in [Vector3i(1, 0, 0), Vector3i(0, 0, 1), Vector3i(1, 0, 1), Vector3i(0, 1, 0)]:
		var c = load("res://Scènes/Cubes/Cubes.tscn").instantiate()
		c.chunk_position = cpos
		root.add_child(c)
		c.generate_chunk()
		zone.append(c)
	for c in zone:
		for x in range(Chunk.width):
			for y in range(c.top_solid_y + 1):
				for z in range(Chunk.depth):
					var id : int = c.block_at(x, y, z)
					if id == 2:
						wood_found = true
					elif id == 3:
						leaves_found = true
	check("du bois généré dans la zone", wood_found)
	check("des feuilles générées dans la zone", leaves_found)

	# Raccord aux frontières : la vue « marge » du chunk (is_air hors limites)
	# doit coïncider avec les voxels réellement générés par le voisin
	var border_ok := true
	var east = zone[1]   # (1,0,0)
	var above = zone[4]  # (0,1,0)
	for y in range(Chunk.height):
		for z in range(Chunk.depth):
			if chunk.is_air(Chunk.width, y, z) != (east.block_at(0, y, z) == 0):
				border_ok = false
	for x in range(Chunk.width):
		for z in range(Chunk.depth):
			if chunk.is_air(x, Chunk.height, z) != (above.block_at(x, 0, z) == 0):
				border_ok = false
	check("frontières cohérentes avec les voisins (est + dessus)", border_ok)

	# --- Déterminisme ------------------------------------------------------
	var chunk2 = load("res://Scènes/Cubes/Cubes.tscn").instantiate()
	chunk2.chunk_position = Vector3i(0, 0, 0)
	root.add_child(chunk2)
	chunk2.generate_chunk()
	var verts2: PackedVector3Array = chunk2.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	check("déterministe : même maillage au 2e build", verts2 == verts)

	print("\n%d checks, %d échecs" % [checks, fails])
	quit(1 if fails > 0 else 0)
