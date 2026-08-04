class_name WorldConfig
# Paramètres du monde partagés par tous les modules de génération
# (chunk, terrain, arbres). Aucune logique ici : uniquement des constantes.

const WIDTH : int = 32
const HEIGHT : int = 256
const DEPTH : int = 32
const CUBE_SIZE : float = 1.0

# Relief : bornes de hauteur du terrain
const MIN_H : int = 4
const MAX_H : int = 12

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
