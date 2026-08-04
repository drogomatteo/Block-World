class_name TerrainHeight
# Hauteur du terrain avec deux optimisations :
# - up-sampling : le bruit n'est échantillonné que tous les NOISE_STEP blocs,
#   les colonnes intermédiaires sont interpolées bilinéairement ;
# - cache : les échantillons sont mémorisés dans un cache statique partagé
#   par tous les chunks (les voisins retombent sur les mêmes points).
# Le résultat reste une fonction pure de (seed, gx, gz) : deux chunks qui
# évaluent la même colonne obtiennent toujours la même hauteur.

const STEP : int = WorldConfig.NOISE_STEP

static var _cache : Dictionary = {}
static var _cache_seed : int = 0
static var _cache_ready : bool = false

static func height_at(noise : FastNoiseLite, gx : int, gz : int) -> int:
	return int(remap(noise_at(noise, gx, gz), -1.0, 1.0, WorldConfig.MIN_H, WorldConfig.MAX_H))

static func noise_at(noise : FastNoiseLite, gx : int, gz : int) -> float:
	var cx := floori(float(gx) / STEP)
	var cz := floori(float(gz) / STEP)
	var tx := float(gx - cx * STEP) / STEP
	var tz := float(gz - cz * STEP) / STEP
	return lerpf(
		lerpf(_sample(noise, cx, cz), _sample(noise, cx + 1, cz), tx),
		lerpf(_sample(noise, cx, cz + 1), _sample(noise, cx + 1, cz + 1), tx),
		tz
	)

static func _sample(noise : FastNoiseLite, cx : int, cz : int) -> float:
	if not _cache_ready or noise.seed != _cache_seed:
		_cache.clear()
		_cache_seed = noise.seed
		_cache_ready = true
	var key := Vector2i(cx, cz)
	var value = _cache.get(key)
	if value == null:
		value = noise.get_noise_2d(cx * STEP, cz * STEP)
		_cache[key] = value
	return value
