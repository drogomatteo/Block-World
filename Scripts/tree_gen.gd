class_name TreeGen
# Placement procédural des arbres, entièrement déterministe : chaque chunk
# recalcule les mêmes arbres que ses voisins (pieds dans le chunk ou dans la
# marge autour), donc les feuillages qui débordent s'emboîtent sans
# communication entre chunks.
#
# Silhouettes façon Cube World :
#   - feuillu à dôme : canopée « en terrasses », pile de disques au profil de
#     calotte sphérique, branches montantes finies par un bouquet de feuilles ;
#     ~1 sur 5 en variante jaune-vert, les grands sujets ont un tronc 2×2 ;
#   - sapin : étages en losanges décroissants, feuillage sombre, flèche ;
#   - géant multi-lobes (rare, plaines) : tronc 2×2 haut, grand dôme sommital
#     et des lobes portés par des branches.

const WOOD : int = WorldConfig.WOOD
const LEAVES : int = WorldConfig.LEAVES
const LEAVES_DARK : int = WorldConfig.LEAVES_DARK
const LEAVES_LIME : int = WorldConfig.LEAVES_LIME

# Placement sur GRILLE MACRO : 1 arbre potentiel par cellule de GRID×GRID
# blocs, pied jitteré dans la cellule. Même densité qu'un tirage par colonne
# (proba × GRID²), mais compute_tree_blocks n'itère que les cellules macro
# au lieu de balayer toutes les colonnes.
const GRID := 8

# Tous les blocs d'arbre (coordonnées monde) dont le pied est dans le chunk
# ou dans la marge TREE_MARGIN autour : itère les cellules macro couvrant la
# zone (les pieds hors marge ne peuvent pas atteindre le chunk).
static func compute_tree_blocks(noise : FastNoiseLite, chunk_position : Vector3i) -> Dictionary:
	var blocks := {}
	var x0 := chunk_position.x * WorldConfig.WIDTH - WorldConfig.TREE_MARGIN
	var z0 := chunk_position.z * WorldConfig.DEPTH - WorldConfig.TREE_MARGIN
	var x1 := x0 + WorldConfig.WIDTH + 2 * WorldConfig.TREE_MARGIN - 1
	var z1 := z0 + WorldConfig.DEPTH + 2 * WorldConfig.TREE_MARGIN - 1
	for mx in range(floori(float(x0) / GRID), floori(float(x1) / GRID) + 1):
		for mz in range(floori(float(z0) / GRID), floori(float(z1) / GRID) + 1):
			var f := macro_tree(noise, mx, mz)
			if tree_at(noise, f.x, f.y):
				place_tree(blocks, noise, f.x, f.y)
	return blocks

# Chance d'arbre par COLONNE selon le biome dominant (ordre de BiomeMap :
# montagnes, plaines, neige, océan, désert), multipliée par GRID² pour la
# cellule macro. Plaines : mélange feuillus/sapins/géants ; neige : sapins
# épars ; océan : seulement sur les îles émergées (plus dense, effet oasis) ;
# montagnes et désert : aucun.
const CHANCE_BY_BIOME := [0.0, 0.0022, 0.0018, 0.005, 0.0]
# borne haute de CHANCE_BY_BIOME × GRID² : early-out du tirage avant tout
# échantillonnage de biome/hauteur (chemin chaud des LOD)
const MAX_CELL_CHANCE := 0.32

# Pied (jitteré) de l'arbre potentiel de la cellule macro (mx, mz), en blocs.
static func macro_tree(noise : FastNoiseLite, mx : int, mz : int) -> Vector2i:
	var h := column_seed(noise, mx, mz, 2)
	return Vector2i(mx * GRID + (h & 7), mz * GRID + ((h >> 3) & 7))

# L'arbre de la cellule macro dont (gx, gz) est le pied existe-t-il ?
static func tree_at(noise : FastNoiseLite, gx : int, gz : int) -> bool:
	var r := RandomNumberGenerator.new()
	r.seed = column_seed(noise, gx, gz, 0)
	var roll := r.randf()
	if roll >= MAX_CELL_CHANCE:
		return false
	if roll >= CHANCE_BY_BIOME[TerrainHeight.biome_sample(noise, gx, gz)] * (GRID * GRID):
		return false
	var ground := TerrainHeight.height_at(noise, gx, gz)
	# jamais les pieds dans l'eau, ni dans la neige des sommets
	return ground > WorldConfig.SEA_LEVEL + 1 and ground < WorldConfig.SNOW_LINE - 4

