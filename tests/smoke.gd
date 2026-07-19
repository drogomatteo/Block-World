extends SceneTree

# Test de fumée headless : godot --headless -s res://tests/smoke.gd
# Charge le monde (menu principal), teste la persistance des profils, lance une
# session avec un seed fixe puis vérifie joueur (corps articulé, endurance,
# roulade), caméra, lanterne, cycle jour/nuit, génération (eau/arbres/déco),
# nage (hystérésis comprise), effet sous-marin et ennemis.

var fails := 0

func check(cond: bool, label: String) -> void:
	if cond:
		print("OK   - ", label)
	else:
		fails += 1
		printerr("FAIL - ", label)

func _initialize() -> void:
	_run()

func _run() -> void:
	var ws := load("res://Scènes/world.tscn") as PackedScene
	check(ws != null, "world.tscn se charge")
	var world = ws.instantiate()
	root.add_child(world)
	await process_frame
	await process_frame

	# --- Menu principal + persistance des profils ---
	check(world._menu != null, "le menu principal est affiché au lancement")
	check(world.gen == null, "pas de génération avant le choix d'un monde")
	var test_ch: Dictionary = MainMenu.create_character("__smoke__", "warrior")
	check(test_ch.has("key"), "création d'un personnage persisté")
	var listed := MainMenu.list_characters().filter(func(c): return c["key"] == test_ch["key"])
	check(listed.size() == 1, "le personnage créé est listé")
	test_ch["level"] = 3
	MainMenu.save_character(test_ch)
	listed = MainMenu.list_characters().filter(func(c): return c["key"] == test_ch["key"])
	check(listed.size() == 1 and int(listed[0]["level"]) == 3, "la progression sauvegardée est relue")
	MainMenu.delete_entry(test_ch["key"])
	listed = MainMenu.list_characters().filter(func(c): return c["key"] == test_ch["key"])
	check(listed.is_empty(), "la suppression retire le personnage")
	var test_w: Dictionary = MainMenu.create_world("__smoke_monde__", 12345)
	check(int(test_w.get("seed", 0)) == 12345, "création d'un monde avec sa graine")
	MainMenu.delete_entry(test_w["key"])

	# --- Lancement de session (sans passer par l'interface) ---
	world.start_session({"name": "Testeur", "class_id": "warrior"}, 12345)
	await process_frame
	check(world._menu == null, "le menu est fermé une fois la session lancée")

	# --- Génération : seuil de l'eau ---
	var gen: TerrainGen = world.gen
	check(gen != null, "générateur créé avec la graine du monde")
	var submerged := 0
	var beach := 0
	var deepest := 0.0            # lac le plus profond trouvé (pour le test de nage)
	var deep_pos := Vector2i.ZERO
	for x in range(-160, 160, 2):
		for z in range(-160, 160, 2):
			var top := float(gen.get_height(x, z)) + 0.5
			if top < TerrainGen.WATER_Y:
				submerged += 1
				if TerrainGen.WATER_Y - top > deepest:
					deepest = TerrainGen.WATER_Y - top
					deep_pos = Vector2i(x, z)
				if gen.has_tree(x, z):
					fails += 1
					printerr("FAIL - arbre sous l'eau en (%d, %d)" % [x, z])
				if not gen.get_decoration(x, z).is_empty():
					fails += 1
					printerr("FAIL - déco sous l'eau en (%d, %d)" % [x, z])
			elif top < TerrainGen.WATER_Y + 1.0: # bande de plage (1 cube)
				beach += 1
				if gen.has_tree(x, z):
					fails += 1
					printerr("FAIL - arbre sur la plage en (%d, %d)" % [x, z])
	check(submerged > 0, "l'échantillon contient des colonnes immergées (%d) et de plage (%d)" % [submerged, beach])

	# Laisse le streaming construire tous les chunks (1/frame, render distance
	# éventuellement remontée par le settings.cfg de la machine).
	for i in 600:
		await process_frame
		if world.build_queue.is_empty():
			break
	var player = world.player
	check(player != null, "joueur créé au lancement de la session")
	if player == null:
		quit(1)
		return

	# --- Corps articulé ---
	check(player._arm_l != null and player._arm_r != null, "bras sur pivots")
	check(player._leg_l != null and player._leg_r != null, "jambes sur pivots")
	check(player.weapon != null and player.weapon.get_parent() == player._arm_r, "arme accrochée au bras droit")

	# --- Caméra sur SpringArm3D ---
	check(player.camera != null and player.camera.current, "caméra active")
	var arm = player.camera.get_parent()
	check(arm is SpringArm3D, "caméra montée sur SpringArm3D")

	# --- Lanterne (touche G) ---
	check(InputMap.has_action("lantern"), "action 'lantern' enregistrée")
	check(player._lantern != null and not player._lantern.visible, "lanterne éteinte au départ")
	player.toggle_lantern()
	check(player._lantern.visible, "toggle_lantern allume la lanterne")
	player.toggle_lantern()

	# --- Endurance + roulade ---
	check(InputMap.has_action("roll"), "action 'roll' (Ctrl) enregistrée")
	check(world._stamina_bar != null, "jauge d'endurance au HUD")
	check(absf(player.stamina - Player.STAMINA_MAX) < 0.01, "endurance pleine au départ")
	var hp_before_roll: int = player.health
	player._start_roll(Vector3(0, 0, -1))
	check(player._roll_timer > 0.0, "la roulade démarre")
	check(player.stamina <= Player.STAMINA_MAX - Player.ROLL_COST + 0.01, "la roulade consomme de l'endurance")
	player.take_damage(15)
	check(player.health == hp_before_roll, "invincible pendant la roulade (esquive)")
	for i in 40:
		await physics_frame
	check(player._roll_timer <= 0.0, "la roulade se termine")
	player.take_damage(15)
	check(player.health == hp_before_roll - 15, "les dégâts passent à nouveau après la roulade")
	player.heal(15)

	# --- Cycle jour/nuit ---
	var dns := world.get_children().filter(func(c): return c is DayNight)
	check(dns.size() == 1, "un nœud DayNight présent")
	if dns.size() == 1:
		var dn: DayNight = dns[0]
		var sun: DirectionalLight3D = world.get_node("DirectionalLight3D")
		dn.time_of_day = 0.5 # midi
		dn._apply()
		check(absf(sun.light_energy - 1.25) < 0.01, "midi : plein soleil (%.2f)" % sun.light_energy)
		dn.time_of_day = 0.0 # minuit
		dn._apply()
		check(absf(sun.light_energy - 0.30) < 0.01, "minuit : clair de lune (%.2f)" % sun.light_energy)
		var env: Environment = world.get_node("WorldEnvironment").environment
		check(env.sky != null and env.sky.sky_material is ShaderMaterial, "ciel remplacé par le shader custom")

	# --- Chunks + eau locale ---
	var expected: int = (2 * world.render_distance + 1) ** 2
	check(world.loaded_chunks.size() == expected, "chunks chargés : %d / %d attendus" % [world.loaded_chunks.size(), expected])
	var chunks_with_water := 0
	var mismatches := 0
	for key in world.loaded_chunks:
		var chunk = world.loaded_chunks[key]
		var has_submerged := false
		for lx in Chunk.SIZE:
			for lz in Chunk.SIZE:
				if float(gen.get_height(key.x * Chunk.SIZE + lx, key.y * Chunk.SIZE + lz)) + 0.5 < TerrainGen.WATER_Y:
					has_submerged = true
					break
			if has_submerged:
				break
		var has_water_mesh := false
		for child in chunk.get_children():
			if child is MeshInstance3D and child.material_override != null:
				has_water_mesh = true
		if has_submerged:
			chunks_with_water += 1
		if has_submerged != has_water_mesh:
			mismatches += 1
	check(mismatches == 0, "eau présente exactement sur les chunks immergés (%d avec eau)" % chunks_with_water)

	# --- Nage ---
	# TerrainGen est en unités cube : conversions monde via Chunk.CUBE.
	var water_world := TerrainGen.WATER_Y * Chunk.CUBE
	var deepest_world := deepest * Chunk.CUBE
	check(player.gen != null, "le joueur connaît le générateur (détection de l'eau)")
	check(Player.SWIM_EXIT_DEPTH < Player.SWIM_ENTER_DEPTH, "hystérésis : sortie moins profonde que l'entrée")
	check(deepest_world >= 1.3, "un lac assez profond existe pour nager (%.2f m en %s)" % [deepest_world, deep_pos])
	if deepest_world >= 1.3 and player.gen != null:
		var drop := minf(deepest_world - 0.1, 1.8) # sous la surface mais au-dessus du fond
		player.global_position = Vector3(deep_pos.x * Chunk.CUBE, water_world - drop, deep_pos.y * Chunk.CUBE)
		player.velocity = Vector3.ZERO
		for i in 30:
			await physics_frame
		check(player.swimming, "le joueur nage en eau profonde")
		for i in 240:
			await physics_frame
		var eq := water_world - Player.FLOAT_DEPTH
		check(absf(player.global_position.y - eq) < 0.4,
			"la flottabilité stabilise à la surface (y=%.2f, attendu ~%.2f)" % [player.global_position.y, eq])
		# Hystérésis : en flottant à l'équilibre, l'état de nage ne bascule plus.
		var toggles := 0
		var last: bool = player.swimming
		for i in 120:
			await physics_frame
			if player.swimming != last:
				toggles += 1
				last = player.swimming
		check(toggles == 0, "état de nage stable à la surface (%d bascule(s))" % toggles)

		# --- Ambiance sous-marine : caméra forcée sous la surface ---
		var cam: Camera3D = player.camera
		var old_cam := cam.global_position
		cam.global_position = Vector3(deep_pos.x * Chunk.CUBE, water_world - 0.8, deep_pos.y * Chunk.CUBE)
		world._update_underwater()
		check(world._underwater, "caméra immergée détectée")
		check(world._underwater_rect.visible, "teinte sous-marine affichée")
		var env2: Environment = world.get_node("WorldEnvironment").environment
		world._day_night._apply()
		check(env2.fog_density > 0.05, "brouillard sous-marin dense (%.3f)" % env2.fog_density)
		cam.global_position = old_cam
		world._update_underwater()
		world._day_night._apply()
		check(not world._underwater and not world._underwater_rect.visible, "retour à la surface : effet coupé")
		check(env2.fog_density < 0.01, "brouillard normal restauré (%.4f)" % env2.fog_density)
		# On repose le joueur au spawn pour la suite du test.
		world._on_player_died()
		await physics_frame

	# --- Ennemis : archétypes, corps, agilité ---
	var slime := Enemy.new()
	slime.type_id = "slime"
	world.add_child(slime)
	slime.global_position = player.global_position + Vector3(2, 1, 0)
	await process_frame
	check(slime.model != null and slime._hops, "slime : modèle construit, se déplace par bonds")
	check(slime._gen != null, "l'ennemi connaît le générateur (flottaison)")
	var hp_before: int = slime.health
	slime.take_damage(10, player.global_position)
	check(slime.health == hp_before - 10, "l'ennemi encaisse des dégâts")

	var scout := Enemy.new()
	scout.type_id = "scout"
	world.add_child(scout)
	scout.global_position = player.global_position + Vector3(-2, 1, 0)
	await process_frame
	check(scout._agile and scout._leg_l != null and scout._arm_r != null, "éclaireur : agile, corps articulé")
	check(scout._try_roll(Vector3(1, 0, 0)), "l'éclaireur peut rouler (endurance)")
	var scout_hp: int = scout.health
	scout.take_damage(10, player.global_position)
	check(scout.health == scout_hp, "roulade d'ennemi = esquive (invincible)")
	check(scout._stamina <= Enemy.STAMINA_MAX - Enemy.ROLL_COST + 0.01, "la roulade de l'ennemi consomme son endurance")
	for i in 40:
		await physics_frame
	scout.take_damage(10, player.global_position)
	check(scout.health == scout_hp - 10, "l'éclaireur reprend des dégâts après sa roulade")

	print("")
	if fails == 0:
		print("=== SMOKE TEST : tout est OK ===")
	else:
		printerr("=== SMOKE TEST : %d échec(s) ===" % fails)
	quit(1 if fails > 0 else 0)
