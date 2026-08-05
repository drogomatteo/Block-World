extends SceneTree
# Banc d'essai du mesher : godot --headless -s res://tests/bench.gd
# Mesure séparément la construction des données RLE et le maillage sur une
# zone de 100x100 chunks, et compte les rectangles produits.

func _init() -> void:
	var template = load("res://Scènes/Cubes/Cubes.tscn").instantiate()
	var noise: FastNoiseLite = template.noise
	var with_trees: bool = template.generate_trees
	template.free()

	var n := 0
	var data_us := 0
	var mesh_us := 0
	var verts := 0
	var quads := 0
	for cx in range(100):
		for cz in range(100):
			var t0 := Time.get_ticks_usec()
			var data := ChunkData.new()
			data.build(noise, Vector3i(cx, 0, cz), with_trees)
			var t1 := Time.get_ticks_usec()
			var mesh := ChunkMesher.build(data)
			var t2 := Time.get_ticks_usec()
			data_us += t1 - t0
			mesh_us += t2 - t1
			if mesh != null:
				var arrays := mesh.surface_get_arrays(0)
				var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				verts += v.size()
				quads += v.size() / 4
			n += 1

	print("%d chunks" % n)
	print("données RLE : %.2f ms/chunk" % (data_us / 1000.0 / n))
	print("maillage    : %.2f ms/chunk" % (mesh_us / 1000.0 / n))
	print("total       : %.2f ms/chunk" % ((data_us + mesh_us) / 1000.0 / n))
	print("%d rectangles, %d sommets (%.1f sommets/chunk)" % [quads, verts, float(verts) / n])
	quit(0)
