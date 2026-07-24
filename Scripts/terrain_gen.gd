class_name TerrainGen
extends Node

# Génération procédurale DÉTERMINISTE : tout dépend uniquement de (world_seed, x, z).
# Instancié depuis Scènes/Monde/terrain_gen.tscn par world.gd, qui appelle
# setup(seed) avant toute utilisation (une scène ne peut pas passer d'argument
# au constructeur). Le nœud vit sous World : visible dans l'arbre distant.
# C'est volontaire — un jour, en multijoueur, il suffira de partager le seed pour que
# tous les joueurs génèrent exactement le même monde sans transférer le terrain.
#
# UNITÉS : tout ici est exprimé en INDICES DE CUBE. Un cube mesure Chunk.CUBE
# (0.6 m = le tiers du joueur) dans le monde : x/z sont des indices de colonne,
# get_height renvoie une hauteur en cubes. Conversion monde -> indice :
# roundi(w / Chunk.CUBE) ; indice -> monde : i * Chunk.CUBE. Les fréquences de
# bruit sont réglées pour des reliefs à la même échelle MONDE qu'avant.

enum Biome { DESERT, PLAINS, FOREST, MOUNTAINS, SNOW, OCEAN }

# Niveau de l'eau, en unités cube (niveau monde = WATER_Y * Chunk.CUBE).
# C'est aussi un seuil de génération : sous l'eau rien ne pousse et les blocs
# deviennent du sable/vase (lit du lac).
const WATER_Y := -1.1

# Océan : un bruit « continental » très basse fréquence, INDÉPENDANT des biomes
# terrestres. Sous OCEAN_T on est en mer ; le fond rejoint la terre au rivage
# puis plonge vers OCEAN_FLOOR sur une bande de bruit OCEAN_SHELF (plateau
# continental) — pas de falaise abrupte à la côte.
const OCEAN_T := -0.35
const OCEAN_SHELF := 0.18
const OCEAN_FLOOR := -14.0 # fond au large, en cubes (~ -8.4 m, soit ~7.8 m d'eau)

# Fleuves : creusés le long des lignes de zéro d'un bruit dédié. La distance
# au centre est NORMALISÉE par le gradient local du bruit (|n|/|∇n|) : la
# largeur est donc constante en mètres, quelle que soit la pente du bruit.
# Lit PLAT immergé jusqu'à RIVER_HALF_W, berges en pente douce jusqu'à
# RIVER_BANK_W. ~11 m d'eau, ~2.3 m de profondeur.
const RIVER_GATE := 0.35   # préfiltre sur |bruit| (évite le calcul du gradient loin du fleuve)
const RIVER_HALF_W := 9.0  # demi-largeur du lit immergé, en cubes
const RIVER_BANK_W := 16.0 # demi-largeur totale, berges comprises
const RIVER_BED := -5.0    # fond du lit, en cubes

# Vallées fluviales : le relief S'ABAISSE progressivement à l'approche d'un
# fleuve (fini le lit qui tranche une montagne en canyon à parois verticales).
# Le facteur d'abaissement est |bruit de fleuve| (0 au centre du fleuve) : il
# est continu PARTOUT, contrairement à la distance normalisée qui s'arrête au
# préfiltre RIVER_GATE et créerait une marche à sa frontière.
const RIVER_VALLEY_N := 0.28   # |bruit| sous lequel la vallée se creuse
const RIVER_VALLEY_CAP := 4.0  # hauteur max (en cubes) au bord du fleuve

# Relief CONTINU : une seule fonction de hauteur pour toute la terre, sans
# amplitude ni base par biome (fini les marches aux frontières de biomes).
# L'amplitude croît avec le bruit lui-même (lissée par smoothstep) : les creux
# restent des plaines douces (AMP_LOW), les hauts du bruit s'étirent en vraies
# montagnes (AMP_HIGH). Le biome MONTAGNE n'est plus une zone du bruit de
# biome : c'est toute colonne dont la hauteur dépasse MOUNTAIN_T.
const LAND_BASE := 2.0   # hauteur moyenne des terres, en cubes
const AMP_LOW := 5.0     # amplitude des plaines (creux du bruit)
const AMP_HIGH := 55.0   # amplitude des sommets (hauts du bruit, ~33 m)
const MOUNTAIN_T := 18.0 # seuil montagne, en cubes (~10.8 m au-dessus de la mer)
const SNOWCAP_Y := 30    # au-dessus : sommets enneigés (~18 m)

