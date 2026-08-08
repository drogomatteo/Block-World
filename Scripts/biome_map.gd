class_name BiomeMap
# Carte de biomes par bruit de Worley (cellulaire) : le monde est découpé en
# cellules de CELL blocs ; chaque cellule reçoit un point caractéristique
# (jitter déterministe) et un biome tiré au hash. La hauteur du terrain en un
# point est le MÉLANGE pondéré des hauteurs des biomes des cellules voisines
# (fenêtre 3×3) :
#   poids(cellule) = exp(-K * distance(point, point caractéristique) / CELL)
# K règle la précision du fondu : K grand -> frontières nettes mais des plis
# d'artéfacts apparaissent aux lignes d'équidistance (le poids « saute » d'un
# point caractéristique à l'autre) ; K petit -> transitions larges où les
# biomes déteignent les uns sur les autres. Tout est fonction pure de
# (seed monde, x, z) : le déterminisme (multijoueur par seed) est préservé.

const MONTAGNES := 0
const PLAINES := 1
const NEIGE := 2  # plaines enneigées
const OCEAN := 3
const DESERT := 4

const NAMES := ["montagnes", "plaines", "plaines enneigées", "océan", "désert"]

# Chaque biome a son propre fichier de bruit (fréquence/fractale adaptées :
# crêtes ridged en montagne, dunes serrées au désert, fond marin très doux...)
# et sa propre FORMULE de relief (_biome_height). Les biomes terrestres
# restent au-dessus de SEA_LEVEL (10) : seuls l'océan (et les fondus côtiers)
# passent dessous.
const NOISES := [
	preload("res://Ressource/Noise/biome_montagnes.tres"),
	preload("res://Ressource/Noise/biome_plaines.tres"),
	preload("res://Ressource/Noise/biome_neige.tres"),
	preload("res://Ressource/Noise/biome_ocean.tres"),
	preload("res://Ressource/Noise/biome_desert.tres"),
]

# Réglages de relief (blocs)
# bases terrestres >= SEA_LEVEL + 2 + amplitude : la règle « plage » de
# strata() ne doit jamais mordre au coeur d'un biome terrestre
const PLAINES_BASE := 25.0
const PLAINES_AMP := 3.0
const NEIGE_BASE := 30.0
const NEIGE_AMP := 1.0
const MONT_BASE := 50.0
const MONT_AMP := 50.0        # hauteur max des pics au-dessus de la base
const MONT_SHARP := 1.5       # exposant : > 1 = vallées larges, pics rares
const OCEAN_FLOOR := -20.0      # fond marin moyen (sous SEA_LEVEL = profond)
const OCEAN_FLOOR_AMP := 5.0
# Îles : seuil sur le bruit décalé (fractal 3 octaves : dépasse rarement
# ~0,6, un seuil haut ne sortirait jamais de l'eau) ; la rampe est bornée à
# ISLAND_FULL pour que les rares maxima donnent des îles franches.
const ISLAND_THRESHOLD := 0.35
const ISLAND_FULL := 0.65
const ISLAND_AMP := 26.0
const DESERT_BASE := 20.0
const DESERT_AMP := 1.5
const DUNE_AMP := 15.0         # hauteur des crêtes de dunes

const CELL := 2048.0   # taille d'une cellule de biome, en blocs (16 chunks)
static var K := 6.0   # précision du fondu entre cellules (voir en-tête)

# Hauteur mélangée + biome dominant au point monde (x, z) : Vector2(hauteur
# en blocs >= 0, biome). Une seule passe de poids pour les deux (le biome
# dominant décide du bloc de surface via strata()).
static func sample(world_seed : int, x : float, z : float) -> Vector2:
	var weights := _weights(world_seed, x, z)
	var h := 0.0
	var used := 0.0
	var best := 0
	for b in range(5):
		var w : float = weights[b]
		if w > weights[best]:
			best = b
		if w < 0.004:
			continue  # biome négligeable ici : on s'épargne son bruit
		h += w * _biome_height(b, x, z)
		used += w
	return Vector2(maxf(h / used, 0.0), float(best))

