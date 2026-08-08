class_name WorldConfig
# Paramètres du monde partagés par tous les modules de génération
# (chunk, terrain, arbres). Aucune logique ici : uniquement des constantes.

const WIDTH : int = 32
const HEIGHT : int = 256
const DEPTH : int = 32
const CUBE_SIZE : float = 1.0

# Ids de blocs — table des couleurs/solidité dans ChunkMesher.BLOCKS.
# Déclarés ici (amont de tous les modules) pour que BiomeMap/TreeGen puissent
# les référencer sans dépendre du mesher.
const AIR : int = 0
const GRASS : int = 1
const WOOD : int = 2
const LEAVES : int = 3
const SAND : int = 4
const DIRT : int = 5
const ROCK : int = 6
const SNOW : int = 7
const ICE : int = 8
const LEAVES_DARK : int = 9   # feuillage des sapins
const LEAVES_LIME : int = 10  # variante jaune-vert des feuillus

# Océan : le plan d'eau global (main.tscn/water.gdshader) affleure juste au
# dessus de la face supérieure des colonnes de hauteur SEA_LEVEL - 1 ; une
# colonne de hauteur >= SEA_LEVEL émerge. La mer est HAUTE (40) pour laisser
# ~35 blocs de profondeur aux océans (le fond du monde est à y = 0) — toutes
# les bases terrestres de BiomeMap sont calées au-dessus.
const SEA_LEVEL : int = 40
# Montagnes : altitude où la pierre laisse place à la neige et aux glaciers
# (ligne jitterée par bruit dans BiomeMap.strata) — pics jusqu'à ~165
const SNOW_LINE : int = 100

# Up-sampling du bruit : 1 échantillon tous les NOISE_STEP blocs,
# interpolation bilinéaire entre les points (voir TerrainHeight)
const NOISE_STEP : int = 4

# Arbres (silhouettes façon Cube World : feuillus à dôme, sapins à étages,
# rares géants multi-lobes — voir TreeGen, densités dans CHANCE_BY_BIOME)
# marge = portée horizontale max d'un feuillage (lobe de géant : branche 12
# + rayon de lobe 5) + 1 pour l'anneau de culling des faces
const TREE_MARGIN : int = 18
