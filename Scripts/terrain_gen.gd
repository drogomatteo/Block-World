class_name TerrainGen
extends RefCounted

# Génération procédurale DÉTERMINISTE : tout dépend uniquement de (world_seed, x, z).
# C'est volontaire — un jour, en multijoueur, il suffira de partager le seed pour que
# tous les joueurs génèrent exactement le même monde sans transférer le terrain.
#
# UNITÉS : tout ici est exprimé en INDICES DE CUBE. Un cube mesure Chunk.CUBE
# (0.5 m) dans le monde : x/z sont des indices de colonne, get_height renvoie
# une hauteur en cubes. Conversion monde -> indice : roundi(w / Chunk.CUBE) ;
# indice -> monde : i * Chunk.CUBE. Les fréquences de bruit sont réglées pour
# des reliefs à la même échelle MONDE qu'avant le raffinement des blocs.

enum Biome { DESERT, PLAINS, FOREST, MOUNTAINS, SNOW }

# Niveau de l'eau, en unités cube (niveau monde = WATER_Y * Chunk.CUBE).
# C'est aussi un seuil de génération : sous l'eau rien ne pousse et les blocs
# deviennent du sable/vase (lit du lac).
const WATER_Y := -1.3

var world_seed: int
var height_noise: FastNoiseLite
var biome_noise: FastNoiseLite

func _init(seed_value: int) -> void:
	world_seed = seed_value

	height_noise = FastNoiseLite.new()
	height_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	height_noise.seed = seed_value
	# 0.02/m d'avant × 0.5 m/cube : mêmes reliefs monde, résolution doublée.
	height_noise.frequency = 0.01
	height_noise.fractal_octaves = 4

	# Un bruit très basse fréquence = grandes zones = biomes cohérents.
	biome_noise = FastNoiseLite.new()
	biome_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	biome_noise.seed = seed_value + 4096
	# 0.0024/m en monde : biomes ~2.5× plus étendus qu'avant.
	biome_noise.frequency = 0.0012

func get_biome(wx: int, wz: int) -> int:
	var v := biome_noise.get_noise_2d(float(wx), float(wz))
	if v < -0.45:
		return Biome.DESERT
	elif v < 0.05:
		return Biome.PLAINS
	elif v < 0.4:
		return Biome.FOREST
	elif v < 0.62:
		return Biome.MOUNTAINS
	return Biome.SNOW

# Hauteur (entière) du sommet de la colonne au point monde (wx, wz).
func get_height(wx: int, wz: int) -> int:
	var n := height_noise.get_noise_2d(float(wx), float(wz))
	# Amplitudes en cubes (doublées lors du raffinement : mêmes hauteurs monde).
	var amp := 10.0
	var base := 0.0
	match get_biome(wx, wz):
		Biome.DESERT:
			amp = 6.0
		Biome.PLAINS:
			amp = 10.0
		Biome.FOREST:
			amp = 14.0
		Biome.MOUNTAINS:
			amp = 40.0
			base = 12.0
		Biome.SNOW:
			amp = 30.0
			base = 18.0
	return roundi(n * amp + base)

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
	var top := float(h) + 0.5
	if top < WATER_Y:
		# Bloc immergé : lit du lac (sable/vase), assombri avec la profondeur.
		var depth := WATER_Y - top # en cubes (0.05/cube = même rendu qu'avant)
		c = Color(0.58, 0.53, 0.38).darkened(clampf(depth * 0.05, 0.0, 0.45))
	elif top < WATER_Y + 1.0 and biome != Biome.DESERT and biome != Biome.SNOW:
		c = Color(0.80, 0.73, 0.52) # plage de sable au bord de l'eau
	if y < h:
		c = c.darkened(0.35)
	elif biome == Biome.MOUNTAINS and y >= 24:
		c = Color(0.92, 0.94, 0.97) # sommets enneigés
	return c

# Seuil d'apparition de la flore : rien ne pousse sous l'eau ni sur la bande
# de plage (le dessus du bloc de surface doit dépasser le niveau de l'eau
# d'au moins un cube — même largeur monde qu'avant le raffinement).
func can_spawn_flora(wx: int, wz: int) -> bool:
	return float(get_height(wx, wz)) + 0.5 >= WATER_Y + 1.0

func has_tree(wx: int, wz: int) -> bool:
	if not can_spawn_flora(wx, wz):
		return false # pas d'arbre dans l'eau ni sur la plage
	# Probabilités par COLONNE : divisées par 4 lors du raffinement des blocs
	# (4× plus de colonnes par m² => même densité d'arbres au sol).
	var chance := 0.0
	match get_biome(wx, wz):
		Biome.FOREST:
			chance = 0.015
		Biome.PLAINS:
			chance = 0.004
		Biome.SNOW:
			chance = 0.008
		Biome.MOUNTAINS:
			chance = 0.004
	return rand01(wx, wz) < chance

# Petite décoration posée sur le bloc (herbe, fleur, cactus, rocher...).
# Renvoie {} s'il n'y a rien, sinon {"size": Vector3, "color": Color}.
func get_decoration(wx: int, wz: int) -> Dictionary:
	if not can_spawn_flora(wx, wz):
		return {} # rien dans l'eau ni sur la plage
	if has_tree(wx, wz):
		return {} # jamais de déco sous un arbre
	# Mêmes probabilités par colonne divisées par 4 que has_tree (densité monde).
	var r := rand01(wx, wz, 7)
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