var world_seed: int
var height_noise: FastNoiseLite
var biome_noise: FastNoiseLite
var continent_noise: FastNoiseLite
var river_noise: FastNoiseLite
var tint_noise: FastNoiseLite

func setup(seed_value: int) -> void:
	world_seed = seed_value

	height_noise = FastNoiseLite.new()
	height_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	height_noise.seed = seed_value
	# Fréquence très basse (reliefs ~240 m de large) : l'amplitude a grimpé
	# (AMP_HIGH) mais les pentes restent douces car le bruit est très étiré.
	height_noise.frequency = 0.0025
	height_noise.fractal_octaves = 4

	# Un bruit très basse fréquence = grandes zones = biomes cohérents.
	biome_noise = FastNoiseLite.new()
	biome_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	biome_noise.seed = seed_value + 4096
	# Très basse fréquence : zones climatiques ~1.5 km de large (encore ~1.75×
	# plus étendues que la version précédente).
	biome_noise.frequency = 0.0004

	# Continents/océans : encore plus basse fréquence que les biomes, pour de
	# vraies mers à explorer (et non des lacs géants).
	continent_noise = FastNoiseLite.new()
	continent_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	continent_noise.seed = seed_value + 8192
	continent_noise.frequency = 0.00035

	# Fleuves : peu d'octaves = méandres amples et lisses ; fréquence basse =
	# fleuves espacés (plusieurs centaines de mètres entre deux).
	river_noise = FastNoiseLite.new()
	river_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	river_noise.seed = seed_value + 16384
	river_noise.frequency = 0.0012
	river_noise.fractal_octaves = 2

	# Teinte de l'herbe : patches de verts (~30 m) qui font dériver doucement
	# la couleur des plaines/forêts — jamais le même vert partout.
	tint_noise = FastNoiseLite.new()
	tint_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	tint_noise.seed = seed_value + 32768
	tint_noise.frequency = 0.02

func get_biome(wx: int, wz: int) -> int:
	if continent_noise.get_noise_2d(float(wx), float(wz)) < OCEAN_T:
		return Biome.OCEAN
	return _land_biome(wx, wz)

# Biome terrestre « sous-jacent » (utilisé aussi pour raccorder le rivage).
# La montagne est purement altimétrique : au-dessus de MOUNTAIN_T, quelle que
# soit la zone climatique, la colonne est MOUNTAINS. En dessous, le bruit de
# biome répartit les climats (le relief, lui, est le même partout : continu).
func _land_biome(wx: int, wz: int) -> int:
	if _land_height(wx, wz) >= MOUNTAIN_T:
		return Biome.MOUNTAINS
	var v := biome_noise.get_noise_2d(float(wx), float(wz))
	if v < -0.45:
		return Biome.DESERT
	elif v < 0.1:
		return Biome.PLAINS
	elif v < 0.5:
		return Biome.FOREST
	return Biome.SNOW

# Hauteur terrestre CONTINUE (en cubes, non arrondie), identique pour tous les
# biomes. smoothstep fait croître l'amplitude avec le bruit : dérivable partout,
# donc aucune rupture de pente — les montagnes émergent progressivement des
# collines au lieu d'apparaître à une frontière.
func _land_height(wx: int, wz: int) -> float:
	var n := height_noise.get_noise_2d(float(wx), float(wz))
	var t := smoothstep(0.0, 0.6, n)
	var h := LAND_BASE + n * lerpf(AMP_LOW, AMP_HIGH, t)
	# Vallée fluviale : près d'un fleuve, la hauteur est plafonnée puis relevée
	# en douceur avec la distance. Comme le BIOME lit cette hauteur, les flancs
	# de vallée redeviennent plaines/forêt — un fleuve qui traverse un massif
	# creuse une vraie vallée verte, pas un canyon gris à parois verticales.
	var rn := absf(river_noise.get_noise_2d(float(wx), float(wz)))
	if rn < RIVER_VALLEY_N:
		var vt := smoothstep(0.0, 1.0, rn / RIVER_VALLEY_N)
		h = lerpf(minf(h, RIVER_VALLEY_CAP), h, vt)
	# Les biomes terrestres ne descendent JAMAIS sous le niveau de l'eau : les
	# seuls plans d'eau du monde sont l'océan et les rivières (fini les lacs
	# aléatoires creusés par le bruit de relief).
	return maxf(h, WATER_Y + 0.1)

