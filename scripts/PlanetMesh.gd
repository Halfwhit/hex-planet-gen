class_name PlanetMesh
extends RefCounted

# Build a coloured ArrayMesh from a HexPlanet at the given radius.
static func build(planet: HexPlanet, radius: float) -> ArrayMesh:
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	for cell in planet.cells:
		var center: Vector3 = cell.position * radius
		# Use the cell-centre sphere normal for every vertex in this cell so
		# the entire tile shades as one flat facet — prevents intra-cell normal
		# interpolation from distorting the appearance at the sphere's limb.
		var cell_normal: Vector3 = cell.position
		var poly: PackedVector3Array = cell.polygon
		var n: int = poly.size()
		var color: Color = _terrain_color(cell, planet.land_threshold)

		for i in n:
			var p0: Vector3 = poly[i] * radius
			var p1: Vector3 = poly[(i + 1) % n] * radius

			st.set_normal(cell_normal)
			st.set_color(color)
			st.add_vertex(center)

			st.set_normal(cell_normal)
			st.set_color(color)
			st.add_vertex(p0)

			st.set_normal(cell_normal)
			st.set_color(color)
			st.add_vertex(p1)

	var mesh: ArrayMesh = st.commit()

	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mesh.surface_set_material(0, mat)

	return mesh

static func _terrain_color(cell: Dictionary, land_threshold: float) -> Color:
	var h: float = cell.height
	if cell.type == HexPlanet.OCEAN:
		var t: float = clamp((h + 1.0) / (land_threshold + 1.0), 0.0, 1.0)
		return Color(0.04, 0.12, 0.42).lerp(Color(0.18, 0.48, 0.72), t)
	else:
		var t: float = clamp((h - land_threshold) / (1.0 - land_threshold), 0.0, 1.0)
		if t < 0.5:
			return Color(0.08, 0.32, 0.08).lerp(Color(0.36, 0.58, 0.18), t / 0.5)
		elif t < 0.8:
			return Color(0.36, 0.58, 0.18).lerp(Color(0.55, 0.50, 0.42), (t - 0.5) / 0.3)
		else:
			return Color(0.55, 0.50, 0.42).lerp(Color(0.92, 0.94, 0.96), (t - 0.8) / 0.2)
