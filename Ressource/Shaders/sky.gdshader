shader_type sky;
render_mode use_quarter_res_pass;

// Ciel procédural — port Godot du plugin Bevy « bevy_sky_gradient »
// (github.com/TanTanDev/bevy_sky_gradient). Dégradé vertical à 4 stops dont
// les couleurs sont réécrites chaque frame par sky_cycle.gd selon l'heure ;
// disque solaire aligné sur la DirectionalLight3D (LIGHT0) ; étoiles et
// aurores boréales apparaissent avec night_visibility. L'aurore (raymarching
// à ~60 échantillons) est calculée dans la passe quart de résolution puis
// composée en pleine résolution — l'équivalent de la texture séparée basse
// résolution du plugin d'origine.

// ---- Dégradé (gradient.wgsl) : 4 stops, positions croissantes ------------
// t = EYEDIR.y remappé : 0 = nadir, 0.5 = horizon, 1 = zénith
uniform vec4 stop0_color : source_color = vec4(0.0, 0.004, 0.170, 1.0);
uniform vec4 stop1_color : source_color = vec4(0.064, 0.082, 0.365, 1.0);
uniform vec4 stop2_color : source_color = vec4(0.0, 0.052, 0.419, 1.0);
uniform vec4 stop3_color : source_color = vec4(0.101, 0.0, 0.232, 1.0);
uniform vec4 stop_positions = vec4(0.38, 0.47, 0.61, 1.0);

// ---- Soleil (sun.wgsl) : la direction vient de LIGHT0 --------------------
uniform bool sun_enabled = true;
uniform vec4 sun_color = vec4(1.0, 1.0, 0.5, 1.0);
uniform float sun_strength = 1.5;
uniform float sun_sharpness = 364.0;

// 0 = plein jour, 1 = pleine nuit (smoothstep déjà appliqué par sky_cycle.gd)
uniform float night_visibility = 0.0;

// ---- Étoiles (stars.wgsl) ------------------------------------------------
uniform bool stars_enabled = true;
uniform float stars_rotation_speed = 0.01;
uniform float stars_sample_scale = 9.0;
uniform float stars_threshold = 0.9;
uniform float stars_threshold_blink = 0.01;
uniform float stars_blink_speed = 10.0;
uniform float stars_mask_scale = 1.0;
uniform float stars_mask_threshold = 0.4;
uniform float stars_blink_variance_scale = 0.03;

// ---- Aurore (aurora.wgsl) ------------------------------------------------
uniform bool aurora_enabled = true;
uniform vec4 aurora_bottom_color = vec4(0.0, 1.0, 0.2, 1.0);
uniform vec4 aurora_top_color = vec4(0.0, 1.0, 0.8, 1.0);
uniform float aurora_alpha = 0.7;
uniform float aurora_density = 0.05;
uniform float aurora_sharpness = 1.56;
uniform int aurora_samples = 60;
uniform float aurora_start_height = 3.1;
uniform float aurora_end_height = 4.8;
uniform float aurora_flow_scale = 0.002;
uniform float aurora_flow_strength = 4.3;
uniform float aurora_flow_speed = 0.005;
uniform float aurora_flow_x_speed = -0.6;
uniform float aurora_wiggle_scale = 0.03;
uniform float aurora_wiggle_strength = 1.05;
uniform float aurora_wiggle_speed = 0.1;
uniform vec4 aurora_sparkle_primary = vec4(0.0, 2.3, 0.0, 1.0);
uniform vec4 aurora_sparkle_secondary = vec4(6.3, 0.2, 4.0, 1.0);
uniform float aurora_sparkle_scale = 0.004;
uniform float aurora_sparkle_speed = 0.02;
uniform float aurora_sparkle_threshold = 0.3;
uniform float aurora_sparkle_max_height = 0.3;
uniform float aurora_opacity_per_sample = 0.18;

// Bruits 3D sans couture — équivalents des textures noise3/voronoi3 du plugin
uniform sampler3D noise3_tex : repeat_enable, filter_linear;
uniform sampler3D voronoi3_tex : repeat_enable, filter_linear;

float noise3(vec3 p) {
	return texture(noise3_tex, p).r;
}

float vnoise3(vec3 p) {
	return texture(voronoi3_tex, p).r;
}

// Mixes chaînés = interpolation linéaire par morceaux : sur [p_i, p_i+1] le
// clamp du segment précédent vaut déjà 1, donc col est exactement stop_i.
vec3 sky_gradient(float up_y) {
	float t = clamp(up_y * 0.5 + 0.5, 0.0, 1.0);
	vec3 col = stop0_color.rgb;
	col = mix(col, stop1_color.rgb, clamp((t - stop_positions.x) / max(stop_positions.y - stop_positions.x, 0.0001), 0.0, 1.0));
	col = mix(col, stop2_color.rgb, clamp((t - stop_positions.y) / max(stop_positions.z - stop_positions.y, 0.0001), 0.0, 1.0));
	col = mix(col, stop3_color.rgb, clamp((t - stop_positions.z) / max(stop_positions.w - stop_positions.z, 0.0001), 0.0, 1.0));
	return col;
}

vec3 sun_disc(vec3 dir) {
	float f = pow(max(dot(dir, LIGHT0_DIRECTION), 0.0), sun_sharpness);
	return sun_color.rgb * (f * sun_strength);
}

