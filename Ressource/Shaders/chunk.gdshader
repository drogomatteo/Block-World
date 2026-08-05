shader_type spatial;
render_mode unshaded;
// Matériau des chunks, chemin maillage classique (ArrayMesh du mesher) : les
// couleurs/UV viennent des attributs de sommet. Toute l'apparence (teinte
// d'herbe par position monde, AO, bordures F3) vit dans chunk_common — elle
// est partagée à l'identique avec le chemin vertex pulling.

#include "res://Ressource/Shaders/chunk_common.gdshaderinc"

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}
