extends SceneTree

# Test de fumée headless : godot --headless -s res://tests/smoke.gd
# Charge le monde (menu principal), teste la persistance des profils, lance une
# session avec un seed fixe puis vérifie joueur (corps articulé, endurance,
# roulade), caméra, lanterne, cycle jour/nuit, génération (océan/coraux/plages,
# arbres/déco), nage (hystérésis comprise), effet sous-marin, auto-montée
# d'une marche d'un cube et ennemis.

var fails := 0

func check(cond: bool, label: String) -> void:
	if cond:
		print("OK   - ", label)
	else:
		fails += 1
		printerr("FAIL - ", label)

# Pose le joueur sur la colonne (col.x - 1, col.y), oriente la caméra pour que
# « avancer » aille vers +X et MAINTIENT la touche : l'auto-montée étant
# déclenchée par les collisions réelles, on vérifie le résultat physique.
# Renvoie true si le joueur finit DEBOUT sur la colonne col.x + 1 (marche gravie).
func drive_forward(player, col: Vector2i, gen: TerrainGen) -> bool:
	var h := gen.get_height(col.x - 1, col.y)
	player.global_position = Vector3((col.x - 1) * Chunk.CUBE,
		(float(h) + 0.5) * Chunk.CUBE + 0.02, col.y * Chunk.CUBE)
	player.velocity = Vector3.ZERO
	player.cam_pivot.rotation.y = -PI / 2 # « Go forward » = +X
	var target_top := (float(gen.get_height(col.x + 1, col.y)) + 0.5) * Chunk.CUBE
	var climbed := false
	Input.action_press("Go forward")
	for i in 50:
		await physics_frame
		if roundi(player.global_position.x / Chunk.CUBE) >= col.x + 1 \
				and absf(player.global_position.y - target_top) < 0.35:
			climbed = true
			break
	Input.action_release("Go forward")
	return climbed

# Même conduite, mais on surveille si le joueur s'est fait REHAUSSER (il ne
# doit pas : mur de 2+ ou fente trop étroite). Renvoie true s'il est monté.
func drive_expect_blocked(player, col: Vector2i, gen: TerrainGen) -> bool:
	var h := gen.get_height(col.x - 1, col.y)
	var start_y := (float(h) + 0.5) * Chunk.CUBE + 0.02
	player.global_position = Vector3((col.x - 1) * Chunk.CUBE, start_y, col.y * Chunk.CUBE)
	player.velocity = Vector3.ZERO
	player.cam_pivot.rotation.y = -PI / 2
	var rose := false
	Input.action_press("Go forward")
	for i in 50:
		await physics_frame
		if player.global_position.y > start_y + 0.35:
			rose = true
			break
	Input.action_release("Go forward")
	return rose

func _initialize() -> void:
	_run()