float star_field(vec3 dir, float t_now) {
	// lente rotation du ciel étoilé
	float rot = t_now * stars_rotation_speed;
	float c = cos(rot);
	float s = sin(rot);
	vec3 d = mat3(vec3(c, -s, 0.0), vec3(s, c, 0.0), vec3(0.0, 0.0, 1.0)) * dir;
	float n = 1.0 - vnoise3(d * stars_sample_scale);
	float mask = noise3(d * stars_mask_scale);
	float variance = noise3(d * stars_blink_variance_scale);
	// le masque éclaircit certaines zones du ciel (densité irrégulière)
	n *= 1.0 - smoothstep(stars_mask_threshold, 1.0, mask);
	// clignotement : vitesse 50 % -> 150 % selon la position
	float speed = 1.0 + sin(variance) * 0.5;
	float blink = cos(t_now * stars_blink_speed * speed + variance);
	return smoothstep(stars_threshold + blink * stars_threshold_blink, 1.0, n);
}

float stripe(float x, float half_size) {
	float v = fract(x);
	return smoothstep(0.5 - half_size, 0.5, v) * smoothstep(0.5 + half_size, 0.5, v);
}

// Rideaux verticaux : le rayon de vue est échantillonné à plusieurs hauteurs
// de « plafond » ; à chaque hauteur, des bandes déformées par deux bruits
// (dérive globale + ondulation locale) s'accumulent comme un volume.
vec4 aurora(vec3 dir, float t_now) {
	if (dir.y < 0.001) {
		return vec4(0.0);
	}
	int samples = max(aurora_samples, 2);
	vec3 acc = vec3(0.0);
	float acc_a = 0.0;
	float flow_time = t_now * aurora_flow_speed;
	float wiggle_time = t_now * aurora_wiggle_speed;
	for (int i = 0; i < samples; i++) {
		float hf = float(i) / float(samples - 1);
		float height = mix(aurora_start_height, aurora_end_height, hf);
		vec2 world_pos = dir.xz * (height / dir.y);
		// dérive globale des bandes
		vec2 s_wp = world_pos * aurora_flow_scale;
		vec2 flow = vec2(noise3(vec3(s_wp, flow_time)), noise3(vec3(s_wp, 0.5 + flow_time)));
		vec2 flow_dir = normalize(flow + vec2(0.0001));
		// ondulation locale, désynchronisée par la position (sinon uniforme)
		vec2 w_wo = world_pos * aurora_wiggle_scale;
		float t_off = w_wo.x + w_wo.y;
		vec2 wiggle = vec2(
			noise3(vec3(w_wo, wiggle_time + t_off)),
			noise3(vec3(w_wo, 0.5 + wiggle_time + t_off))) * aurora_wiggle_strength;
		vec2 warped = world_pos + flow_dir * aurora_flow_strength + wiggle
			+ vec2(aurora_flow_x_speed * t_now);
		// deux familles de bandes (large + fine espacée), fusionnées
		float bands = pow(max(stripe(warped.x * aurora_density, 0.2),
			stripe(warped.x * aurora_density * 1.7, 0.1)), aurora_sharpness);
		// rideau : brillant en bas, fondu en haut
		float vertical = smoothstep(0.0, 0.15, hf) * smoothstep(1.0, 0.5, hf);
		// étincelles colorées au pied du rideau
		float sp_int = 1.0 - smoothstep(0.0, aurora_sparkle_max_height, hf);
		vec2 sn = warped * aurora_sparkle_scale;
		float k = t_now * aurora_sparkle_speed;
		float sp_noise = smoothstep(aurora_sparkle_threshold, 1.0, 1.0 - noise3(vec3(sn + vec2(k), k * 0.3)));
		float sp_col_noise = noise3(vec3(sn * 0.3 + vec2(10.0), 0.0));
		vec3 sp_color = mix(aurora_sparkle_primary.rgb, aurora_sparkle_secondary.rgb,
			smoothstep(0.4, 1.0, sp_col_noise));
		vec3 sparkle = smoothstep(0.5, 1.0, bands) * sp_int * sp_color * sp_noise;
		float curtain = bands * vertical;
		float sample_alpha = curtain * aurora_opacity_per_sample;
		float weight = sample_alpha * (1.0 - acc_a);
		vec3 selected = mix(aurora_bottom_color.rgb, aurora_top_color.rgb, hf);
		acc += selected * curtain * weight + sparkle * vertical * weight;
		acc_a += sample_alpha * (1.0 - acc_a);
		if (acc_a > 0.95) {
			break;
		}
	}
	float up = smoothstep(0.05, 0.7, dir.y);
	return vec4(acc * up * aurora_alpha, acc_a * up * aurora_alpha);
}

void sky() {
	if (AT_QUARTER_RES_PASS) {
		// passe basse résolution : seulement l'aurore
		vec4 a = vec4(0.0);
		if (aurora_enabled && !AT_CUBEMAP_PASS && night_visibility > 0.001) {
			a = aurora(EYEDIR, TIME);
		}
		COLOR = a.rgb;
		ALPHA = a.a;
	} else {
		vec3 col = sky_gradient(EYEDIR.y);
		if (sun_enabled && LIGHT0_ENABLED) {
			// visible la nuit aussi, mais presque éteint (comme full_sky.wgsl)
			col += sun_disc(EYEDIR) * max(1.0 - night_visibility, 0.05);
		}
		if (!AT_CUBEMAP_PASS && night_visibility > 0.001) {
			if (stars_enabled) {
				col += vec3(star_field(EYEDIR, TIME)) * night_visibility;
			}
			if (aurora_enabled) {
				col += QUARTER_RES_COLOR.rgb * night_visibility;
			}
		}
		COLOR = col;
	}
}
