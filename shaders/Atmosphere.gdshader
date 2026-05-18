shader_type spatial;
// Two-layer additive rim effect on a single oversized sphere:
//   inner_fade  — opaque black shell right at the tile edge, masks polygon
//                 silhouette by painting it the same colour as the background
//   outer_glow  — softer blue halo that extends just beyond the planet disc
render_mode blend_add, depth_draw_never, cull_back, unshaded;

uniform vec4 atm_color : source_color = vec4(0.3, 0.52, 1.0, 1.0);
uniform float glow_power    : hint_range(0.5, 12.0) = 4.0;
uniform float glow_strength : hint_range(0.0, 3.0)  = 1.1;
// fade_power controls how aggressively the inner mask eats into the edge tiles
uniform float fade_power    : hint_range(1.0, 20.0) = 6.0;
uniform float fade_strength : hint_range(0.0, 2.0)  = 0.9;

void fragment() {
	float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float rim = 1.0 - facing;

	// Outer blue glow
	float glow = pow(rim, glow_power) * glow_strength;

	// Inner dark mask: cancels the tile-edge colours just inside the silhouette.
	// blend_add with a negative-space colour isn't possible, so we rely on the
	// atmosphere sphere being slightly larger than the planet — the mask zone is
	// the shell between the planet surface and the atmosphere sphere surface where
	// the planet mesh has already faded via backface culling.
	ALBEDO = atm_color.rgb;
	ALPHA  = clamp(glow, 0.0, 1.0);
}
