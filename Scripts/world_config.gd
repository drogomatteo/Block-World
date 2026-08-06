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

# Océan : le plan d'eau global (main.tscn/water.gdshader) affleure juste au
# dessus de la face supérieure des colonnes de hauteur SEA_LEVEL - 1 ; une
# colonne de hauteur >= SEA_LEVEL émerge.
const SEA_LEVEL : int = 10
# Montagnes : altitude où la terre laisse place à la neige et aux glaciers
# (ligne jitterée par bruit dans BiomeMap.strata)
const SNOW_LINE : int = 45

# Up-sampling du bruit : 1 échantillon tous les NOISE_STEP blocs,
# interpolation bilinéaire entre les points (voir TerrainHeight)
const NOISE_STEP : int = 4

# Arbres : rares mais massifs — troncs hauts, large couronne étagée
const TREE_CHANCE : float = 0.008
const TRUNK_MIN : int = 6
const TRUNK_MAX : int = 10
const LEAF_RADIUS : int = 3
# marge = rayon max du feuillage + 1 pour l'anneau de culling des faces
const TREE_MARGIN : int = LEAF_RADIUS + 1
