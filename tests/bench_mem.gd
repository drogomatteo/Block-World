extends SceneTree

# Banc de mesure mémoire : godot --headless -s res://tests/bench_mem.gd
# Charge une session (seed fixe), construit tous les chunks (~307 m de vue) et
# imprime la mémoire statique + un inventaire (nœuds, colliders, sommets).
# Sert à comparer avant/après une optimisation ; pas un test (pas de checks).

func _initialize() -> void:
	_run()

func _run() -> void:
	var world = (load("res://Scènes/Monde/world.tscn") as PackedScene).instantiate()
	root.add_child(world)
	await process_frame
	world.start_session({"name": "Bench", "class_id": "warrior"}, 12345)
	world.max_enemies = 0
	world.enemy_spawn_interval = 1e9
	world._enemy_timer = 1e9
	world.set_render_distance(8) # chunks de 32 cubes : même vue que 16 × 16 cubes
	world.chunk_build_per_frame = 16
	for i in 20000:
		await process_frame
		var lq = world.get("lod_queue") # absent sur l'ancien code
		if world.build_queue.is_empty() and (lq == null or lq.is_empty()):
			break
	for i in 5:
		await process_frame # laisse les queue_free s'appliquer
	var c := {"nodes": 0, "static_bodies": 0, "collision_shapes": 0,
		"mesh_instances": 0, "mesh_vertices": 0, "mm_instances": 0}
	_count(root, c)
	print("chunks: ", world.loaded_chunks.size())
	print("static_mem_MB: %.1f" % (OS.get_static_memory_usage() / 1048576.0))
	print(c)
	quit(0)

func _count(n: Node, c: Dictionary) -> void:
	c["nodes"] += 1
	if n is StaticBody3D:
		c["static_bodies"] += 1
	elif n is CollisionShape3D:
		c["collision_shapes"] += 1
	elif n is MultiMeshInstance3D:
		if (n as MultiMeshInstance3D).multimesh != null:
			c["mm_instances"] += (n as MultiMeshInstance3D).multimesh.instance_count
	elif n is MeshInstance3D:
		var m := (n as MeshInstance3D).mesh
		if m is ArrayMesh:
			c["mesh_instances"] += 1
			for s in (m as ArrayMesh).get_surface_count():
				c["mesh_vertices"] += ((m as ArrayMesh).surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	for ch in n.get_children():
		_count(ch, c)
