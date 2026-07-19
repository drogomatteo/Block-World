class_name DayNight
extends Node

# Cycle jour/nuit : anime l'élévation du soleil, la couleur/énergie de la
# lumière, le ciel et le brouillard. Tout dérive de time_of_day (0..1) :
# 0.0 = minuit, 0.25 = aube, 0.5 = midi, 0.75 = crépuscule.
#
# Le ciel est un shader maison (créé ici, il REMPLACE le ProceduralSky de
# world.tscn au lancement) : dégradé animé, nuages en bruit fbm qui dérivent,
# étoiles la nuit, et disque du soleil/lune dessiné à partir de LIGHT0 — donc
# toujours aligné avec la DirectionalLight.
#
# La nuit, la MÊME DirectionalLight fait office de lune (froide, faible) et
# l'ambiance passe par un clair de lune diffus (ambient_light_color animée) :
# le monde reste lisible sans lumière supplémentaire.

const SUN_DAY := Color(1.0, 0.96, 0.88)
const SUN_LOW := Color(1.0, 0.60, 0.32)   # lever / coucher
const MOON := Color(0.60, 0.68, 0.92)

const SKY_TOP_DAY := Color(0.24, 0.42, 0.72)
const SKY_TOP_NIGHT := Color(0.015, 0.02, 0.06)
const HORIZON_DAY := Color(0.78, 0.84, 0.90)
const HORIZON_NIGHT := Color(0.06, 0.08, 0.14)
const HORIZON_GLOW := Color(0.98, 0.55, 0.32) # lueur d'aube/crépuscule
const GROUND_DAY := Color(0.32, 0.36, 0.42)
const GROUND_NIGHT := Color(0.03, 0.04, 0.07)
const FOG_DAY := Color(0.80, 0.85, 0.92)
const FOG_NIGHT := Color(0.05, 0.06, 0.11)
const CLOUD_DAY := Color(0.98, 0.98, 1.0)
const CLOUD_DAY_SHADE := Color(0.68, 0.73, 0.84)
const CLOUD_NIGHT := Color(0.10, 0.12, 0.20)
const CLOUD_NIGHT_SHADE := Color(0.05, 0.06, 0.11)
const AMBIENT_DAY := Color(0.50, 0.55, 0.63)
const AMBIENT_NIGHT := Color(0.12, 0.15, 0.24) # clair de lune diffus

# Caméra sous l'eau : brouillard dense bleu-vert (assombri la nuit), teinte
# bleutée de l'ambiance. Piloté par world.gd via `underwater`.
const UNDERWATER_FOG := Color(0.10, 0.26, 0.35)
const UNDERWATER_FOG_DENSITY := 0.18
const UNDERWATER_AMBIENT_TINT := Color(0.55, 0.80, 1.0)

const SKY_SHADER := """
shader_type sky;

uniform vec3 top_color : source_color = vec3(0.24, 0.42, 0.72);
uniform vec3 horizon_color : source_color = vec3(0.78, 0.84, 0.90);
uniform vec3 ground_color : source_color = vec3(0.32, 0.36, 0.42);
uniform vec3 cloud_light : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3 cloud_shade : source_color = vec3(0.68, 0.73, 0.84);
uniform float cloud_coverage : hint_range(0.0, 1.0) = 0.45;
uniform float night : hint_range(0.0, 1.0) = 0.0;

// Hash "sans sinus" (Dave Hoskins) : stable sur GPU, contrairement au
// classique fract(sin(...)*43758.) qui produit des artefacts en grille.
float hash21(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0); // quintique : pas de facettes
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += vnoise(p) * a;
		p = p * 2.13 + vec2(17.3, 9.1);
		a *= 0.5;
	}
	return v;
}

void sky() {
	vec3 dir = EYEDIR;
	vec3 col;
	if (dir.y < 0.0) {
		col = mix(horizon_color, ground_color, clamp(-dir.y * 2.5, 0.0, 1.0));
	} else {
		col = mix(horizon_color, top_color, pow(clamp(dir.y, 0.0, 1.0), 0.55));

		// Disque du soleil (jour) / de la lune (nuit) : suit la DirectionalLight.
		float sundot = max(dot(dir, LIGHT0_DIRECTION), 0.0);
		col += LIGHT0_COLOR * LIGHT0_ENERGY * (pow(sundot, 1200.0) * 6.0 + pow(sundot, 80.0) * 0.25);

		// Étoiles la nuit (grille de hash sur les coordonnées sphériques).
		vec2 sc = vec2(atan(dir.x, dir.z), acos(clamp(dir.y, -1.0, 1.0)));
		float star = step(0.9992, hash21(floor(sc * vec2(500.0, 300.0))));
		col += vec3(0.9) * star * night * smoothstep(0.03, 0.2, dir.y);

		// Nuages : fbm projeté sur un plan, dérive lente. Dessinés en dernier :
		// ils couvrent soleil/lune et étoiles. Le seuil est calibré sur la
		// distribution réelle du fbm (médiane ~0.30, q90 ~0.61) : coverage 0.45
		// couvre environ 30 % du ciel.
		vec2 uv = dir.xz / (dir.y + 0.12);
		uv = uv * 0.6 + vec2(TIME * 0.008, TIME * 0.003);
		float f = fbm(uv);
		float edge = 0.62 - 0.55 * cloud_coverage;
		float cl = smoothstep(edge, edge + 0.25, f) * smoothstep(0.02, 0.18, dir.y);
		float shade = fbm(uv * 1.8 + vec2(3.7, 1.3));
		vec3 ccol = mix(cloud_shade, cloud_light, clamp(shade + 0.3, 0.0, 1.0));
		col = mix(col, ccol, cl * 0.9);
	}
	COLOR = col;
}
"""

