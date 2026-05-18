shader_type spatial;
// depth_draw_opaque: writes depth even while alpha-fading so the atmosphere
// sphere never bleeds through the planet interior.
render_mode blend_mix, depth_draw_opaque, cull_back;

uniform float fade_end : hint_range(0.05, 0.6) = 0.22;

// Read vertex colour in the vertex stage and pass it as a varying so that
// the fragment stage receives it correctly regardless of render pipeline.
varying vec3 tile_color;

void vertex() {
	tile_color = COLOR.rgb;
}

void fragment() {
	float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	ALBEDO    = tile_color;
	ROUGHNESS = 0.85;
	ALPHA     = smoothstep(0.0, fade_end, facing);
}
