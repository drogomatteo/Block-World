shader_type spatial;
uniform sampler2DArray tiles : source_color, filter_nearest;
varying flat float layer;

void vertex() {
	layer = CUSTOM0.x;
}

void fragment() {
	ALBEDO = texture(tiles, vec3(fract(UV), layer)).rgb;
}
