shader_type spatial;
render_mode unshaded;
// Matériau des chunks, chemin VERTEX PULLING : le nœud porte un maillage
// « compteur » partagé (sommets à zéro), et ce vertex shader reconstruit
// chaque rectangle du greedy mesher depuis une texture de données
// (2 texels RGBA8 = 8 octets par rectangle, cf. ChunkMesher.build_packed).
// VERTEX_ID = index dans le maillage compteur : VERTEX_ID >> 2 donne le
// rectangle, VERTEX_ID & 3 le coin. Le fragment (chunk_common) est identique
// au chemin classique : on produit les mêmes COLOR / UV.x / NORMAL.

#include "res://Ressource/Shaders/chunk_common.gdshaderinc"

uniform sampler2D rect_data : filter_nearest, repeat_disable;
uniform uint quad_count = 0u;
uniform float cell_size = 1.0;  // CUBE_SIZE * pas de LOD

// Copies conformes des tables du mesher (ordre des directions : UP, DOWN,
// LEFT, RIGHT, FORWARD, BACK).
const vec3 DIRS[6] = vec3[](
	vec3(0.0, 1.0, 0.0), vec3(0.0, -1.0, 0.0), vec3(-1.0, 0.0, 0.0),
	vec3(1.0, 0.0, 0.0), vec3(0.0, 0.0, -1.0), vec3(0.0, 0.0, 1.0));
const float FACE_SHADE[6] = float[](1.0, 0.5, 0.6, 0.6, 0.8, 0.8);
const float AO_LIGHT[4] = float[](1.0, 0.75, 0.55, 0.4);
// Couleurs de BLOCKS par id (0 inutilisé) : dessus/dessous puis flancs.
// Copie conforme de ChunkMesher.BLOCKS — tenir les deux synchronisées.
const vec3 COLOR_TOP[9] = vec3[](
	vec3(0.0), vec3(0.137, 0.902, 0.137), vec3(0.42, 0.27, 0.11), vec3(0.10, 0.55, 0.12),
	vec3(0.76, 0.60, 0.30), vec3(0.32, 0.20, 0.10), vec3(0.42, 0.42, 0.45),
	vec3(0.92, 0.94, 0.97), vec3(0.60, 0.80, 0.97));
const vec3 COLOR_SIDE[9] = vec3[](
	vec3(0.0), vec3(0.137, 0.902, 0.137), vec3(0.48, 0.31, 0.14), vec3(0.10, 0.55, 0.12),
	vec3(0.70, 0.54, 0.26), vec3(0.30, 0.18, 0.09), vec3(0.38, 0.38, 0.41),
	vec3(0.86, 0.88, 0.92), vec3(0.52, 0.72, 0.92));
// FACE_CORNERS : signes des 4 coins de chaque direction (-1 = bord min du
// rectangle sur l'axe, +1 = bord max), même winding horaire que le mesher.
const vec3 CORNERS[24] = vec3[](
	vec3(-1.0, 1.0, -1.0), vec3(1.0, 1.0, -1.0), vec3(1.0, 1.0, 1.0), vec3(-1.0, 1.0, 1.0),      // UP
	vec3(-1.0, -1.0, 1.0), vec3(1.0, -1.0, 1.0), vec3(1.0, -1.0, -1.0), vec3(-1.0, -1.0, -1.0),  // DOWN
	vec3(-1.0, -1.0, -1.0), vec3(-1.0, 1.0, -1.0), vec3(-1.0, 1.0, 1.0), vec3(-1.0, -1.0, 1.0),  // LEFT
	vec3(1.0, -1.0, 1.0), vec3(1.0, 1.0, 1.0), vec3(1.0, 1.0, -1.0), vec3(1.0, -1.0, -1.0),      // RIGHT
	vec3(-1.0, -1.0, -1.0), vec3(1.0, -1.0, -1.0), vec3(1.0, 1.0, -1.0), vec3(-1.0, 1.0, -1.0),  // FORWARD
	vec3(-1.0, 1.0, 1.0), vec3(1.0, 1.0, 1.0), vec3(1.0, -1.0, 1.0), vec3(-1.0, -1.0, 1.0));     // BACK

void vertex() {
	uint qid = uint(VERTEX_ID) >> 2u;
	uint corner = uint(VERTEX_ID) & 3u;
	if (qid >= quad_count) {
		// remplissage du maillage compteur au-delà des rectangles du chunk :
		// quad dégénéré (aire nulle), jamais rasterisé
		VERTEX = vec3(0.0);
		NORMAL = vec3(0.0, 1.0, 0.0);
		COLOR = vec4(0.0);
		UV = vec2(1.0, 0.0);
	} else {
		int t = int(qid) * 2;
		ivec2 tc = ivec2(t % 512, t / 512);
		uvec4 b0v = uvec4(round(texelFetch(rect_data, tc, 0) * 255.0));
		uvec4 b1v = uvec4(round(texelFetch(rect_data, ivec2(tc.x + 1, tc.y), 0) * 255.0));
		uint w0 = b0v.r | (b0v.g << 8u) | (b0v.b << 16u) | (b0v.a << 24u);
		uint w1 = b1v.r | (b1v.g << 8u) | (b1v.b << 16u) | (b1v.a << 24u);
		uint d = w0 & 7u;
		uint flip = (w0 >> 3u) & 1u;
		uint id = (w0 >> 4u) & 15u;
		uint ao = (w0 >> 8u) & 255u;
		float level = float((w0 >> 16u) & 255u);
		float b0 = float((w0 >> 24u) & 31u);
		float r0 = float(w1 & 255u);
		float h = float(((w1 >> 8u) & 31u) + 1u);
		float w = float(((w1 >> 13u) & 255u) + 1u);

		// anisotropie : la diagonale du maillage compteur est fixe (0-2) ;
		// faire tourner l'anneau des coins d'un cran équivaut au flip du
		// mesher classique (ordre cyclique donc winding préservés)
		if (flip == 1u) {
			corner = (corner + 1u) & 3u;
		}

		// reconstruction du rectangle : même arithmétique que _emit_quad
		float fp = (d == 0u || d == 3u || d == 5u) ? level + 0.5 : level - 0.5;
		float bmin = b0 - 0.5;
		float bmax = b0 + h - 0.5;
		float rmin = r0 - 0.5;
		float rmax = r0 + w - 0.5;
		vec3 pmin;
		vec3 pmax;
		if (d < 2u) {         // bits = x, rangées = z
			pmin = vec3(bmin, fp, rmin);
			pmax = vec3(bmax, fp, rmax);
		} else if (d < 4u) {  // bits = z, rangées = y
			pmin = vec3(fp, rmin, bmin);
			pmax = vec3(fp, rmax, bmax);
		} else {              // bits = x, rangées = y
			pmin = vec3(bmin, rmin, fp);
			pmax = vec3(bmax, rmax, fp);
		}
		vec3 sgn = CORNERS[int(d) * 4 + int(corner)];
		VERTEX = mix(pmin, pmax, step(0.0, sgn)) * cell_size;
		NORMAL = DIRS[d];
		vec3 albedo = (d < 2u) ? COLOR_TOP[id] : COLOR_SIDE[id];
		COLOR = vec4(albedo * FACE_SHADE[d], float(id) / 255.0);
		UV = vec2(AO_LIGHT[(ao >> (corner * 2u)) & 3u], 0.0);
	}
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}