static func place_tree(blocks : Dictionary, noise : FastNoiseLite, gx : int, gz : int) -> void:
	var ground := TerrainHeight.height_at(noise, gx, gz)
	var r := RandomNumberGenerator.new()
	r.seed = column_seed(noise, gx, gz, 1)
	match TerrainHeight.biome_sample(noise, gx, gz):
		BiomeMap.NEIGE:
			_place_spruce(blocks, r, gx, gz, ground)
		BiomeMap.PLAINES:
			var roll := r.randf()
			if roll < 0.05:
				_place_giant(blocks, r, gx, gz, ground)
			elif roll < 0.35:
				_place_spruce(blocks, r, gx, gz, ground)
			else:
				_place_dome_tree(blocks, r, gx, gz, ground)
		_:
			_place_dome_tree(blocks, r, gx, gz, ground)

# Feuillu à dôme : tronc 2×2 à souche évasée (_trunk), canopée = _dome posé
# au sommet, plus 2-3 branches montantes finies par un bouquet.
static func _place_dome_tree(blocks : Dictionary, r : RandomNumberGenerator, gx : int, gz : int, ground : int) -> void:
	var big := r.randf() < 0.35
	var trunk_h := r.randi_range(11, 15) if big else r.randi_range(8, 12)
	var radius := r.randi_range(6, 8) if big else r.randi_range(5, 6)
	var id := LEAVES_LIME if r.randf() < 0.18 else LEAVES
	var top := ground + trunk_h
	_trunk(blocks, gx, gz, ground, top, 3 if big else 2)
	_dome(blocks, Vector3i(gx, top, gz), radius, id)
	# branches qui DÉPASSENT du bord de la canopée : bois visible, bouquet net
	for i in range(r.randi_range(3, 4) if big else r.randi_range(2, 3)):
		_limb(blocks, r, Vector3i(gx, top - r.randi_range(3, 6), gz),
			radius + r.randi_range(0, 2), r.randi_range(3, 4), id)

# Tronc 2×2 (cellules gx..gx+1 × gz..gz+1) avec SOUCHE évasée : un anneau de
# bois autour de la base sur `flare_h` blocs de haut (racines apparentes).
static func _trunk(blocks : Dictionary, gx : int, gz : int, ground : int, top : int, flare_h : int) -> void:
	for y in range(ground + 1, top + 1):
		blocks[Vector3i(gx, y, gz)] = WOOD
		blocks[Vector3i(gx + 1, y, gz)] = WOOD
		blocks[Vector3i(gx, y, gz + 1)] = WOOD
		blocks[Vector3i(gx + 1, y, gz + 1)] = WOOD
	for y in range(ground + 1, mini(ground + flare_h, top) + 1):
		for off in [Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(2, 0), Vector2i(2, 1),
				Vector2i(0, -1), Vector2i(1, -1), Vector2i(0, 2), Vector2i(1, 2)]:
			blocks[Vector3i(gx + off.x, y, gz + off.y)] = WOOD

# Branche : ligne de bois partant de `from`, montant légèrement vers un point
# à `dist` blocs, avec un bouquet de feuilles (dôme de rayon `blob`) au bout.
static func _limb(blocks : Dictionary, r : RandomNumberGenerator, from : Vector3i,
		dist : int, blob : int, id : int) -> void:
	var ang := r.randf() * TAU
	var to := from + Vector3i(roundi(cos(ang) * dist), r.randi_range(1, 2), roundi(sin(ang) * dist))
	var n := maxi(maxi(absi(to.x - from.x), absi(to.y - from.y)), absi(to.z - from.z))
	for i in range(n + 1):
		var t := float(i) / maxf(1.0, float(n))
		blocks[Vector3i(roundi(lerpf(from.x, to.x, t)), roundi(lerpf(from.y, to.y, t)),
			roundi(lerpf(from.z, to.z, t)))] = WOOD
	_dome(blocks, to + Vector3i(0, 1, 0), blob, id)

