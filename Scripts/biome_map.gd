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

# Pour l'instant les biomes ne diffèrent que par leur relief :
# hauteur = OFFSET + bruit(-1..1) * AMP, en blocs. Chaque biome a son propre
# fichier de bruit (fréquence/fractale adaptées : crêtes ridged en montagne,
# dunes serrées au désert, fond marin très doux...).
const NOISES := [
	preload("res://Ressource/Noise/biome_montagnes.tres"),
	preload("res://Ressource/Noise/biome_plaines.tres"),
	preload("res://Ressource/Noise/biome_neige.tres"),
	preload("res://Ressource/Noise/biome_ocean.tres"),
	preload("res://Ressource/Noise/biome_desert.tres"),
]
const OFFSET := [26.0, 8.0, 11.0, 2.0, 7.0]
const AMP := [24.0, 4.0, 6.0, 2.0, 3.0]

const CELL := 192.0   # taille d'une cellule de biome, en blocs (6 chunks)
static var K := 6.0   # précision du fondu entre cellules (voir en-tête)

# Hauteur mélangée (en blocs, flottante, >= 0) au point monde (x, z).
static func height_sample(world_seed : int, x : float, z : float) -> float:
	var weights := _weights(world_seed, x, z)
	var h := 0.0
	var used := 0.0
	for b in range(5):
		var w : float = weights[b]
		if w < 0.004:
			continue  # biome négligeable ici : on s'épargne son bruit
		h += w * (OFFSET[b] + NOISES[b].get_noise_2d(x, z) * AMP[b])
		used += w
	return maxf(h / used, 0.0)

# Biome dominant au point (débug, et spécificités par biome à venir).
static func biome_at(world_seed : int, x : float, z : float) -> int:
	var weights := _weights(world_seed, x, z)
	var best := 0
	for b in range(1, 5):
		if weights[b] > weights[best]:
			best = b
	return best

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