func _run() -> void:
	var ws := load("res://Scènes/Monde/world.tscn") as PackedScene
	check(ws != null, "world.tscn se charge")

	# --- Chaque brique du jeu a sa scène, avec ses presets dans le .tscn ---
	for cid in ["warrior", "ranger", "mage", "rogue"]:
		var cs := load("res://Scènes/Acteurs/%s.tscn" % cid) as PackedScene
		var ci = cs.instantiate() if cs != null else null
		check(ci != null and ci.class_id == cid, "scène de classe %s (class_id préréglé)" % cid)
		if ci != null:
			ci.free()
	for tid in ["slime", "scout", "brute", "archer"]:
		var es := load("res://Scènes/Acteurs/%s.tscn" % tid) as PackedScene
		var ei = es.instantiate() if es != null else null
		check(ei != null and ei.type_id == tid, "scène d'ennemi %s (type_id préréglé)" % tid)
		if ei != null:
			ei.free()
	for sp in ["Monde/terrain_gen", "Monde/chunk", "Monde/day_night", "Monde/tree",
			"UI/ui", "UI/main_menu", "UI/options_menu", "UI/inventory_ui",
			"Objets/pickup", "Objets/projectile", "Objets/items"]:
		check(load("res://Scènes/%s.tscn" % sp) != null, "la scène %s.tscn se charge" % sp)

	# --- Les scènes d'acteurs contiennent le MODÈLE et les ANIMATIONS ---
	var wi = (load("res://Scènes/Acteurs/warrior.tscn") as PackedScene).instantiate()
	check(wi.get_node_or_null("Model/RollCenter/ArmR/Weapon") != null, "le guerrier de la scène porte son arme")
	var wanim: AnimationPlayer = wi.get_node("Anim")
	for an in ["walk", "idle", "swim_move", "swim_idle", "roll"]:
		check(wanim.has_animation(an), "clip '%s' du joueur dans la scène" % an)
	check((wi.get_node("GearAnim") as AnimationPlayer).has_animation("attack"), "clip 'attack' de l'arme dans la scène")
	# La nage : les bras pagaient en aller-retour (amplitude bornée), plus de
	# moulinet à tour complet (l'ancien bug des « bras d'hélice »).
	var swim_anim: Animation = wanim.get_animation("swim_move")
	var arm_max := 0.0
	for ti in swim_anim.get_track_count():
		if String(swim_anim.track_get_path(ti)).contains("ArmL"):
			for k in swim_anim.track_get_key_count(ti):
				arm_max = maxf(arm_max, absf(swim_anim.track_get_key_value(ti, k)))
	check(arm_max > 0.5 and arm_max < 1.5, "nage : bras en aller-retour (amplitude %.2f, pas de tour complet)" % arm_max)
	wi.free()
	var ai = (load("res://Scènes/Acteurs/archer.tscn") as PackedScene).instantiate()
	check(ai.get_node_or_null("Model/RollCenter/ArmL/Bow") != null, "l'archer de la scène affiche son arc")
	check((ai.get_node("Anim") as AnimationPlayer).has_animation("walk"), "clip 'walk' de l'ennemi dans la scène")
	check((ai.get_node("GearAnim") as AnimationPlayer).has_animation("draw"), "clip 'draw' (recul d'arc) dans la scène")
	ai.free()
	var si = (load("res://Scènes/Acteurs/slime.tscn") as PackedScene).instantiate()
	check(si.get_node_or_null("Model/Body") != null, "le slime de la scène affiche son corps")
	si.free()

	var world = ws.instantiate()
	root.add_child(world)
	await process_frame
	await process_frame

	# --- Menu principal + persistance des profils ---
	check(world._menu != null, "le menu principal est affiché au lancement")
	check(world.gen == null, "pas de génération avant le choix d'un monde")
	# Les widgets viennent des scènes UI (plus construits en code).
	check(world._menu.find_child("PlayBtn") != null, "bouton Jouer dans la scène du menu")
	check(world._menu.find_child("SeedEdit") != null, "champ Graine dans la scène du menu")
	check(world._options.find_child("VolumeSlider") != null, "curseur Volume dans la scène des options")
	check(world._options.find_child("ResBtn") != null, "liste des résolutions dans la scène des options")
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
	# Déterminisme : plus AUCUN spawn d'ennemi par le monde pendant les tests
	# (un archer qui touche le joueur fausse les comptes de PV) — les tests
	# d'ennemis instancient les leurs à la main. Le tick de spawn est AUSSI
	# neutralisé : il recycle les ennemis à plus de 50 m du joueur, et nos
	# ennemis de test téléportés en plein océan se faisaient libérer en pleine
	# vérification (crash « previously freed instance »).
	world.max_enemies = 0
	world.enemy_spawn_interval = 1e9
	world._enemy_timer = 1e9
	for e in world.get_tree().get_nodes_in_group("enemies"):
		e.queue_free()
	# Distance de rendu réduite pour le test : la valeur de jeu (30 chunks =
	# 3721 chunks chargés) prendrait de longues minutes en headless. Toutes les
	# vérifications (comptes de chunks, brume) sont relatives à cette valeur.
	world.set_render_distance(6)

	# --- Génération : cubes, océan, seuil de l'eau ---
	var gen: TerrainGen = world.gen
	check(gen != null, "générateur créé avec la graine du monde")
	check(absf(Chunk.CUBE - 0.6) < 0.001, "cube = 1/3 de la taille du joueur (0.6 m pour 1.8 m)")

	# Le spawn est choisi par le monde : toujours sur la terre ferme.
	var spawn_col := Vector2i(roundi(world._spawn_pos.x / Chunk.CUBE), roundi(world._spawn_pos.z / Chunk.CUBE))
	check(float(gen.get_height(spawn_col.x, spawn_col.y)) + 0.5 >= TerrainGen.WATER_Y + 1.0,
		"le point d'apparition est émergé (les océans sont grands)")

	# Cherche un point d'océan PROFOND en spirale (anneaux de 32 cubes).
	var deep_pos := Vector2i.ZERO
	var found_ocean := false
	for ring in 400:
		var d := ring * 32
		var pts: Array[Vector2i] = []
		if ring == 0:
			pts.append(Vector2i(0, 0))
		for i in range(-ring, ring + 1):
			if ring > 0:
				pts.append_array([Vector2i(i * 32, -d), Vector2i(i * 32, d),
					Vector2i(-d, i * 32), Vector2i(d, i * 32)])
		for p in pts:
			if gen.get_biome(p.x, p.y) == TerrainGen.Biome.OCEAN \
					and float(gen.get_height(p.x, p.y)) + 0.5 < TerrainGen.WATER_Y - 5.0:
				deep_pos = p
				found_ocean = true
				break
		if found_ocean:
			break
	check(found_ocean, "un océan profond existe à distance raisonnable (%s)" % deep_pos)

	# Transect du large vers le spawn : on doit croiser du fond marin, une
	# plage puis de la terre (plateau continental = côte progressive).
	var submerged := 0
	var beach := 0
	var emerged := 0
	var trees_underwater := 0
	var steps := maxi(absi(spawn_col.x - deep_pos.x), absi(spawn_col.y - deep_pos.y))
	for s in steps + 1:
		var t := float(s) / float(maxi(steps, 1))
		var x := roundi(lerpf(float(deep_pos.x), float(spawn_col.x), t))
		var z := roundi(lerpf(float(deep_pos.y), float(spawn_col.y), t))
		var top := float(gen.get_height(x, z)) + 0.5
		if top < TerrainGen.WATER_Y:
			submerged += 1
			if gen.has_tree(x, z):
				trees_underwater += 1
		elif top < TerrainGen.WATER_Y + 1.0: # bande de plage (1 cube)
			beach += 1
		else:
			emerged += 1
	check(submerged > 0 and beach > 0 and emerged > 0,
		"transect océan→spawn : fond marin (%d), plage (%d), terre (%d)" % [submerged, beach, emerged])
	check(trees_underwater == 0, "aucun arbre sous l'eau sur le transect")

	# Coraux (colonnes fines colorées) et roches aquatiques sur le fond marin.
	var corals := 0
	var rocks := 0
	for dx in range(-48, 49, 2):
		for dz in range(-48, 49, 2):
			var deco := gen.get_decoration(deep_pos.x + dx, deep_pos.y + dz)
			if deco.is_empty():
				continue
			if (deco["size"] as Vector3).x < 0.3:
				corals += 1
			else:
				rocks += 1
	check(corals > 0 and rocks > 0, "fond marin décoré : %d coraux, %d roches aquatiques" % [corals, rocks])

	# Hors océan : la seule eau est celle des fleuves (plus de lacs aléatoires).
	var stray_water := 0
	for dx in range(-160, 161, 4):
		for dz in range(-160, 161, 4):
			var x := spawn_col.x + dx
			var z := spawn_col.y + dz
			if gen.get_biome(x, z) == TerrainGen.Biome.OCEAN:
				continue
			if float(gen.get_height(x, z)) + 0.5 < TerrainGen.WATER_Y and not gen.is_river(x, z):
				stray_water += 1
	check(stray_water == 0, "l'eau terrestre vient uniquement des fleuves (pas de lacs, %d intrus)" % stray_water)

	# --- Sable uniquement PRÈS d'une vraie colonne d'eau ---
	# Un creux de terrain intérieur au niveau de la mer (le relief est clampé
	# juste au-dessus de WATER_Y) ne doit PLUS devenir une plage fantôme.
	var sand := Color(0.80, 0.73, 0.52)
	var low_dry := 0      # colonnes basses SANS eau à proximité...
	var low_dry_sand := 0 # ... coloriées en sable à tort
	var shore_sand := false
	for dx in range(-120, 121, 2):
		for dz in range(-120, 121, 2):
			var x := spawn_col.x + dx
			var z := spawn_col.y + dz
			var b := gen.get_biome(x, z)
			if b == TerrainGen.Biome.DESERT or b == TerrainGen.Biome.SNOW or b == TerrainGen.Biome.OCEAN:
				continue
			var h := gen.get_height(x, z)
			var top := float(h) + 0.5
			if top < TerrainGen.WATER_Y or top >= TerrainGen.WATER_Y + 1.0:
				continue # seule la bande basse est candidate au sable
			var colr := gen.get_color(x, z, h, h)
			if gen.near_water(x, z):
				shore_sand = shore_sand or colr.is_equal_approx(sand)
			else:
				low_dry += 1
				if colr.is_equal_approx(sand):
					low_dry_sand += 1
	check(low_dry_sand == 0,
		"aucune plage fantôme loin de l'eau (%d colonne(s) basse(s) sèche(s), 0 en sable)" % low_dry)
	check(shore_sand, "le sable borde toujours l'eau réelle")

	# --- Teinte de l'herbe : le vert dérive par patches (tint_noise) ---
	# Mesuré PAR biome : plaine et forêt ont des verts de base différents, on ne
	# veut compter que la dérive du bruit à l'intérieur d'un même biome.
	var tint_min := {}
	var tint_max := {}
	var tint_n := {}
	for dx in range(-200, 201, 4):
		for dz in range(-200, 201, 4):
			var x := spawn_col.x + dx
			var z := spawn_col.y + dz
			var b := gen.get_biome(x, z)
			if b != TerrainGen.Biome.PLAINS and b != TerrainGen.Biome.FOREST:
				continue
			var h := gen.get_height(x, z)
			if float(h) + 0.5 < TerrainGen.WATER_Y + 1.0:
				continue # bande basse : sable/immergé, pas d'herbe
			var gc := gen.get_color(x, z, h, h)
			if not tint_n.has(b):
				tint_min[b] = Vector2(gc.h, gc.v)
				tint_max[b] = Vector2(gc.h, gc.v)
				tint_n[b] = 0
			tint_min[b] = Vector2(minf(tint_min[b].x, gc.h), minf(tint_min[b].y, gc.v))
			tint_max[b] = Vector2(maxf(tint_max[b].x, gc.h), maxf(tint_max[b].y, gc.v))
			tint_n[b] += 1
	var tint_ok := false
	var tint_msg := "aucun biome herbeux échantillonné"
	for b in tint_n:
		if tint_n[b] < 40:
			continue
		var t_dh: float = tint_max[b].x - tint_min[b].x
		var t_dv: float = tint_max[b].y - tint_min[b].y
		tint_msg = "%d colonnes, Δteinte %.3f, Δluminosité %.3f" % [tint_n[b], t_dh, t_dv]
		if t_dh > 0.02 and t_dv > 0.05:
			tint_ok = true
			break
	check(tint_ok, "le vert de l'herbe varie par patches (%s)" % tint_msg)

	# Une rivière terrestre existe : colonne creusée sous le niveau de l'eau,
	# hors océan (recherche en spirale, anneaux de 16 cubes).
	var river_pos := Vector2i.ZERO
	var found_river := false
	for ring in 300:
		var rd := ring * 16
		var rpts: Array[Vector2i] = []
		if ring == 0:
			rpts.append(Vector2i(0, 0))
		for i in range(-ring, ring + 1):
			if ring > 0:
				rpts.append_array([Vector2i(i * 16, -rd), Vector2i(i * 16, rd),
					Vector2i(-rd, i * 16), Vector2i(rd, i * 16)])
		for p in rpts:
			if gen.is_river(p.x, p.y) and gen.get_biome(p.x, p.y) != TerrainGen.Biome.OCEAN:
				river_pos = p
				found_river = true
				break
		if found_river:
			break
	check(found_river, "une rivière terrestre existe (trouvée en %s)" % river_pos)
	if found_river:
		check(float(gen.get_height(river_pos.x, river_pos.y)) + 0.5 < TerrainGen.WATER_Y,
			"le lit de la rivière est creusé sous le niveau de l'eau")
		# Calibre « fleuve » : la meilleure section immergée doit être large.
		var best_x := 0
		var run := 0
		for dx in range(-40, 41):
			if float(gen.get_height(river_pos.x + dx, river_pos.y)) + 0.5 < TerrainGen.WATER_Y:
				run += 1
				best_x = maxi(best_x, run)
			else:
				run = 0
		var best_z := 0
		run = 0
		for dz in range(-40, 41):
			if float(gen.get_height(river_pos.x, river_pos.y + dz)) + 0.5 < TerrainGen.WATER_Y:
				run += 1
				best_z = maxi(best_z, run)
			else:
				run = 0
		var width := maxi(best_x, best_z)
		check(width >= 14, "le fleuve est large (%d colonnes ≈ %.1f m d'eau)" % [width, width * Chunk.CUBE])
		# Lit du fleuve : décoré (plantes aquatiques, pierres) et PAS plat.
		var plants := 0
		var stones := 0
		var bed_min := 99999
		var bed_max := -99999
		for dx2 in range(-40, 41):
			for dz2 in range(-40, 41):
				var x2 := river_pos.x + dx2
				var z2 := river_pos.y + dz2
				if not gen.is_river(x2, z2):
					continue
				var hh := gen.get_height(x2, z2)
				bed_min = mini(bed_min, hh)
				bed_max = maxi(bed_max, hh)
				var rdeco := gen.get_decoration(x2, z2)
				if rdeco.is_empty():
					continue
				if (rdeco["size"] as Vector3).x < 0.2:
					plants += 1
				else:
					stones += 1
		check(plants > 0 and stones > 0, "lit du fleuve décoré : %d plantes, %d pierres" % [plants, stones])
		check(bed_max - bed_min >= 2, "le fond du fleuve a du relief (%d..%d cubes)" % [bed_min, bed_max])
		# Vallée fluviale : en traversant le fleuve, aucune paroi abrupte —
		# l'ancien canyon dans la montagne tombait de 7+ cubes d'un coup.
		var worst_step := 0
		for dx3 in range(-60, 60):
			worst_step = maxi(worst_step, absi(gen.get_height(river_pos.x + dx3 + 1, river_pos.y)
				- gen.get_height(river_pos.x + dx3, river_pos.y)))
		check(worst_step <= 5, "vallée fluviale douce (marche max %d cube(s) en traversée)" % worst_step)

	# Plus d'arbres en montagne : on cherche une zone MOUNTAINS et on vérifie.
	var mtn := Vector2i.ZERO
	var found_mtn := false
	for ring in 400:
		var md := ring * 32
		var mpts: Array[Vector2i] = []
		if ring == 0:
			mpts.append(Vector2i(0, 0))
		for i in range(-ring, ring + 1):
			if ring > 0:
				mpts.append_array([Vector2i(i * 32, -md), Vector2i(i * 32, md),
					Vector2i(-md, i * 32), Vector2i(md, i * 32)])
		for p in mpts:
			if gen.get_biome(p.x, p.y) == TerrainGen.Biome.MOUNTAINS:
				mtn = p
				found_mtn = true
				break
		if found_mtn:
			break
	check(found_mtn, "un biome montagne existe (trouvé en %s)" % mtn)
	if found_mtn:
		var mtn_trees := 0
		for dx in range(-40, 41):
			for dz in range(-40, 41):
				var x := mtn.x + dx
				var z := mtn.y + dz
				if gen.get_biome(x, z) == TerrainGen.Biome.MOUNTAINS and gen.has_tree(x, z):
					mtn_trees += 1
		check(mtn_trees == 0, "aucun arbre en montagne (%d trouvé(s))" % mtn_trees)

	# Espacement des arbres (grille jitterée) : jamais deux arbres collés.
	var forest := Vector2i.ZERO
	var found_forest := false
	for ring in 400:
		var fd := ring * 32
		var fpts: Array[Vector2i] = []
		if ring == 0:
			fpts.append(Vector2i(0, 0))
		for i in range(-ring, ring + 1):
			if ring > 0:
				fpts.append_array([Vector2i(i * 32, -fd), Vector2i(i * 32, fd),
					Vector2i(-fd, i * 32), Vector2i(fd, i * 32)])
		for p in fpts:
			if gen.get_biome(p.x, p.y) == TerrainGen.Biome.FOREST:
				forest = p
				found_forest = true
				break
		if found_forest:
			break
	check(found_forest, "un biome forêt existe (trouvé en %s)" % forest)
	if found_forest:
		var trees: Array[Vector2i] = []
		for dx in range(-60, 61):
			for dz in range(-60, 61):
				if gen.has_tree(forest.x + dx, forest.y + dz):
					trees.append(Vector2i(forest.x + dx, forest.y + dz))
		check(trees.size() >= 2, "la forêt contient des arbres (%d sur 72×72 m)" % trees.size())
		var min_d2 := 99999999
		for i in trees.size():
			for j in range(i + 1, trees.size()):
				min_d2 = mini(min_d2, (trees[i] - trees[j]).length_squared())
		if trees.size() >= 2:
			check(min_d2 >= 25, "arbres jamais collés (distance min %.1f m)" % (sqrt(float(min_d2)) * Chunk.CUBE))

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
	check(InputMap.has_action("Lantern"), "action 'Lantern' enregistrée")
	check(player._lantern != null and not player._lantern.visible, "lanterne éteinte au départ")
	player.toggle_lantern()
	check(player._lantern.visible, "toggle_lantern allume la lanterne")
	player.toggle_lantern()

	# --- Endurance + roulade ---
	check(InputMap.has_action("Roll"), "action 'Roll' (clic molette) enregistrée")
	check(world._stamina_bar != null, "jauge d'endurance au HUD")
	check(absf(player.stamina - Player.STAMINA_MAX) < 0.01, "endurance pleine au départ")
	var hp_before_roll: int = player.health
	player._start_roll(Vector3(0, 0, -1))
	check(player._roll_timer > 0.0, "la roulade démarre")
	check(player.stamina <= Player.STAMINA_MAX - Player.ROLL_COST + 0.01, "la roulade consomme de l'endurance")
	player.take_damage(15)
	check(player.health == hp_before_roll, "invincible pendant la roulade (esquive)")
	# Pendant la roulade, ni attaque ni spécial ne partent (les timers restent à 0).
	player._try_attack()
	check(player._attack_timer <= 0.0, "pas d'attaque pendant la roulade")
	player._try_special()
	check(player.special_timer <= 0.0, "pas de spécial pendant la roulade")
	for i in 40:
		await physics_frame
	check(player._roll_timer <= 0.0, "la roulade se termine")
	player.take_damage(15)
	check(player.health == hp_before_roll - 15, "les dégâts passent à nouveau après la roulade")
	player.heal(15)

	# --- Roll (clic molette) et Crouch (Ctrl) : touches séparées ---
	check(InputMap.has_action("Crouch"), "action 'Crouch' (Ctrl) enregistrée")
	world._on_player_died() # retour au spawn : la roulade a pu nous déplacer vers l'eau
	await physics_frame
	for i in 90: # le spawn est 3 m au-dessus du sol : laisser le temps d'atterrir
		if player.is_on_floor():
			break
		await physics_frame
	check(player.is_on_floor(), "le joueur est au sol avant le test Roll/Crouch")
	player.stamina = Player.STAMINA_MAX
	Input.action_press("Roll")
	for i in 2:
		await physics_frame
	Input.action_release("Roll")
	check(player._roll_timer > 0.0, "la roulade part dès l'appui (clic molette)")
	for i in 40:
		await physics_frame
	world._on_player_died() # la roulade a pu nous emmener n'importe où : re-spawn
	await physics_frame
	for i in 90:
		if player.is_on_floor():
			break
		await physics_frame
	Input.action_press("Crouch")
	for i in 5:
		await physics_frame
	check(player.crouching, "Ctrl maintenu : le joueur s'accroupit")
	check(player._roll_timer <= 0.0, "l'accroupissement ne déclenche pas de roulade")
	Input.action_release("Crouch")
	for i in 2:
		await physics_frame
	check(not player.crouching, "relâcher Ctrl redresse le joueur")

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
	check(world._water_mat.render_priority == 1,
		"l'eau se dessine après les autres transparents (coque du slime immergé)")
	# L'eau est un BLOC (sans collision) : chaque face porte des UV 0..1 locales
	# au bloc — plus d'UV en coordonnées monde.
	var water_uv_bad := 0
	var water_uv_found := false
	for key in world.loaded_chunks:
		for child in world.loaded_chunks[key].get_children():
			if child is MeshInstance3D and child.material_override != null:
				var wuv: PackedVector2Array = (child.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_TEX_UV]
				water_uv_found = wuv.size() > 0
				for uv in wuv:
					if uv.x < -0.001 or uv.x > 1.001 or uv.y < -0.001 or uv.y > 1.001:
						water_uv_bad += 1
				break
		if water_uv_found:
			break
	check(water_uv_found and water_uv_bad == 0,
		"blocs d'eau : UV 0..1 par bloc (%d hors bornes)" % water_uv_bad)

	# --- Optimisations d'affichage (décos, ombres, brouillard, LOD) ---
	var deco_chunk: Chunk = null
	for key in world.loaded_chunks:
		if world.loaded_chunks[key].deco_mmi != null:
			deco_chunk = world.loaded_chunks[key]
			break
	check(deco_chunk != null and deco_chunk.deco_mmi.visibility_range_end > 0.0,
		"décos limitées à une distance RELATIVE (%.0f m)"
		% (deco_chunk.deco_mmi.visibility_range_end if deco_chunk != null else -1.0))
	world.set_decorations(false)
	check(deco_chunk != null and not deco_chunk.deco_mmi.visible, "option : décorations au sol masquées")
	world.set_decorations(true)
	check(deco_chunk != null and deco_chunk.deco_mmi.visible, "option : décorations au sol réaffichées")
	var sun_l: DirectionalLight3D = world.get_node("DirectionalLight3D")
	var shadow_chunk: Chunk = null
	for key in world.loaded_chunks:
		if world.loaded_chunks[key].tree_shadow_mmi != null:
			shadow_chunk = world.loaded_chunks[key]
			break
	world.set_shadows_enabled(false)
	check(not sun_l.shadow_enabled, "option : ombres du soleil coupées")
	check(shadow_chunk != null and shadow_chunk.tree_shadow_mmi.visible,
		"ombres rondes sous les arbres quand les vraies ombres sont coupées")
	world.set_shadows_enabled(true)
	check(sun_l.shadow_enabled and (shadow_chunk == null or not shadow_chunk.tree_shadow_mmi.visible),
		"ombres réelles restaurées, ombres rondes d'arbres masquées")
	check(world._options.find_child("ShadowsOnCheck", true, false) != null, "case Ombres dans les options")
	check(world._options.find_child("DecoCheck", true, false) != null, "case Décorations dans les options")
	world._day_night._apply()
	var envf: Environment = world.get_node("WorldEnvironment").environment
	check(envf.fog_mode == Environment.FOG_MODE_DEPTH \
			and absf(envf.fog_depth_end - world._view_dist_m() * 1.02) < 1.0,
		"mur de brume calé sur la limite des chunks (opaque à %.0f m)" % envf.fog_depth_end)
	check(player._blob != null, "ombre ronde sous le joueur")
	check(player.camera.v_offset > 0.0, "caméra décalée : le crosshair flotte au-dessus du joueur")
	var zl0: float = player._spring.spring_length
	var zin := InputEventAction.new()
	zin.action = "Zoom in"
	zin.pressed = true
	player._unhandled_input(zin)
	check(player._spring.spring_length < zl0, "zoom molette : la caméra se rapproche")
	var zout := InputEventAction.new()
	zout.action = "Zoom out"
	zout.pressed = true
	player._unhandled_input(zout)
	check(absf(player._spring.spring_length - zl0) < 0.01, "dézoom molette : la caméra s'éloigne")
	var lod_tree = (load("res://Scènes/Monde/tree.tscn") as PackedScene).instantiate()
	var lod_blocks: MeshInstance3D = lod_tree.get_node("Blocks")
	var lod_mesh: MeshInstance3D = lod_tree.get_node_or_null("BlocksLOD")
	check(lod_mesh != null and lod_blocks.visibility_range_end > 0.0 \
			and absf(lod_mesh.visibility_range_begin - lod_blocks.visibility_range_end) < 0.01,
		"arbre : LOD à distance fixe (bascule à %.0f m)" % lod_blocks.visibility_range_end)
	if lod_mesh != null:
		var full_v: int = (lod_blocks.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
		var lod_v: int = (lod_mesh.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
		check(lod_v * 3 < full_v, "LOD nettement plus léger (%d sommets vs %d)" % [lod_v, full_v])
	lod_tree.free()

	# --- Nage (dans l'océan trouvé plus haut) ---
	# TerrainGen est en unités cube : conversions monde via Chunk.CUBE.
	var water_world := TerrainGen.WATER_Y * Chunk.CUBE
	var deep_top := (float(gen.get_height(deep_pos.x, deep_pos.y)) + 0.5) * Chunk.CUBE
	var deepest_world := water_world - deep_top
	check(player.gen != null, "le joueur connaît le générateur (détection de l'eau)")
	check(Player.SWIM_EXIT_DEPTH < Player.SWIM_ENTER_DEPTH, "hystérésis : sortie moins profonde que l'entrée")
	check(deepest_world >= 1.3, "l'océan est assez profond pour nager (%.2f m en %s)" % [deepest_world, deep_pos])
	if deepest_world >= 1.3 and player.gen != null:
		var drop := minf(deepest_world - 0.1, 1.8) # sous la surface mais au-dessus du fond
		player.global_position = Vector3(deep_pos.x * Chunk.CUBE, water_world - drop, deep_pos.y * Chunk.CUBE)
		player.velocity = Vector3.ZERO
		for i in 30:
			await physics_frame
		check(player.swimming, "le joueur nage en eau profonde")
		# La bascule à l'horizontale tourne autour du CENTRE DE MASSE : c'est le
		# pivot RollCenter qui s'incline, plus l'origine du modèle (les pieds).
		check(wrapf(player._roll_center.rotation.x, -PI, PI) < -0.15,
			"bascule de nage portée par le pivot central (RollCenter %.2f)" % player._roll_center.rotation.x)
		check(absf(player.model.rotation.x) < 0.01, "le modèle ne bascule plus autour des pieds")
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

		# Ctrl MAINTENU en nage : on plonge vers le fond (l'inverse d'Espace).
		var y_before_dive: float = player.global_position.y
		Input.action_press("Crouch")
		for i in 30:
			await physics_frame
		Input.action_release("Crouch")
		check(player.global_position.y < y_before_dive - 0.4,
			"Ctrl maintenu en nage : le joueur descend (%.2f m)" % (y_before_dive - player.global_position.y))
		for i in 60:
			await physics_frame # la flottabilité le ramène avant la suite

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

	# --- Auto-montée : marche d'un cube gravie sans Espace ---
	var NONE := Vector2i(2147483647, 2147483647)
	var step_col := NONE # marche d'un cube « propre » (voisins gravissables, approche plate)
	var wall_col := NONE # mur LARGE de 2+ cubes (les 3 colonnes de front)
	var slot_col := NONE # marche d'un cube COINCÉE entre deux murs (fente étroite)
	# ±140 cubes : il faut atteindre les reliefs (montagnes) pour trouver un mur
	# large — tout reste dans la zone de chunks chargés (render_distance 12 = ±192).
	for dx in range(-140, 140):
		for dz in range(-140, 140):
			var x := spawn_col.x + dx
			var z := spawn_col.y + dz
			var h0 := gen.get_height(x, z)
			if float(h0) + 0.5 < TerrainGen.WATER_Y + 1.0:
				continue # on teste au sec
			if gen.get_height(x - 1, z) != h0:
				continue # approche plate : le joueur part de la colonne x-1
			var dh := gen.get_height(x + 1, z) - h0
			var dhl := gen.get_height(x + 1, z - 1) - h0
			var dhr := gen.get_height(x + 1, z + 1) - h0
			# La capsule (0.8 m) est plus large qu'un cube : les colonnes voisines
			# de front comptent aussi (test_move les voit dans _auto_step).
			if dh == 1 and dhl <= 1 and dhr <= 1 and step_col == NONE:
				step_col = Vector2i(x, z)
			elif dh == 1 and dhl >= 2 and dhr >= 2 and slot_col == NONE:
				slot_col = Vector2i(x, z)
			elif dh >= 2 and dhl >= 2 and dhr >= 2 and wall_col == NONE:
				wall_col = Vector2i(x, z)
		if step_col != NONE and wall_col != NONE and slot_col != NONE:
			break
	check(step_col != NONE, "une marche d'un cube existe près du spawn")
	# L'auto-montée exige d'être au sol : on laisse le joueur atterrir au spawn.
	for i in 180:
		await physics_frame
		if player.is_on_floor():
			break
	check(player.is_on_floor(), "le joueur est au sol avant le test d'auto-montée")
	if step_col != NONE:
		var climbed: bool = await drive_forward(player, step_col, gen)
		check(climbed, "auto-montée par collision : le joueur finit debout sur la marche")
	if wall_col != NONE:
		var rose_wall: bool = await drive_expect_blocked(player, wall_col, gen)
		check(not rose_wall, "pas d'auto-montée contre un mur de 2+ cubes")
	if slot_col != NONE:
		var rose_slot: bool = await drive_expect_blocked(player, slot_col, gen)
		check(not rose_slot, "pas d'auto-montée vers une fente naturelle d'un cube")
	# Fente synthétique GARANTIE (la config naturelle est rare sur du bruit
	# lisse) : marche d'un cube coincée entre deux murs de 2, posée au sol.
	var flat_col := NONE
	for dx in range(-60, 60):
		for dz in range(-60, 60):
			var x := spawn_col.x + dx
			var z := spawn_col.y + dz
			var h0 := gen.get_height(x, z)
			if float(h0) + 0.5 < TerrainGen.WATER_Y + 1.0:
				continue
			var flat := true
			for ax in range(-1, 3):
				for az in range(-2, 3):
					if gen.get_height(x + ax, z + az) != h0 or gen.has_tree(x + ax, z + az):
						flat = false
			if flat:
				flat_col = Vector2i(x, z)
				break
		if flat_col != NONE:
			break
	check(flat_col != NONE, "zone plate trouvée pour la fente synthétique")
	if flat_col != NONE:
		var flat_top := (float(gen.get_height(flat_col.x, flat_col.y)) + 0.5) * Chunk.CUBE
		var slot_body := StaticBody3D.new()
		world.add_child(slot_body)
		for off: int in [-1, 0, 1]:
			var scs := CollisionShape3D.new()
			var sbx := BoxShape3D.new()
			var hgt := Chunk.CUBE if off == 0 else Chunk.CUBE * 2.0
			sbx.size = Vector3(Chunk.CUBE, hgt, Chunk.CUBE)
			scs.shape = sbx
			scs.position = Vector3((flat_col.x + 1) * Chunk.CUBE, flat_top + hgt * 0.5,
				(flat_col.y + off) * Chunk.CUBE)
			slot_body.add_child(scs)
		await physics_frame
		var rose_synth: bool = await drive_expect_blocked(player, flat_col, gen)
		check(not rose_synth, "pas d'auto-montée vers une fente d'un cube (le corps n'y passe pas)")
		slot_body.queue_free()

	# --- Roulade dans l'eau : seulement si on a pied ---
	# En plein océan, le joueur flotte (pas de contact au sol) : la roulade est
	# refusée. (Avec pied — eau peu profonde — elle reste permise : is_on_floor.)
	player.global_position = Vector3(deep_pos.x * Chunk.CUBE,
		TerrainGen.WATER_Y * Chunk.CUBE - 1.3, deep_pos.y * Chunk.CUBE)
	player.velocity = Vector3.ZERO
	for i in 30:
		await physics_frame
		if player.swimming:
			break
	check(player.swimming, "le joueur nage en plein océan")
	check(not player.is_on_floor(), "en flottaison, aucun contact au sol")
	player.stamina = Player.STAMINA_MAX
	Input.action_press("Roll")
	for i in 3:
		await physics_frame
	Input.action_release("Roll")
	check(player._roll_timer <= 0.0, "pas de roulade du joueur dans l'eau sans avoir pied")
	world._on_player_died()
	await physics_frame

	# --- Tir dirigé vers le réticule ---
	# Le projectile part de la poitrine VERS le point marqué par le crosshair
	# (rayon caméra au centre de l'écran) — avant, il partait parallèle à l'axe
	# caméra et ne croisait le réticule qu'à l'infini (parallaxe).
	for i in 180:
		await physics_frame
		if player.is_on_floor():
			break
	check(player.is_on_floor(), "le joueur est au sol avant le test de tir")
	player.cam_pivot.rotation.y = 0.0
	player.cam_pivot.rotation.x = -0.6 # caméra au-dessus, réticule vers le sol devant
	await physics_frame
	var vp_center: Vector2 = player.get_viewport().get_visible_rect().size * 0.5
	var aim_from: Vector3 = player.camera.project_ray_origin(vp_center)
	var aim_to: Vector3 = aim_from + player.camera.project_ray_normal(vp_center) * Player.AIM_RAY_LENGTH
	var aim_q := PhysicsRayQueryParameters3D.create(aim_from, aim_to)
	aim_q.exclude = [player.get_rid()]
	var aim_hit: Dictionary = player.get_world_3d().direct_space_state.intersect_ray(aim_q)
	check(not aim_hit.is_empty(), "le rayon du réticule touche le décor (pitch vers le sol)")
	if not aim_hit.is_empty():
		var old_projs := []
		for chld in world.get_children():
			if chld is Projectile:
				old_projs.append(chld)
		player._shoot(1.0, 0.0)
		var proj: Projectile = null
		for chld in world.get_children():
			if chld is Projectile and not (chld in old_projs):
				proj = chld
		check(proj != null, "projectile du joueur instancié")
		if proj != null:
			var want: Vector3 = (aim_hit["position"] - proj.global_position).normalized()
			var aim_err := rad_to_deg(proj.velocity.normalized().angle_to(want))
			check(aim_err < 2.0, "projectile dirigé vers le point du réticule (écart %.2f°)" % aim_err)
			proj.queue_free()
	player.cam_pivot.rotation.x = 0.0

	# --- Ennemis : archétypes, corps, agilité ---
	var slime := (load("res://Scènes/Acteurs/slime.tscn") as PackedScene).instantiate() as Enemy
	world.add_child(slime)
	slime.global_position = player.global_position + Vector3(2, 1, 0)
	await process_frame
	check(slime.model != null and slime._hops, "slime : modèle construit, se déplace par bonds")
	check(slime._gen != null, "l'ennemi connaît le générateur (flottaison)")
	var hp_before: int = slime.health
	slime.take_damage(10, player.global_position)
	check(slime.health == hp_before - 10, "l'ennemi encaisse des dégâts")

	var scout := (load("res://Scènes/Acteurs/scout.tscn") as PackedScene).instantiate() as Enemy
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

	# Même règle que le joueur : dans l'eau, un ennemi ne roule que s'il a pied.
	scout._stamina = Enemy.STAMINA_MAX
	scout.global_position = Vector3(deep_pos.x * Chunk.CUBE,
		TerrainGen.WATER_Y * Chunk.CUBE - 1.3, deep_pos.y * Chunk.CUBE)
	scout.velocity = Vector3.ZERO
	for i in 10:
		await physics_frame
	check(not scout.is_on_floor(), "éclaireur en flottaison, aucun contact au sol")
	check(not scout._try_roll(Vector3(1, 0, 0)), "pas de roulade d'ennemi dans l'eau sans avoir pied")

	# --- Sol analytique : pas de chute dans le vide hors des chunks chargés ---
	# (bug signalé : distance de rendu au minimum, un ennemi au-delà de la zone
	# chargée n'a plus AUCUN collider sous les pieds et tombait sans fin.)
	var far_col := NONE
	var far_start: int = (world.render_distance + 2) * Chunk.SIZE
	for d in range(far_start, far_start + 600, 4):
		var x: int = spawn_col.x + d
		if float(gen.get_height(x, spawn_col.y)) + 0.5 < TerrainGen.WATER_Y + 1.0:
			continue # au sec : la flottaison fausserait la mesure
		if world.has_chunk_at(Vector3(x * Chunk.CUBE, 0.0, spawn_col.y * Chunk.CUBE)):
			continue
		far_col = Vector2i(x, spawn_col.y)
		break
	check(far_col != NONE, "colonne émergée hors des chunks chargés trouvée")
	if far_col != NONE:
		var far_gy := (float(gen.get_height(far_col.x, far_col.y)) + 0.5) * Chunk.CUBE
		scout.global_position = Vector3(far_col.x * Chunk.CUBE, far_gy + 2.0, far_col.y * Chunk.CUBE)
		scout.velocity = Vector3.ZERO
		for i in 90:
			await physics_frame
		# L'ennemi a pu errer entre-temps : on compare au terrain SOUS lui.
		var cur_gy := (float(gen.get_height(
			roundi(scout.global_position.x / Chunk.CUBE),
			roundi(scout.global_position.z / Chunk.CUBE))) + 0.5) * Chunk.CUBE
		check(not world.has_chunk_at(scout.global_position),
			"l'ennemi est resté hors de la zone de chunks chargés")
		check(scout.global_position.y >= cur_gy - 0.05,
			"ennemi retenu par le sol analytique (y %.2f ≥ terrain %.2f, aucun collider)"
			% [scout.global_position.y, cur_gy])

	# --- Arbre voxel généré par script (tools/gen_tree_scene.gd) ---
	var tree = (load("res://Scènes/Monde/tree.tscn") as PackedScene).instantiate()
	check(int(tree.get_meta("cube_count", 0)) > 500,
		"arbre : nuage de cubes voxel (%d cubes)" % int(tree.get_meta("cube_count", 0)))
	var tmesh: ArrayMesh = (tree.get_node("Blocks") as MeshInstance3D).mesh
	var tarrays := tmesh.surface_get_arrays(0)
	var tverts: PackedVector3Array = tarrays[Mesh.ARRAY_VERTEX]
	var tcols: PackedColorArray = tarrays[Mesh.ARRAY_COLOR]
	check(tverts.size() > 3000 and tcols.size() == tverts.size(),
		"arbre : maillage voxel coloré (%d sommets)" % tverts.size())
	# Chaque sommet est un COIN de cube : sur la demi-grille de CUBE. Cela
	# vérifie à la fois la taille uniforme des cubes et l'alignement monde.
	var misaligned := 0
	for i in tverts.size():
		var p := tverts[i] * (2.0 / Chunk.CUBE)
		if absf(p.x - roundf(p.x)) > 0.02 or absf(p.y - roundf(p.y)) > 0.02 \
				or absf(p.z - roundf(p.z)) > 0.02:
			misaligned += 1
	check(misaligned == 0, "arbre : cubes alignés sur la grille du monde (%d sommets hors grille)" % misaligned)
	var taabb := tmesh.get_aabb()
	check(taabb.size.x > 4.0 and taabb.size.y > 8.0 and taabb.size.x < 20.0 and taabb.size.y < 20.0,
		"arbre : dimensions plausibles (%.1f × %.1f × %.1f m)" % [taabb.size.x, taabb.size.y, taabb.size.z])
	var tbody := tree.get_node("Body") as StaticBody3D
	var trunk_shapes := 0
	var leaf_shapes := 0
	for cs in tbody.get_children():
		if String(cs.name).begins_with("Trunk"):
			trunk_shapes += 1
		elif String(cs.name).begins_with("Leaves"):
			leaf_shapes += 1
	check(trunk_shapes >= 2 and leaf_shapes >= 2,
		"arbre : collision calculée (%d colonnes de tronc, %d boîtes de feuillage)" % [trunk_shapes, leaf_shapes])
	check(tree.get_node_or_null("Model") == null, "arbre : plus de GLB embarqué (généré par script)")
	tree.free()

	# Les 5 variantes : mêmes garanties de base, silhouettes et cubes distincts.
	var variant_heights := {}
	var variant_cubes := {}
	for tf in ["tree", "tree2", "tree3", "tree4", "tree5"]:
		var tv = (load("res://Scènes/Monde/%s.tscn" % tf) as PackedScene).instantiate()
		var cc := int(tv.get_meta("cube_count", 0))
		variant_cubes[tf] = cc
		var vb := tv.get_node_or_null("Body")
		var vm: ArrayMesh = (tv.get_node("Blocks") as MeshInstance3D).mesh
		variant_heights[tf] = vm.get_aabb().size.y
		check(cc > 300 and vb != null and vb.get_child_count() > 5,
			"variante %s : %d cubes, %d boîtes de collision" % [tf, cc, vb.get_child_count() if vb != null else 0])
		tv.free()
	check(variant_heights["tree3"] > variant_heights["tree"] \
			and variant_heights["tree"] > variant_heights["tree2"],
		"variantes : silhouettes distinctes (élancé %.1f > original %.1f > trapu %.1f m)"
		% [variant_heights["tree3"], variant_heights["tree"], variant_heights["tree2"]])

	# Les arbres plantés par les chunks ne sont plus mis à l'échelle (cubes
	# uniformes, variété par rotation en quarts de tour) et mélangent les variantes.
	var planted := 0
	var scaled_trees := 0
	var planted_variants := {}
	for key in world.loaded_chunks:
		for ch in world.loaded_chunks[key].get_children():
			if ch is Node3D and ch.scene_file_path.begins_with("res://Scènes/Monde/tree"):
				planted += 1
				planted_variants[ch.scene_file_path] = true
				if not (ch as Node3D).scale.is_equal_approx(Vector3.ONE):
					scaled_trees += 1
	check(scaled_trees == 0, "arbres plantés à l'échelle 1 (%d arbres chargés)" % planted)
	check(planted_variants.size() >= 3,
		"la forêt mélange les variantes (%d / 5 présentes sur %d arbres)" % [planted_variants.size(), planted])

	print("")
	if fails == 0:
		print("=== SMOKE TEST : tout est OK ===")
	else:
		printerr("=== SMOKE TEST : %d échec(s) ===" % fails)
	quit(1 if fails > 0 else 0)