static func height_sample(world_seed : int, x : float, z : float) -> float:
	return sample(world_seed, x, z).x

# Biome dominant EXACT au point : position pure Worley (hash + distances,
# AUCUN bruit de hauteur) — la frontière de matériau est une courbe nette au
# bloc près, indépendante de l'up-sampling des hauteurs. C'est la référence
# pour le bloc de surface ; la hauteur, elle, reste le mélange pondéré.
static func biome_exact(world_seed : int, x : float, z : float) -> int:
	var weights := _weights(world_seed, x, z)
	var best := 0
	for b in range(1, 5):
		if weights[b] > weights[best]:
			best = b
	return best

# Biome dominant au point (débug, cartes).
static func biome_at(world_seed : int, x : float, z : float) -> int:
	return biome_exact(world_seed, x, z)

# Relief d'un biome pur au point (x, z), en blocs.
static func _biome_height(b : int, x : float, z : float) -> float:
	var n : float = NOISES[b].get_noise_2d(x, z)
	match b:
		MONTAGNES:
			# bruit ridged accentué : les vallées s'aplatissent, les crêtes
			# deviennent des pics ; culmine au-dessus de SNOW_LINE
			var n01 := (n + 1.0) * 0.5
			return MONT_BASE + pow(n01, MONT_SHARP) * MONT_AMP
		PLAINES:
			return PLAINES_BASE + n * PLAINES_AMP
		NEIGE:
			return NEIGE_BASE + n * NEIGE_AMP
		OCEAN:
			# fond profond ; parfois une île : partie du bruit (échantillon
			# décalé -> indépendant du fond) au-dessus du seuil, élevée en
			# puissance pour des flancs qui sortent franchement de l'eau
			var h := OCEAN_FLOOR + n * OCEAN_FLOOR_AMP
			var isl : float = NOISES[OCEAN].get_noise_2d(x + 7777.0, z - 7777.0)
			if isl > ISLAND_THRESHOLD:
				var excess := clampf((isl - ISLAND_THRESHOLD) / (ISLAND_FULL - ISLAND_THRESHOLD), 0.0, 1.0)
				h += pow(excess, 1.4) * ISLAND_AMP
			return h
		DESERT:
			# aussi plat que la plaine, sauf des champs de dunes : crêtes en
			# 1 - |bruit| (arêtes vives), masquées par un bruit très lent
			var h := DESERT_BASE + n * DESERT_AMP
			var mask : float = smoothstep(0.1, 0.7, NOISES[DESERT].get_noise_2d(x * 0.25 + 3333.0, z * 0.25))
			if mask > 0.0:
				var crest := 1.0 - absf(NOISES[DESERT].get_noise_2d(x * 3.0, z * 3.0 + 3333.0))
				h += mask * pow(crest, 2.0) * DUNE_AMP
			return h
	return float(WorldConfig.SEA_LEVEL)

