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

	# --- Strates par biome (fonctions pures) -------------------------------
	var world_seed : int = chunk.noise.seed
	var srt_ok := true
	var srt : Array = BiomeMap.strata(world_seed, 10, 10, BiomeMap.DESERT, 15)
	srt_ok = srt_ok and srt[-1][0] == WorldConfig.SAND and srt[0][0] == WorldConfig.ROCK
	srt = BiomeMap.strata(world_seed, 10, 10, BiomeMap.PLAINES, 15)
	srt_ok = srt_ok and srt[-1][0] == WorldConfig.GRASS and srt[0][0] == WorldConfig.DIRT
	srt = BiomeMap.strata(world_seed, 10, 10, BiomeMap.NEIGE, 15)
	srt_ok = srt_ok and srt[-1][0] == WorldConfig.SNOW
	srt = BiomeMap.strata(world_seed, 10, 10, BiomeMap.MONTAGNES, 30)
	srt_ok = srt_ok and srt[-1][0] == WorldConfig.DIRT and srt[0][0] == WorldConfig.ROCK
	srt = BiomeMap.strata(world_seed, 10, 10, BiomeMap.MONTAGNES, 60)
	srt_ok = srt_ok and (srt[-1][0] == WorldConfig.SNOW or srt[-1][0] == WorldConfig.ICE)
	srt = BiomeMap.strata(world_seed, 10, 10, BiomeMap.OCEAN, 4)
	srt_ok = srt_ok and srt[-1][0] == WorldConfig.SAND
	srt = BiomeMap.strata(world_seed, 10, 10, BiomeMap.OCEAN, WorldConfig.SEA_LEVEL + 5)
	srt_ok = srt_ok and srt[-1][0] == WorldConfig.GRASS
	check("strates : bloc de surface conforme par biome", srt_ok)
	var total_ok := true
	for b in range(5):
		var s2 : Array = BiomeMap.strata(world_seed, 3, 7, b, 20)
		var n2 := 0
		for run in s2:
			n2 += run[1]
		total_ok = total_ok and n2 == 22
	check("strates : longueur totale = sommet + 2 (les 5 biomes)", total_ok)

	# --- Arbres ------------------------------------------------------------
	# Les arbres dépendent du biome : chercher une zone 2×2 chunks de plaines
	# (spirale de Chebyshev depuis l'origine ; un anneau de cellules Worley en
	# contient toujours une à portée).
	var pc := Vector2i.ZERO
	var found_plains := false
	for r in range(0, 60):
		for cx in range(-r, r + 1):
			for cz in range(-r, r + 1):
				if maxi(absi(cx), absi(cz)) != r:
					continue  # seulement l'anneau du rayon r
				var ok_zone := true
				for corner in [Vector2i(0, 0), Vector2i(2, 0), Vector2i(0, 2), Vector2i(2, 2), Vector2i(1, 1)]:
					if BiomeMap.biome_at(world_seed,
							(cx + corner.x) * Chunk.width,
							(cz + corner.y) * Chunk.depth) != BiomeMap.PLAINES:
						ok_zone = false
						break
				if ok_zone:
					pc = Vector2i(cx, cz)
					found_plains = true
					break
			if found_plains:
				break
		if found_plains:
			break
	check("zone de plaines trouvée pour les arbres (chunk %s)" % str(pc), found_plains)

	# Présence : du bois et des feuilles quelque part dans la zone de plaines
	var wood_found := false
	var leaves_found := false
	var zone := []
	for cpos in [Vector3i(pc.x, 0, pc.y), Vector3i(pc.x + 1, 0, pc.y),
			Vector3i(pc.x, 0, pc.y + 1), Vector3i(pc.x + 1, 0, pc.y + 1),
			Vector3i(pc.x, 1, pc.y)]:
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

	# Surface des plaines : herbe posée sur de la terre (strates dans un vrai
	# chunk, en évitant les colonnes modifiées par un tronc au-dessus)
	var base = zone[0]
	var surface_ok := true
	for x in range(0, Chunk.width, 3):
		var top : int = base.data.col_top(x, 7)
		if top < 1:
			continue
		if base.block_at(x, top, 7) != WorldConfig.GRASS \
				or base.block_at(x, top - 1, 7) != WorldConfig.DIRT:
			surface_ok = false
	check("plaines : herbe en surface, terre en dessous", surface_ok)

	# Raccord aux frontières : la vue « marge » du chunk (is_air hors limites)
	# doit coïncider avec les voxels réellement générés par le voisin
	var border_ok := true
	var east = zone[1]   # est de la zone de plaines
	var above = zone[4]  # au-dessus de la zone
	for y in range(Chunk.height):
		for z in range(Chunk.depth):
			if base.is_air(Chunk.width, y, z) != (east.block_at(0, y, z) == 0):
				border_ok = false
	for x in range(Chunk.width):
		for z in range(Chunk.depth):
			if base.is_air(x, Chunk.height, z) != (above.block_at(x, 0, z) == 0):
				border_ok = false
	check("frontières cohérentes avec les voisins (est + dessus)", border_ok)

	# --- LOD ---------------------------------------------------------------
	# Aux pas 2 et 4 : un nœud couvre pas×pas chunks avec une grille fixe de
	# 32×32 cellules de pas blocs — maillage valide, coordonnées dans
	# l'emprise élargie du nœud et alignées sur la grille du pas.
	var lod_ok := true
	for lstep in [2, 4]:
		var ld := ChunkData.new()
		ld.build(chunk.noise, Vector3i(0, 0, 0), false, lstep)
		var lmesh := ChunkMesher.build(ld)
		if lmesh == null:
			lod_ok = false
			continue
		var lv: PackedVector3Array = lmesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		if lv.size() % 4 != 0 or lv.is_empty():
			lod_ok = false
		var fs := float(lstep)
		var span := float(Chunk.width * lstep)
		for v in lv:
			if v.x < -fs or v.x > span + fs or v.z < -fs or v.z > span + fs:
				lod_ok = false
				break
			# sommets à la demi-cellule près (tolérance : compression 16 bits)
			for c in [v.x / fs, v.y / fs, v.z / fs]:
				var fr : float = absf(fposmod(c + 0.5, 1.0))
				if minf(fr, 1.0 - fr) > 0.05:
					lod_ok = false
	check("LOD 2 et 4 : nœuds pas×pas chunks valides et alignés", lod_ok)

	# --- Déterminisme ------------------------------------------------------
	var chunk2 = load("res://Scènes/Cubes/Cubes.tscn").instantiate()
	chunk2.chunk_position = Vector3i(0, 0, 0)
	root.add_child(chunk2)
	chunk2.generate_chunk()
	var verts2: PackedVector3Array = chunk2.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	check("déterministe : même maillage au 2e build", verts2 == verts)

	print("\n%d checks, %d échecs" % [checks, fails])
	quit(1 if fails > 0 else 0)