# Hauteur (entière) du sommet de la colonne au point monde (wx, wz).
func get_height(wx: int, wz: int) -> int:
	# Bruit « détail » : le bruit de relief échantillonné 3× plus serré, pour les
	# petites structures (dunes du fond marin, fosses du lit de fleuve) qui
	# doivent varier vite même si le relief général est très étiré.
	var n := height_noise.get_noise_2d(float(wx) * 3.0, float(wz) * 3.0)
	var h := _land_height(wx, wz)
	var c := continent_noise.get_noise_2d(float(wx), float(wz))
	if c < OCEAN_T:
		# Plateau continental : à la côte (t=0) on rejoint la hauteur terrestre
		# (continuité, pas de mur), au large (t=1) le fond plonge vers
		# OCEAN_FLOOR avec un léger relief de dunes.
		var t := smoothstep(0.0, 1.0, (OCEAN_T - c) / OCEAN_SHELF)
		h = lerpf(h, OCEAN_FLOOR + n * 2.0, t)
	# Fleuves : lit immergé au cœur (avec son propre relief : dunes et fosses,
	# pas un fond plat), berges en pente douce sur les bords. min() : on ne
	# rebouche jamais un fond déjà plus bas (océan) — le fleuve s'y jette
	# naturellement.
	var rd := _river_dist(wx, wz)
	if rd < RIVER_BANK_W:
		var bed := RIVER_BED + n * 2.0 # ±1.2 m de relief, toujours sous l'eau
		var t := smoothstep(0.0, 1.0, maxf(0.0, rd - RIVER_HALF_W) / (RIVER_BANK_W - RIVER_HALF_W))
		h = minf(h, lerpf(bed, h, t))
	return roundi(h)

# Distance approchée (en cubes) au centre du fleuve le plus proche : |bruit|
# divisé par la pente locale du bruit (différences finies sur 2 cubes).
# Renvoie une valeur énorme loin de tout fleuve (au-delà du préfiltre).
func _river_dist(wx: int, wz: int) -> float:
	var n := river_noise.get_noise_2d(float(wx), float(wz))
	if absf(n) >= RIVER_GATE:
		return 1e9
	var gx := (river_noise.get_noise_2d(float(wx) + 2.0, float(wz)) - n) * 0.5
	var gz := (river_noise.get_noise_2d(float(wx), float(wz) + 2.0) - n) * 0.5
	var g := maxf(Vector2(gx, gz).length(), 1e-4)
	return absf(n) / g

# Vrai sur toute colonne d'eau d'un fleuve (lit plat ET partie immergée des
# berges). Utilisé par le smoke test ; pratique aussi pour du gameplay futur.
func is_river(wx: int, wz: int) -> bool:
	return _river_dist(wx, wz) < RIVER_BANK_W \
		and float(get_height(wx, wz)) + 0.5 < WATER_Y