# --- Blocs de la colonne (strates) ----------------------------------------
# Plages [id, longueur] du bas (y = -1) au sommet `top` inclus, total =
# top + 2. Le biome décide du bloc de surface et du remplissage :
#   plaines   : terre + 1 bloc d'herbe
#   désert    : roche + 4 blocs de sable
#   montagnes : roche + 3 blocs de terre ; neige (ou glace par plaques de
#               glacier) au lieu de la terre au-dessus de la ligne de neige
#   neige     : terre + 3 blocs de neige
#   océan     : sable ; les îles qui émergent gagnent 1 bloc d'herbe
static func strata(world_seed : int, gx : int, gz : int, biome : int, top : int) -> Array:
	var total := top + 2
	if total <= 0:
		return []
	# Côtes : toute colonne qui trempe ou affleure (jusqu'à 1 bloc au-dessus
	# de la mer) est du sable, quel que soit le biome — l'herbe ne descend
	# jamais sous l'eau, chaque rivage a sa plage. Les reliefs de base des
	# biomes terrestres restent au-dessus de ce seuil : la règle ne mord que
	# dans les fondus côtiers.
	if top < WorldConfig.SEA_LEVEL + 2:
		return [[WorldConfig.SAND, total]]
	var fill := WorldConfig.DIRT
	var surf := WorldConfig.GRASS
	var surf_len := 1
	match biome:
		DESERT:
			fill = WorldConfig.ROCK
			surf = WorldConfig.SAND
			surf_len = 4
		MONTAGNES:
			fill = WorldConfig.ROCK
			surf_len = 3
			if top >= _snow_line(gx, gz):
				surf = WorldConfig.ICE if _glacier(gx, gz) else WorldConfig.SNOW
			else:
				surf = WorldConfig.DIRT
		NEIGE:
			surf = WorldConfig.SNOW
			surf_len = 3
		OCEAN:
			fill = WorldConfig.SAND
			if top >= WorldConfig.SEA_LEVEL + 3:
				surf = WorldConfig.GRASS  # île émergée
				surf_len = 1
			else:
				surf = WorldConfig.SAND   # fond marin / plage
	surf_len = mini(surf_len, total)
	if surf == fill or surf_len >= total:
		return [[surf, total]]
	return [[fill, total - surf_len], [surf, surf_len]]

# Bloc de surface seul (LOD : la colonne entière prend cette couleur).
static func surface_block(world_seed : int, gx : int, gz : int, biome : int, top : int) -> int:
	var runs := strata(world_seed, gx, gz, biome, top)
	return runs[-1][0] if not runs.is_empty() else WorldConfig.AIR

# Ligne de neige jitterée par bruit (une ligne droite trahit le procédural).
static func _snow_line(gx : int, gz : int) -> int:
	return WorldConfig.SNOW_LINE + int(NOISES[PLAINES].get_noise_2d(gx * 5.0, gz * 5.0) * 4.0)

# Plaques de glaciers sur les sommets enneigés.
static func _glacier(gx : int, gz : int) -> bool:
	return NOISES[NEIGE].get_noise_2d(gx * 3.0, gz * 3.0) > 0.45

# Poids normalisés des 5 biomes au point (x, z), par fenêtre 3×3 de cellules.
static func _weights(world_seed : int, x : float, z : float) -> Array:
	var weights := [0.0, 0.0, 0.0, 0.0, 0.0]
	var total := 0.0
	var cx := floori(x / CELL)
	var cz := floori(z / CELL)
	var p := Vector2(x, z)
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var ccx := cx + dx
			var ccz := cz + dz
			var d := p.distance_to(_feature(world_seed, ccx, ccz))
			var w : float = exp(-K * d / CELL)
			weights[_cell_biome(world_seed, ccx, ccz)] += w
			total += w
	for b in range(5):
		weights[b] /= total
	return weights

# Point caractéristique de la cellule : coin + jitter déterministe.
static func _feature(world_seed : int, cx : int, cz : int) -> Vector2:
	return Vector2(
		(cx + _hash01(world_seed, cx, cz, 1)) * CELL,
		(cz + _hash01(world_seed, cx, cz, 2)) * CELL)

static func _cell_biome(world_seed : int, cx : int, cz : int) -> int:
	return _hash(world_seed, cx, cz, 0) % 5

# Hash déterministe seed monde + cellule + salt (même famille que TreeGen).
static func _hash(world_seed : int, cx : int, cz : int, salt : int) -> int:
	var h : int = world_seed + salt * 668265263
	h ^= cx * 374761393
	h ^= cz * 2246822519
	h = (h ^ (h >> 13)) * 1274126177
	return h & 0x7fffffffffffffff

static func _hash01(world_seed : int, cx : int, cz : int, salt : int) -> float:
	return float(_hash(world_seed, cx, cz, salt) & 0xFFFF) / 65536.0