var sun: DirectionalLight3D
var environment: Environment
var day_length := 900.0   # durée d'un cycle complet, en secondes
var time_of_day := 0.32   # on démarre en matinée
var underwater := false   # posé par world.gd quand la caméra est immergée

var _sky_mat: ShaderMaterial
var _base_fog_density := 0.0035
var _base_fog_sky_affect := 0.2

func _ready() -> void:
	if environment != null:
		_base_fog_density = environment.fog_density
		_base_fog_sky_affect = environment.fog_sky_affect
		var sh := Shader.new()
		sh.code = SKY_SHADER
		_sky_mat = ShaderMaterial.new()
		_sky_mat.shader = sh
		var sky := Sky.new()
		sky.sky_material = _sky_mat
		environment.sky = sky
		# Ambiance pilotée à la main plutôt que dérivée du ciel : la nuit on
		# garde un clair de lune diffus au lieu d'un noir complet.
		environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		environment.ambient_light_energy = 1.0
	_apply()

func _process(delta: float) -> void:
	time_of_day = fposmod(time_of_day + delta / maxf(day_length, 1.0), 1.0)
	_apply()

func _apply() -> void:
	# Hauteur du soleil : +1 à midi, -1 à minuit.
	var sun_h := sin((time_of_day - 0.25) * TAU)
	# 0 = nuit, 1 = plein jour ; transition douce autour de l'horizon.
	var day := clampf(inverse_lerp(-0.08, 0.25, sun_h), 0.0, 1.0)
	# Lueur chaude maximale quand le soleil frôle l'horizon.
	var glow := clampf(1.0 - absf(sun_h) * 3.0, 0.0, 1.0)

	if sun != null:
		# Le jour la lumière suit le soleil, la nuit elle rejoue la trajectoire
		# en lune ; élévation plancher pour éviter une lumière rasante instable.
		var elev := asin(clampf(absf(sun_h), 0.0, 1.0))
		sun.rotation = Vector3(-maxf(elev, 0.06), deg_to_rad(-30.0), 0.0)
		sun.light_energy = lerpf(0.30, 1.25, day)
		sun.light_color = MOON.lerp(SUN_DAY.lerp(SUN_LOW, glow), day)

	if _sky_mat != null:
		_sky_mat.set_shader_parameter("top_color", SKY_TOP_NIGHT.lerp(SKY_TOP_DAY, day))
		var horizon := HORIZON_NIGHT.lerp(HORIZON_DAY, day).lerp(HORIZON_GLOW, glow * 0.8)
		_sky_mat.set_shader_parameter("horizon_color", horizon)
		_sky_mat.set_shader_parameter("ground_color", GROUND_NIGHT.lerp(GROUND_DAY, day))
		_sky_mat.set_shader_parameter("cloud_light",
			CLOUD_NIGHT.lerp(CLOUD_DAY.lerp(HORIZON_GLOW, glow * 0.6), day))
		_sky_mat.set_shader_parameter("cloud_shade", CLOUD_NIGHT_SHADE.lerp(CLOUD_DAY_SHADE, day))
		_sky_mat.set_shader_parameter("night", 1.0 - day)

	if environment != null:
		if underwater:
			environment.fog_light_color = UNDERWATER_FOG.darkened(1.0 - (0.25 + 0.75 * day))
			environment.fog_density = UNDERWATER_FOG_DENSITY
			environment.fog_sky_affect = 1.0 # le ciel aussi est voilé vu de sous l'eau
			environment.ambient_light_color = AMBIENT_NIGHT.lerp(AMBIENT_DAY, day) * UNDERWATER_AMBIENT_TINT
		else:
			environment.fog_light_color = FOG_NIGHT.lerp(FOG_DAY, day).lerp(HORIZON_GLOW, glow * 0.35)
			environment.fog_density = _base_fog_density
			environment.fog_sky_affect = _base_fog_sky_affect
			environment.ambient_light_color = AMBIENT_NIGHT.lerp(AMBIENT_DAY, day)
