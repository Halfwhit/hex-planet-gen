shader_type spatial;
// Paints the scene background colour over the polygon edges right at the
// sphere silhouette, so they don't visibly "float" past the round horizon.
// Sits just outside the planet surface; depth test keeps it invisible over
// the face-on tiles and only reveals it where the tiles go edge-on.
render_mode blend_mix, depth_draw_never, cull_back, unshaded;

uniform vec4 mask_color   : source_color  = vec4(0.467, 0.467, 0.467, 1.0);
uniform float mask_power  : hint_range(2.0, 20.0) = 10.0;
uniform float mask_strength : hint_range(0.0, 2.0) = 1.0;

void fragment() {
	float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float rim = pow(1.0 - facing, mask_power) * mask_strength;
	ALBEDO = mask_color.rgb;
	ALPHA  = clamp(rim, 0.0, 1.0);
}
