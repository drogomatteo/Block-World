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

	# --- Le maillage produit ----------------------------------------------
	var mesh: ArrayMesh = chunk.mesh
	check("1 surface", mesh != null and mesh.get_surface_count() == 1)
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	check("6 sommets par face exposée (%d sommets)" % verts.size(), verts.size() == exposed_total * 6)
	check("1 couleur par sommet", colors.size() == verts.size())

	var normal_ok := true
	var color_ok := true
	for i in range(0, verts.size(), 6):
		var n: Vector3 = normals[i]
		if absf(n.length() - 1.0) > 0.01 or absf(n.x) + absf(n.y) + absf(n.z) > 1.01:
			normal_ok = false
		# winding : face avant = horaire, donc la normale géométrique est opposée
		var geo_n: Vector3 = (verts[i + 1] - verts[i]).cross(verts[i + 2] - verts[i]).normalized()
		if geo_n.dot(n) > -0.99:
			normal_ok = false
		# couleur : les 6 sommets identiques, et conforme à la table BLOCKS selon
		# l'id du bloc de la face — normale recalée sur l'axe exact (le buffer les
		# compresse en octaédrique), tolérance 1/255 : couleurs quantifiées en RGBA8
		var axis_n: Vector3 = Chunk.DIRECTIONS[0]
		for dir in Chunk.DIRECTIONS:
			if n.dot(dir) > n.dot(axis_n):
				axis_n = dir
		# bloc retrouvé par géométrie : centre de face = centre du bloc + normale/2
		var center: Vector3 = (verts[i] + verts[i + 1] + verts[i + 2] + verts[i + 5]) / 4.0
		var cell_f: Vector3 = (center - axis_n * 0.5 * Chunk.cube_size) / Chunk.cube_size
		var cell := Vector3i(cell_f.round())
		var expected: Color = chunk.block_color_for_face(chunk.block_at(cell.x, cell.y, cell.z), axis_n)
		for j in range(6):
			var d: Color = colors[i + j] - expected
			if absf(d.r) > 1.0 / 255 or absf(d.g) > 1.0 / 255 or absf(d.b) > 1.0 / 255:
				color_ok = false
	check("normales sur axes + winding horaire (face avant)", normal_ok)
	check("couleur des faces = table BLOCKS selon la direction", color_ok)

	# --- Matériau ----------------------------------------------------------
	var mat: Material = mesh.surface_get_material(0)
	check("matériau de surface posé en code", mat is StandardMaterial3D)
	check("vertex_color_use_as_albedo actif", mat != null and mat.vertex_color_use_as_albedo)
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
