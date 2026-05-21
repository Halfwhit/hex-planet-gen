class_name PlanetMesh
extends RefCounted


static func build(planet: HexPlanet, radius: float, highlight_pentagons: bool = false, debug_plates: bool = false) -> ArrayMesh:
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	for cell: Dictionary in planet.cells:
		var center: Vector3 = (cell["position"] as Vector3) * radius
		# Uniform normal per cell so each tile shades as a flat facet.
		var cell_normal: Vector3 = cell["position"] as Vector3
		var poly: PackedVector3Array = cell["polygon"] as PackedVector3Array
		var n: int = poly.size()
		var color: Color
		if debug_plates:
			color = _plate_color(
				cell.get("plate_id", 0) as int,
				cell.get("plate_oceanic", false) as bool,
				planet.num_plates,
			)
		else:
			color = terrain_color(
				cell["height"] as float,
				cell["type"] as int,
				planet.land_threshold,
				highlight_pentagons and cell["pentagon"] as bool,
				cell.get("biome", -1) as int,
			)

		st.set_normal(cell_normal)
		st.set_color(color)
		for i: int in n:
			var p0: Vector3 = poly[i] * radius
			var p1: Vector3 = poly[(i + 1) % n] * radius
			st.add_vertex(center)
			st.add_vertex(p0)
			st.add_vertex(p1)

	var mesh: ArrayMesh = st.commit()

	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mesh.surface_set_material(0, mat)

	return mesh


## Returns the render colour for a cell.
## When biome >= 0 the full biome palette is used; passing biome = -1 falls
## back to the original height-only gradient (kept for any callers that do
## not yet carry biome data).
## Pass highlight_pentagon = true to show the 12 pentagon landmarks in magenta.
static func terrain_color(
		height: float,
		type: int,
		land_threshold: float,
		highlight_pentagon: bool = false,
		biome: int = -1,
) -> Color:
	if highlight_pentagon:
		return Color(0.85, 0.20, 0.55)  # vivid magenta — pentagon landmark

	if biome >= 0:
		return _biome_color(height, type, land_threshold, biome)

	# ── Legacy height-only fallback ───────────────────────────────────────────
	if type == HexPlanet.OCEAN:
		var t: float = clamp((height + 1.0) / (land_threshold + 1.0), 0.0, 1.0)
		return Color(0.04, 0.12, 0.42).lerp(Color(0.18, 0.48, 0.72), t)
	var t: float = clamp((height - land_threshold) / max(1.0 - land_threshold, 0.001), 0.0, 1.0)
	if t < 0.5:
		return Color(0.08, 0.32, 0.08).lerp(Color(0.36, 0.58, 0.18), t / 0.5)
	elif t < 0.8:
		return Color(0.36, 0.58, 0.18).lerp(Color(0.55, 0.50, 0.42), (t - 0.5) / 0.3)
	return Color(0.55, 0.50, 0.42).lerp(Color(0.92, 0.94, 0.96), (t - 0.8) / 0.2)


