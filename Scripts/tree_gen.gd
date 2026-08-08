class_name TreeGen
# Placement procédural des arbres, entièrement déterministe : chaque chunk
# recalcule les mêmes arbres que ses voisins (pieds dans le chunk ou dans la
# marge autour), donc les feuillages qui débordent s'emboîtent sans
# communication entre chunks.

const WOOD : int = 2
const LEAVES : int = 3

# Tous les blocs d'arbre (coordonnées monde) dont le pied est dans le chunk
# ou dans la marge TREE_MARGIN autour.
static func compute_tree_blocks(noise : FastNoiseLite, chunk_position : Vector3i) -> Dictionary:
	var blocks := {}
	var base_x := chunk_position.x * WorldConfig.WIDTH
	var base_z := chunk_position.z * WorldConfig.DEPTH
	for x in range(-WorldConfig.TREE_MARGIN, WorldConfig.WIDTH + WorldConfig.TREE_MARGIN):
		for z in range(-WorldConfig.TREE_MARGIN, WorldConfig.DEPTH + WorldConfig.TREE_MARGIN):
			var gx := base_x + x
			var gz := base_z + z
			if tree_at(noise, gx, gz):
				place_tree(blocks, noise, gx, gz)
	return blocks

# Chance d'arbre par colonne selon le biome dominant (ordre de BiomeMap :
# montagnes, plaines, neige, océan, désert). Plaines : peu d'arbres ;
# montagnes : très rares, et jamais au-dessus de la ligne de neige ; océan :
# seulement sur les îles émergées (plus dense, effet oasis) ; neige et
# désert : aucun.
const CHANCE_BY_BIOME := [0.0015, 0.003, 0.0, WorldConfig.TREE_CHANCE, 0.0]

static func tree_at(noise : FastNoiseLite, gx : int, gz : int) -> bool:
	var chance : float = CHANCE_BY_BIOME[TerrainHeight.biome_sample(noise, gx, gz)]
	if chance <= 0.0:
		return false
	var ground := TerrainHeight.height_at(noise, gx, gz)
	# jamais les pieds dans l'eau, ni dans la neige des sommets
	if ground <= WorldConfig.SEA_LEVEL + 1 or ground >= WorldConfig.SNOW_LINE - 4:
		return false
	var r := RandomNumberGenerator.new()
	r.seed = column_seed(noise, gx, gz, 0)
	return r.randf() < chance

static func place_tree(blocks : Dictionary, noise : FastNoiseLite, gx : int, gz : int) -> void:
	var ground := TerrainHeight.height_at(noise, gx, gz)
	var r := RandomNumberGenerator.new()
	r.seed = column_seed(noise, gx, gz, 1)
	var trunk_h := r.randi_range(WorldConfig.TRUNK_MIN, WorldConfig.TRUNK_MAX)
	var top := ground + trunk_h
	var max_top := top + ceili(trunk_h/4)

	for y in range(ground + 1, top + 1):
		blocks[Vector3i(gx, y, gz)] = WOOD


	var lr := WorldConfig.LEAF_RADIUS

	# couronne massive : 3 couches larges (rayon LEAF_RADIUS), coins durs
	# retirés et pourtour rogné au RNG pour arrondir la silhouette
	for y in range(top, max_top + 1):
		for dx in range(-lr, lr + 1):
			for dz in range(-lr, lr + 1):
				if absi(dx) == lr and absi(dz) == lr:
					continue
				if absi(dx) + absi(dz) >= lr + 2 and r.randf() < 0.07:
					continue
				set_leaf(blocks, Vector3i(gx + dx, y, gz + dz))

	# épaulement plus étroit puis chapeau (deux couches)
	for dx in range(-lr + 1, lr):
		for dz in range(-lr + 1, lr):
			if absi(dx) == lr - 1 and absi(dz) == lr - 1:
				continue
			if r.randf() < 0.07:
				continue
			set_leaf(blocks, Vector3i(gx + dx, max_top + 1, gz + dz))

	for dx in range(-lr + 2, lr - 1):
		for dz in range(-lr + 2, lr - 1):
			if absi(dx) >= lr - 3 and absi(dz) >= lr - 3:
				continue
			if r.randf() < 0.07:
				continue
			set_leaf(blocks, Vector3i(gx + dx, max_top + 2, gz + dz))

	for dx in range(-lr + 3, lr - 2):
		for dz in range(-lr + 3, lr - 2):
			if absi(dx) >= lr - 4 and absi(dz) >= lr - 4:
				continue
			if r.randf() < 0.07:
				continue
			set_leaf(blocks, Vector3i(gx + dx, max_top + 3, gz + dz))

static func set_leaf(blocks : Dictionary, pos : Vector3i) -> void:
	if not blocks.has(pos):
		blocks[pos] = LEAVES

# Hash déterministe seed monde + colonne ; salt sépare les canaux de RNG
# (placement / forme) pour qu'une variante future ne décale pas les positions.
static func column_seed(noise : FastNoiseLite, gx : int, gz : int, salt : int) -> int:
	var h : int = noise.seed + salt * 668265263
	h ^= gx * 374761393
	h ^= gz * 2246822519
	h = (h ^ (h >> 13)) * 1274126177
	return h & 0x7fffffffffffffff