# Couleur d'un cube. y == h => bloc de surface, sinon bloc enterré (assombri).
func get_color(wx: int, wz: int, y: int, h: int) -> Color:
	var biome := get_biome(wx, wz)
	var c := Color(0.38, 0.66, 0.30)
	match biome:
		Biome.DESERT:
			c = Color(0.85, 0.78, 0.48)
		Biome.PLAINS:
			c = Color(0.38, 0.66, 0.30)
		Biome.FOREST:
			c = Color(0.26, 0.52, 0.24)
		Biome.MOUNTAINS:
			c = Color(0.50, 0.50, 0.52)
		Biome.SNOW:
			c = Color(0.90, 0.93, 0.96)
		Biome.OCEAN:
			c = Color(0.80, 0.73, 0.52) # îlots et hauts-fonds : sable
	if biome == Biome.PLAINS or biome == Biome.FOREST:
		# Dérive de teinte de l'herbe (tint_noise) : plus jaune/claire ou plus
		# profonde selon le patch. Appliquée AVANT les cas plage/immergé/enterré
		# (qui écrasent ou assombrissent la couleur, teinte comprise).
		var t := tint_noise.get_noise_2d(float(wx), float(wz))
		c.h = wrapf(c.h + t * 0.03, 0.0, 1.0)
		c.v = clampf(c.v * (1.0 + t * 0.12), 0.0, 1.0)
	var top := float(h) + 0.5
	if top < WATER_Y:
		# Bloc immergé : lit sableux, assombri avec la profondeur.
		var depth := WATER_Y - top # en cubes
		c = Color(0.58, 0.53, 0.38).darkened(clampf(depth * 0.05, 0.0, 0.45))
	elif top < WATER_Y + 1.0 and biome != Biome.DESERT and biome != Biome.SNOW \
			and near_water(wx, wz):
		# Plage de sable : bas ET à quelques cubes d'une VRAIE colonne d'eau —
		# un creux de terrain intérieur au niveau de la mer reste de l'herbe.
		c = Color(0.80, 0.73, 0.52)
	if y < h:
		c = c.darkened(0.35) # bloc enterré
	elif biome == Biome.MOUNTAINS and y >= SNOWCAP_Y:
		c = Color(0.92, 0.94, 0.97) # sommets enneigés
	return c

# Vrai s'il existe une colonne d'eau réelle (sommet immergé) à ≤ radius cubes.
# Portes rapides d'abord : l'eau n'existe que dans l'océan et les fleuves, donc
# loin des deux (bruit continental et distance au fleuve), inutile de sonder —
# le balayage de hauteurs ne se paie qu'aux abords des côtes et des berges.
func near_water(wx: int, wz: int, radius := 5) -> bool:
	if continent_noise.get_noise_2d(float(wx), float(wz)) > OCEAN_T + 0.02 \
			and _river_dist(wx, wz) > RIVER_HALF_W + float(radius) + 2.0:
		return false
	for dx in range(-radius, radius + 1):
		for dz in range(-radius, radius + 1):
			if dx * dx + dz * dz > radius * radius or (dx == 0 and dz == 0):
				continue
			if float(get_height(wx + dx, wz + dz)) + 0.5 < WATER_Y:
				return true
	return false

# Seuil d'apparition de la flore : rien ne pousse sous l'eau, sur la bande
# de plage (le dessus du bloc de surface doit dépasser le niveau de l'eau
# d'au moins un cube), ni nulle part en mer (même sur un îlot de sable).
func can_spawn_flora(wx: int, wz: int) -> bool:
	if get_biome(wx, wz) == Biome.OCEAN:
		return false
	return float(get_height(wx, wz)) + 0.5 >= WATER_Y + 1.0

# Taille (en cubes) des cellules de la grille d'arbres : AU PLUS un arbre par
# cellule, à une position jitterée à l'intérieur (marge de 2 cubes aux bords).
# Deux arbres ne peuvent donc jamais être collés : ≥ ~5 cubes (3 m) entre
# troncs, même entre cellules voisines. 16 depuis l'agrandissement des arbres
# (canopées ~12 m : mêmes probabilités par cellule, forêts plus aérées).
const TREE_CELL := 16

func has_tree(wx: int, wz: int) -> bool:
	# La colonne doit être LE point jitteré de sa cellule...
	var cx := floori(float(wx) / TREE_CELL)
	var cz := floori(float(wz) / TREE_CELL)
	if wx != cx * TREE_CELL + 2 + int(rand01(cx, cz, 21) * (TREE_CELL - 4)) \
			or wz != cz * TREE_CELL + 2 + int(rand01(cx, cz, 22) * (TREE_CELL - 4)):
		return false
	if not can_spawn_flora(wx, wz):
		return false # pas d'arbre dans l'eau ni sur la plage
	# ... et la cellule tirée au sort. Probabilités par CELLULE (12×12 colonnes),
	# calées sur les anciennes densités par colonne (même nombre d'arbres/m²).
	# Pas d'arbres en montagne (roche nue) ni dans le désert.
	var chance := 0.0
	match get_biome(wx, wz):
		Biome.FOREST:
			chance = 0.45
		Biome.PLAINS:
			chance = 0.12
		Biome.SNOW:
			chance = 0.22
	return rand01(cx, cz, 23) < chance