## Full biome colour palette.
## Each biome lerps between two colours using a height-derived factor
## (ocean: deeper = darker; land: higher = lighter/rockier) so there is
## visible micro-variation within each biome rather than a flat fill.
static func _biome_color(
		height: float,
		type: int,
		land_threshold: float,
		biome: int,
) -> Color:
	# Normalised depth for ocean (0 = sea-level surface, 1 = deepest).
	var od: float = clamp((land_threshold - height) / max(land_threshold + 1.0, 0.001), 0.0, 1.0)
	# Normalised altitude for land (0 = sea level, 1 = highest peak).
	var la: float = clamp((height - land_threshold) / max(1.0 - land_threshold, 0.001), 0.0, 1.0)

	match biome:
		# ── Ocean ─────────────────────────────────────────────────────────
		HexPlanet.BIOME_DEEP_OCEAN:
			return Color(0.03, 0.08, 0.32).lerp(Color(0.08, 0.18, 0.48), 1.0 - od)
		HexPlanet.BIOME_SHALLOW_OCEAN:
			return Color(0.10, 0.30, 0.60).lerp(Color(0.20, 0.50, 0.76), 1.0 - od)
		HexPlanet.BIOME_TROPICAL_OCEAN:
			return Color(0.02, 0.42, 0.60).lerp(Color(0.08, 0.64, 0.78), 1.0 - od)
		HexPlanet.BIOME_ICY_OCEAN:
			return Color(0.50, 0.62, 0.72).lerp(Color(0.68, 0.80, 0.88), 1.0 - od)
		HexPlanet.BIOME_COASTAL_OCEAN:
			return Color(0.18, 0.58, 0.70).lerp(Color(0.28, 0.70, 0.82), 1.0 - od)
		# ── Coastal ───────────────────────────────────────────────────────
		HexPlanet.BIOME_BEACH:
			return Color(0.78, 0.70, 0.46).lerp(Color(0.90, 0.82, 0.60), la)
		# ── Hot zone ──────────────────────────────────────────────────────
		HexPlanet.BIOME_TROPICAL_RAINFOREST:
			return Color(0.04, 0.26, 0.08).lerp(Color(0.10, 0.38, 0.14), la)
		HexPlanet.BIOME_SAVANNA:
			return Color(0.58, 0.50, 0.18).lerp(Color(0.72, 0.62, 0.28), la)
		HexPlanet.BIOME_DESERT:
			return Color(0.74, 0.58, 0.28).lerp(Color(0.88, 0.74, 0.44), la)
		# ── Temperate zone ────────────────────────────────────────────────
		HexPlanet.BIOME_GRASSLAND:
			return Color(0.30, 0.55, 0.14).lerp(Color(0.44, 0.65, 0.24), la)
		HexPlanet.BIOME_SHRUBLAND:
			return Color(0.46, 0.42, 0.18).lerp(Color(0.58, 0.52, 0.26), la)
		HexPlanet.BIOME_TEMPERATE_FOREST:
			return Color(0.08, 0.30, 0.10).lerp(Color(0.16, 0.42, 0.18), la)
		HexPlanet.BIOME_TEMPERATE_RAINFOREST:
			return Color(0.05, 0.26, 0.16).lerp(Color(0.12, 0.38, 0.24), la)
		# ── Cold zone ─────────────────────────────────────────────────────
		HexPlanet.BIOME_BOREAL_FOREST:
			return Color(0.06, 0.18, 0.12).lerp(Color(0.12, 0.26, 0.18), la)
		HexPlanet.BIOME_TUNDRA:
			return Color(0.40, 0.37, 0.28).lerp(Color(0.52, 0.48, 0.37), la)
		# ── Alpine / polar ────────────────────────────────────────────────
		HexPlanet.BIOME_MOUNTAIN:
			return Color(0.40, 0.36, 0.32).lerp(Color(0.56, 0.50, 0.44), la)
		HexPlanet.BIOME_SNOW:
			return Color(0.76, 0.80, 0.86).lerp(Color(0.90, 0.93, 0.97), la)
		HexPlanet.BIOME_ICE:
			return Color(0.70, 0.78, 0.88).lerp(Color(0.88, 0.93, 0.98), la)

	# Fallback — should never be reached.
	return Color(1.0, 0.0, 1.0)


## Debug: colour each plate with a visually distinct hue.
## Uses the golden-ratio hue sequence so adjacent plate IDs are maximally
## different in colour.  Oceanic plates are rendered darker and more
## saturated; continental plates are brighter so the two types read apart
## at a glance.
static func _plate_color(plate_id: int, plate_oceanic: bool, _num_plates: int) -> Color:
	var hue: float = fmod(float(plate_id) * 0.618033988, 1.0)
	if plate_oceanic:
		return Color.from_hsv(hue, 0.70, 0.50)
	return Color.from_hsv(hue, 0.55, 0.85)
