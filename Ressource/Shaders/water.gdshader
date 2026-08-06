shader_type spatial;
render_mode blend_mix, cull_disabled, unshaded;
// Surface de l'océan : un grand plan unique à y = SEA_LEVEL (main.tscn,
// recentré sur la caméra par main.gd — le motif est en coordonnées MONDE,
// le glissement du plan est donc invisible). L'eau n'existe pas dans les
// voxels : le terrain sous le niveau de la mer est simplement recouvert.
// cull_disabled : visible aussi par en dessous. Le fog s'applique (unshaded).

uniform vec3 shallow_color : source_color = vec3(0.13, 0.55, 0.64);
uniform vec3 deep_color : source_color = vec3(0.02, 0.18, 0.38);
uniform float base_alpha : hint_range(0.0, 1.0) = 0.72;
uniform float wave_scale = 0.045;   // fréquence des vaguelettes (1/blocs)
uniform float wave_speed = 0.35;
uniform float wave_strength : hint_range(0.0, 1.0) = 0.45;

varying vec3 water_world_pos;

// Même famille de hash/bruit entier que chunk_common (exact loin de l'origine).
float w_hash(vec2 cell) {
	uvec2 q = uvec2(ivec2(cell)) * uvec2(1597334673u, 3812015801u);
	uint n = (q.x ^ q.y) * 1597334673u;
	return float(n) * (1.0 / 4294967295.0);
}

float w_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = p - i;
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(w_hash(i), w_hash(i + vec2(1.0, 0.0)), u.x),
		mix(w_hash(i + vec2(0.0, 1.0)), w_hash(i + vec2(1.0, 1.0)), u.x),
		u.y);
}

void vertex() {
	water_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// deux nappes de bruit qui défilent en sens contraires -> vaguelettes
	vec2 p = water_world_pos.xz * wave_scale;
	float t = TIME * wave_speed;
	float n = w_noise(p + vec2(t, t * 0.6)) * 0.6
		+ w_noise(p * 2.3 - vec2(t * 0.8, t * 0.5)) * 0.4;
	float crest = smoothstep(0.35, 0.75, n);

	// plus opaque et plus sombre au rasant (faux fresnel), crêtes claires
	float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
	vec3 col = mix(deep_color, shallow_color, facing * 0.7 + crest * 0.3);
	col += vec3(0.10, 0.12, 0.12) * crest * wave_strength;
	ALBEDO = col;
	ALPHA = clamp(base_alpha + (1.0 - facing) * 0.22, 0.0, 0.97);
}
