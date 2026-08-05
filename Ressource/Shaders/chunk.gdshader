shader_type spatial;
render_mode unshaded;
// Matériau des chunks : reproduit l'ancien StandardMaterial3D (couleurs de
// sommet en albédo, non éclairé) et ajoute la teinte de l'herbe par position
// monde. La géométrie (rectangles fusionnés par le binary greedy mesher)
// reste intacte : chaque pixel retrouve le bloc du monde auquel il appartient
// et en déduit sa teinte, fonction pure de la position -> aucune couture entre
// rectangles ni entre chunks. L'id du bloc est encodé dans le canal alpha des
// couleurs de sommet (id / 255) ; seule l'herbe (id 1) est teintée.

const int GRASS_ID = 1;

uniform float block_size = 1.0;  // WorldConfig.CUBE_SIZE
uniform float tint_amount : hint_range(0.0, 1.0) = 1.0;   // 0 = couleur du maillage
uniform float patch_size = 24.0;                          // taille des taches, en blocs
uniform float block_jitter : hint_range(0.0, 1.0) = 0.3;  // variation par bloc
uniform vec3 grass_dry : source_color = vec3(0.55, 0.75, 0.22);   // herbe sèche
uniform vec3 grass_lush : source_color = vec3(0.13, 0.80, 0.25);  // herbe grasse
uniform float ao_strength : hint_range(0.0, 1.0) = 1.0;  // ambient occlusion

// Débug F3 : peint les frontières de chunks (lignes au sol, murs entiers pour
// les faces posées exactement sur le plan frontière).
uniform bool show_chunk_borders = false;
uniform float chunk_span = 32.0;  // WorldConfig.WIDTH * CUBE_SIZE
uniform vec3 border_color : source_color = vec3(1.0, 0.15, 0.1);

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

// Hash entier -> [0, 1[, exact sur les coordonnées de blocs même loin de
// l'origine (les hash à base de sin() se dégradent au-delà de ~10 000).
float cell_hash(vec2 cell) {
	uvec2 q = uvec2(ivec2(cell)) * uvec2(1597334673u, 3812015801u);
	uint n = (q.x ^ q.y) * 1597334673u;
	return float(n) * (1.0 / 4294967295.0);
}

// Bruit de valeur lisse : hash aux coins de la grille + interpolation.
float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = p - i;
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(cell_hash(i), cell_hash(i + vec2(1.0, 0.0)), u.x),
		mix(cell_hash(i + vec2(0.0, 1.0)), cell_hash(i + vec2(1.0, 1.0)), u.x),
		u.y);
}

void fragment() {
	vec3 albedo = COLOR.rgb;
	int block_id = int(round(COLOR.a * 255.0));
	if (block_id == GRASS_ID) {
		// Centre du bloc : un demi-bloc vers l'intérieur depuis la face, puis
		// arrondi à la grille -> teinte plate par bloc, sans clignotement aux
		// frontières. cell.xz seul : les flancs d'une colonne suivent son dessus.
		vec3 cell = floor(world_pos / block_size - world_normal * 0.5 + 0.5);
		float patches = value_noise(cell.xz / patch_size);
		float jitter = (cell_hash(cell.xz) - 0.5) * block_jitter;
		float v = clamp(patches + jitter, 0.0, 1.0);
		// La couleur de l'herbe est REMPLACÉE (un multiplicateur ne pourrait
		// pas jaunir un vert saturé) ; l'ombrage par face, cuit dans la
		// couleur de sommet, est reconstruit depuis la normale (= FACE_SHADE).
		float shade = world_normal.y > 0.5 ? 1.0
			: (world_normal.y < -0.5 ? 0.5
			: (abs(world_normal.x) > 0.5 ? 0.6 : 0.8));
		vec3 grass = mix(grass_dry, grass_lush, v) * shade;
		albedo = mix(albedo, grass, tint_amount);
	}
	// AO voxel : facteur de lumière du coin dans UV.x, interpolé sur la face
	// par le GPU. Appliquée APRÈS la teinte d'herbe (qui REMPLACE la couleur),
	// pour assombrir tous les blocs uniformément.
	albedo *= mix(1.0, UV.x, ao_strength);
	if (show_chunk_borders) {
		vec2 f = fract(world_pos.xz / chunk_span);
		vec2 dist = min(f, 1.0 - f) * chunk_span;  // distance monde à la frontière
		float d = min(dist.x, dist.y);
		float w = max(0.08, fwidth(d));  // au moins ~1 pixel : pas de scintillement au loin
		albedo = mix(albedo, border_color, (1.0 - smoothstep(0.5 * w, w, d)) * 0.85);
	}
	ALBEDO = albedo;
}
