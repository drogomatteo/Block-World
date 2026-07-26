extends SceneTree

# Fusionne les brins d'herbe du MultiMesh de Assets/Grass.tscn (l'asset de
# l'utilisateur : 128 brins sur une emprise d'un bloc) en UN SEUL ArrayMesh.
# Chaque chunk instancie ensuite la touffe entière via son propre MultiMesh
# (1 draw call pour toute l'herbe du chunk) avec une couleur PAR INSTANCE
# accordée au bloc de sol (vertex_color_use_as_albedo).
# Une légère variation de luminosité par brin est cuite dans les couleurs de
# sommet — elles MULTIPLIENT la couleur d'instance : l'herbe n'est jamais plate.
# Écrit Assets/grass_mesh.res, référencé par Scripts/chunk.gd.
# À relancer après chaque retouche de Assets/Grass.tscn :
#   godot --headless -s res://tools/gen_grass_mesh.gd

func _init() -> void:
	var src = (load("res://Assets/Grass.tscn") as PackedScene).instantiate()
	var mm: MultiMesh = null
	# Transform du NŒUD MultiMeshInstance3D lui-même (l'utilisateur y règle la
	# hauteur des brins, ex. +0.3 pour les poser SUR le sol) : cuit aussi.
	var node_xf := Transform3D.IDENTITY
	for c in src.get_children():
		if c is MultiMeshInstance3D:
			mm = (c as MultiMeshInstance3D).multimesh
			node_xf = (c as MultiMeshInstance3D).transform
	var arr := mm.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]

	# PIÈGE headless : le buffer d'instances vit dans le RenderingServer — avec
	# le renderer factice, get_instance_transform renvoie l'IDENTITÉ (vécu : les
	# 128 brins fusionnés au même endroit). La propriété `buffer`, elle, est
	# fidèle au .tscn : on décode ses 12 floats par instance (3 lignes de la
	# matrice 3×4 : basis colonne par colonne + composante d'origine).
	var buf := mm.buffer
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = 48151623 # fixe : relancer l'outil redonne exactement le même .res
	for i in mm.instance_count:
		var f := buf.slice(i * 12, i * 12 + 12)
		var xf := node_xf * Transform3D(
			Vector3(f[0], f[4], f[8]), Vector3(f[1], f[5], f[9]),
			Vector3(f[2], f[6], f[10]), Vector3(f[3], f[7], f[11]))
		var shade := rng.randf_range(0.85, 1.08)
		var col := Color(shade, shade, shade)
		for j in idx:
			st.set_color(col)
			st.set_normal((xf.basis * normals[j]).normalized())
			st.add_vertex(xf * verts[j])
	src.free()
	st.index()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	st.set_material(mat)
	var mesh := st.commit()
	var err := ResourceSaver.save(mesh, "res://Assets/grass_mesh.res")
	var out_verts: int = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
	print("Fusion : %d brins -> 1 surface de %d sommets (save err=%d)"
		% [mm.instance_count, out_verts, err])
	quit()
