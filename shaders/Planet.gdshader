// Planet surface shader.
// Replaces the default hard Lambertian terminator with a physically motivated
// soft penumbra.  The transition width is set by sun_angular_size, which the
// Planet script computes as  sun_radius / orbit_distance.  A planet close to
// the sun sees a large sun disc and gets a wide twilight band; a distant planet
// sees a small disc and gets a sharp day/night line.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back;

// Half-angle of the sun disc as seen from this planet's orbit.
// Set by Planet.gd: sun_radius / orbit_distance.
uniform float sun_angular_size : hint_range(0.001, 1.0) = 0.1;

// Read vertex colour in the vertex stage and pass it as a varying so the
// fragment stage receives it correctly regardless of render pipeline.
varying vec3 tile_color;

void vertex() {
	tile_color = COLOR.rgb;
}

void fragment() {
	ALBEDO    = tile_color;
	ROUGHNESS = 1.0;
	METALLIC  = 0.0;
	SPECULAR  = 0.0;
}

void light() {
	// Smooth the terminator over ±sun_angular_size around the geometric limb.
	// At the exact limb (n_dot_l = 0) the surface receives half illumination.
	float n_dot_l = dot(NORMAL, LIGHT);
	float lit = smoothstep(-sun_angular_size, sun_angular_size, n_dot_l);
	DIFFUSE_LIGHT += tile_color * LIGHT_COLOR * ATTENUATION * lit;
}