# Petite décoration posée sur le bloc (herbe, fleur, cactus, rocher... et au
# fond de la mer : coraux, roches aquatiques).
# Renvoie {} s'il n'y a rien, sinon {"size": Vector3, "color": Color}.
func get_decoration(wx: int, wz: int) -> Dictionary:
	var r := rand01(wx, wz, 7)
	if get_biome(wx, wz) == Biome.OCEAN:
		# Fond marin : uniquement là où c'est assez profond pour que la déco
		# reste entièrement sous l'eau (2 cubes sous la surface).
		if float(get_height(wx, wz)) + 0.5 > WATER_Y - 2.0:
			return {}
		if r < 0.012:
			# Corail : colonne fine et colorée, hauteur variée.
			var cols := [Color(0.95, 0.35, 0.50), Color(1.0, 0.55, 0.25),
				Color(0.70, 0.35, 0.85), Color(0.25, 0.85, 0.80)]
			var hgt := 0.35 + rand01(wx, wz, 11) * 0.55
			return {"size": Vector3(0.22, hgt, 0.22),
				"color": cols[int(rand01(wx, wz, 13) * cols.size()) % cols.size()]}
		elif r < 0.019:
			# Roche aquatique : bloc trapu gris-bleu.
			var s := 0.35 + rand01(wx, wz, 11) * 0.35
			return {"size": Vector3(s, s * 0.7, s), "color": Color(0.33, 0.40, 0.46)}
		return {}
	if _river_dist(wx, wz) < RIVER_BANK_W \
			and float(get_height(wx, wz)) + 0.5 <= WATER_Y - 2.0:
		# Lit du fleuve (assez profond pour que la déco reste sous l'eau) :
		# plantes aquatiques ondulant vers la surface et pierres de rivière.
		if r < 0.022:
			var hgt := 0.35 + rand01(wx, wz, 11) * 0.55
			return {"size": Vector3(0.14, hgt, 0.14), "color": Color(0.16, 0.52, 0.30)} # plante
		elif r < 0.032:
			var s := 0.3 + rand01(wx, wz, 11) * 0.3
			return {"size": Vector3(s, s * 0.65, s), "color": Color(0.44, 0.46, 0.49)} # pierre
		return {}
	if not can_spawn_flora(wx, wz):
		return {} # rien dans l'eau ni sur la plage
	if has_tree(wx, wz):
		return {} # jamais de déco sous un arbre
	# Mêmes probabilités par colonne divisées par 4 que has_tree (densité monde).
	match get_biome(wx, wz):
		Biome.PLAINS:
			if r < 0.012:
				return {"size": Vector3(0.12, 0.3, 0.12), "color": Color(0.45, 0.72, 0.30)} # touffe d'herbe
			elif r < 0.017:
				var cols := [Color(0.95, 0.30, 0.30), Color(0.98, 0.85, 0.30), Color(0.95, 0.95, 0.95), Color(0.90, 0.50, 0.80)]
				return {"size": Vector3(0.16, 0.16, 0.16), "color": cols[int(rand01(wx, wz, 11) * cols.size()) % cols.size()]} # fleur
		Biome.FOREST:
			if r < 0.023:
				return {"size": Vector3(0.12, 0.28, 0.12), "color": Color(0.30, 0.55, 0.25)}
		Biome.DESERT:
			if r < 0.003:
				return {"size": Vector3(0.3, 1.0 + rand01(wx, wz, 11) * 0.7, 0.3), "color": Color(0.28, 0.55, 0.30)} # cactus
		Biome.MOUNTAINS:
			if r < 0.005:
				return {"size": Vector3(0.4, 0.35, 0.4), "color": Color(0.45, 0.45, 0.48)} # rocher
		Biome.SNOW:
			if r < 0.003:
				return {"size": Vector3(0.4, 0.35, 0.4), "color": Color(0.60, 0.62, 0.66)}
	return {}

# Pseudo-aléatoire déterministe dans [0, 1) à partir de (a, b), du seed et
# d'un sel optionnel (pour tirer plusieurs valeurs indépendantes au même point).
func rand01(a: int, b: int, salt: int = 0) -> float:
	var h := a * 73856093
	h ^= b * 19349663
	h ^= (world_seed + salt * 977) * 83492791
	h = absi(h)
	return float(h % 1000000) / 1000000.0
