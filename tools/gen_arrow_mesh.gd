extends SceneTree

# Fusionne tous les MeshInstance3D de Assets/Arrow.glb (un par cube Blender)
# en UN SEUL ArrayMesh : l'albedo de chaque matériau source devient une couleur
# PAR SOMMET, un unique StandardMaterial3D (vertex_color_use_as_albedo) habille
# le tout → 1 flèche = 1 MeshInstance3D = 1 draw call (au lieu de 30).
# Écrit Assets/arrow_mesh.res, référencé par Scènes/Objets/Arrow.tscn.
# À relancer après chaque réexport Blender de la flèche :
#   godot --headless -s res://tools/gen_arrow_mesh.gd

func _init() -> void:
	var src = (load("res://Assets/Arrow.glb") as PackedScene).instantiate()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var stats := {"meshes": 0, "verts": 0}
	_merge(src, Transform3D.IDENTITY, st, stats)
	src.free()
	st.index()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	st.set_material(mat)
	var mesh := st.commit()
	var err := ResourceSaver.save(mesh, "res://Assets/arrow_mesh.res")
	var out_verts: int = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
	print("Fusion : %d meshes / %d sommets -> 1 surface de %d sommets (save err=%d)"
		% [stats.meshes, stats.verts, out_verts, err])
	quit()

func _merge(n: Node, xf: Transform3D, st: SurfaceTool, stats: Dictionary) -> void:
	if n is Node3D:
		xf = xf * (n as Node3D).transform
	if n is MeshInstance3D:
		var m: Mesh = (n as MeshInstance3D).mesh
		for s in m.get_surface_count():
			var bmat := m.surface_get_material(s) as BaseMaterial3D
			var col := bmat.albedo_color if bmat != null else Color.WHITE
			var arr := m.surface_get_arrays(s)
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var normals = arr[Mesh.ARRAY_NORMAL]
			var idx = arr[Mesh.ARRAY_INDEX]
			if idx == null or idx.is_empty():
				idx = PackedInt32Array(range(verts.size()))
			for i in idx:
				st.set_color(col)
				if normals != null:
					st.set_normal((xf.basis * normals[i]).normalized())
				st.add_vertex(xf * verts[i])
			stats.meshes += 1
			stats.verts += verts.size()
	for c in n.get_children():
		_merge(c, xf, st, stats)