# Sapin : étages de losanges (2 couches, la 2e plus étroite) séparés d'un
# bloc de tronc visible, rayon décroissant vers le haut, flèche de 2 blocs ;
# feuillage sombre.
static func _place_spruce(blocks : Dictionary, r : RandomNumberGenerator, gx : int, gz : int, ground : int) -> void:
	var base_r := r.randi_range(3, 5)
	var y := ground + r.randi_range(2, 3)
	# tronc jusqu'au dernier étage (posé d'abord : le bois gagne sur la feuille),
	# souche en croix au ras du sol
	var trunk_top := y + (base_r - 1) * 3
	for ty in range(ground + 1, trunk_top + 1):
		blocks[Vector3i(gx, ty, gz)] = WOOD
	blocks[Vector3i(gx - 1, ground + 1, gz)] = WOOD
	blocks[Vector3i(gx + 1, ground + 1, gz)] = WOOD
	blocks[Vector3i(gx, ground + 1, gz - 1)] = WOOD
	blocks[Vector3i(gx, ground + 1, gz + 1)] = WOOD
	for rad in range(base_r, 0, -1):
		_diamond(blocks, gx, y, gz, rad)
		if rad > 1:
			_diamond(blocks, gx, y + 1, gz, rad - 1)
			y += 3
		else:
			y += 1
	set_leaf(blocks, Vector3i(gx, y, gz))
	set_leaf(blocks, Vector3i(gx, y + 1, gz))

# Géant multi-lobes : tronc 2×2 haut, grand dôme au sommet, et des lobes
# portés par de vraies branches partant du haut du tronc (portée horizontale
# max 17 = branche 12 + rayon de lobe 5, cf. TREE_MARGIN).
static func _place_giant(blocks : Dictionary, r : RandomNumberGenerator, gx : int, gz : int, ground : int) -> void:
	var trunk_h := r.randi_range(18, 24)
	var top := ground + trunk_h
	_trunk(blocks, gx, gz, ground, top, 4)
	_dome(blocks, Vector3i(gx, top, gz), r.randi_range(8, 9), LEAVES)
	for i in range(r.randi_range(4, 5)):
		_limb(blocks, r, Vector3i(gx, top - r.randi_range(4, 8), gz),
			r.randi_range(8, 12), r.randi_range(4, 5), LEAVES)

# Dôme de feuilles centré en `center` : disques empilés, rayon en calotte
# sphérique (dessous rentré d'un cran, bouton sommital).
static func _dome(blocks : Dictionary, center : Vector3i, radius : int, id : int) -> void:
	for dy in range(-1, radius + 1):
		var rad := radius - 1
		if dy >= 0:
			var t := float(dy) / float(radius)
			rad = maxi(1, roundi(float(radius) * sqrt(1.0 - t * t)))
		for dx in range(-rad, rad + 1):
			for dz in range(-rad, rad + 1):
				if dx * dx + dz * dz <= rad * rad + (rad >> 1):
					set_leaf(blocks, center + Vector3i(dx, dy, dz), id)

# Losange plein |dx|+|dz| <= rad au niveau y (étage de sapin).
static func _diamond(blocks : Dictionary, gx : int, y : int, gz : int, rad : int) -> void:
	for dx in range(-rad, rad + 1):
		var span := rad - absi(dx)
		for dz in range(-span, span + 1):
			set_leaf(blocks, Vector3i(gx + dx, y, gz + dz), LEAVES_DARK)

static func set_leaf(blocks : Dictionary, pos : Vector3i, id : int = LEAVES) -> void:
	if not blocks.has(pos):
		blocks[pos] = id

# Hash déterministe seed monde + colonne ; salt sépare les canaux de RNG
# (placement / forme) pour qu'une variante future ne décale pas les positions.
static func column_seed(noise : FastNoiseLite, gx : int, gz : int, salt : int) -> int:
	var h : int = noise.seed + salt * 668265263
	h ^= gx * 374761393
	h ^= gz * 2246822519
	h = (h ^ (h >> 13)) * 1274126177
	return h & 0x7fffffffffffffff
