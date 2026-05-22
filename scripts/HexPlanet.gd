class_name HexPlanet
extends RefCounted


const OCEAN: int = 0
const LAND: int = 1

## Biome identifiers — used for colour mapping and gameplay logic.
## Ocean biomes (type == OCEAN):
const BIOME_DEEP_OCEAN: int = 0
const BIOME_SHALLOW_OCEAN: int = 1
const BIOME_TROPICAL_OCEAN: int = 2
const BIOME_ICY_OCEAN: int = 3
## Coastal land:
const BIOME_BEACH: int = 4
## Hot-zone land:
const BIOME_TROPICAL_RAINFOREST: int = 5
const BIOME_SAVANNA: int = 6
const BIOME_DESERT: int = 7
## Temperate-zone land:
const BIOME_GRASSLAND: int = 8
const BIOME_SHRUBLAND: int = 9
const BIOME_TEMPERATE_FOREST: int = 10
const BIOME_TEMPERATE_RAINFOREST: int = 11
## Cold-zone land:
const BIOME_BOREAL_FOREST: int = 12
const BIOME_TUNDRA: int = 13
## Alpine / polar:
const BIOME_MOUNTAIN: int = 14
const BIOME_SNOW: int = 15
const BIOME_ICE: int = 16
## Shoreline ocean — very shallow band right at the waterline:
const BIOME_COASTAL_OCEAN: int = 17
## Landlocked water body (ocean region not connected to the main ocean):
const BIOME_LAKE: int = 18

## Each element is a Dictionary with keys:
##   position, polygon, height, type, pentagon,
##   temperature, moisture, biome, plate_id, plate_oceanic
var cells: Array[Dictionary] = []
var land_threshold: float = 0.0
var noise_scale: float = 1.0
var num_plates: int = 0

# Tectonic data retained after generation for debug visualisation.
var _cell_plate: Array[int] = []
var _plate_is_oceanic: Array[bool] = []


func generate(
		ico: IcoSphere,
		noise: FastNoiseLite,
		p_noise_scale: float,
		p_ocean_fraction: float,
		p_num_plates: int = 12,
		p_oceanic_plate_fraction: float = 0.65,
		p_mountain_height: float = 0.85,
		p_detail_strength: float = 0.15,
) -> void:
	noise_scale = p_noise_scale
	num_plates = p_num_plates
	cells = []
	_cell_plate.clear()
	_plate_is_oceanic.clear()

	# Moisture noise uses a prime-offset seed so it is uncorrelated with the
	# terrain height noise while remaining fully deterministic.
	var m_noise: FastNoiseLite = FastNoiseLite.new()
	m_noise.seed = noise.seed ^ 0x1A2B3C
	m_noise.frequency = noise.frequency * 0.65
	m_noise.fractal_octaves = 3

	# Temperature noise adds very subtle local variation on top of the
	# latitude-based gradient (keeps the base feel latitude-driven).
	var t_noise: FastNoiseLite = FastNoiseLite.new()
	t_noise.seed = noise.seed ^ 0x4D5E6F
	t_noise.frequency = noise.frequency * 0.9
	t_noise.fractal_octaves = 2

	var n_verts: int = ico.vertices.size()
	var n_faces: int = ico.faces.size()

	var face_centroids: PackedVector3Array
	face_centroids.resize(n_faces)
	for fi: int in n_faces:
		var f: Array = ico.faces[fi]
		var c: Vector3 = ico.vertices[f[0]] + ico.vertices[f[1]] + ico.vertices[f[2]]
		face_centroids[fi] = (c / 3.0).normalized()

	var vertex_to_faces: Array[Array] = []
	vertex_to_faces.resize(n_verts)
	for i: int in n_verts:
		vertex_to_faces[i] = []
	for fi: int in n_faces:
		var f: Array = ico.faces[fi]
		vertex_to_faces[f[0]].append(fi)
		vertex_to_faces[f[1]].append(fi)
		vertex_to_faces[f[2]].append(fi)


	# Tectonic pass — simulate plate interactions to derive per-cell heights.
	# Sea level is then computed from the actual height distribution so that
	# ocean_fraction is honoured regardless of seed or plate configuration.
	var tectonic_h: Array[float] = _build_tectonic_heights(
			ico, vertex_to_faces,
			noise, p_noise_scale,
			p_num_plates, p_oceanic_plate_fraction,
			p_mountain_height, p_detail_strength)


	var sorted_h: Array[float] = tectonic_h.duplicate()
	sorted_h.sort()
	land_threshold = sorted_h[clamp(int(sorted_h.size() * p_ocean_fraction), 0, sorted_h.size() - 1)]

	# Pass 1 — height, type, polygon.
	for vi: int in n_verts:
		var pos: Vector3 = ico.vertices[vi]
		var adj: Array = vertex_to_faces[vi]

		var pts: Array[Vector3] = []
		for fi: int in adj:
			pts.append(face_centroids[fi])

		var polygon: PackedVector3Array = _sort_around(pos, pts)
		var h: float = tectonic_h[vi]
		var terrain_type: int = LAND if h > land_threshold else OCEAN

		cells.append({
			"position": pos,
			"polygon": polygon,
			"height": h,
			"type": terrain_type,
			# Exactly 12 cells on any Goldberg polyhedron are pentagons (5 sides).
			# Flag them so renderers can treat them as landmarks.
			"pentagon": polygon.size() == 5,
			# Biome fields filled in pass 2.
			"temperature": 0.5,
			"moisture": 0.5,
			"biome": BIOME_SHALLOW_OCEAN,
			# Tectonic plate data (for debug visualisation).
			"plate_id": _cell_plate[vi],
			"plate_oceanic": _plate_is_oceanic[_cell_plate[vi]],
		})


	# ── Lake detection ───────────────────────────────────────────────────────
	# Flood-fill ocean connectivity.  Uses PackedByteArray / PackedInt32Array
	# so the inner BFS loop avoids slow GDScript typed-array overhead and
	# never touches Dictionary fields in its hot path.
	#
	# vert_ocean[i] = 1 if ocean, 0 if land — built once from cells[] then
	# used instead of per-step dictionary lookups.
	var vert_ocean: PackedByteArray = PackedByteArray()
	vert_ocean.resize(n_verts)
	for vi: int in n_verts:
		if (cells[vi] as Dictionary)["type"] == OCEAN:
			vert_ocean[vi] = 1

	# comp_id: -1 = unvisited, ≥0 = component index.
	# PackedInt32Array.fill() is a C-level memset — much faster than a GDScript loop.
	var comp_id: PackedInt32Array = PackedInt32Array()
	comp_id.resize(n_verts)
	comp_id.fill(-1)

	var comp_sizes: PackedInt32Array = PackedInt32Array()
	var next_comp: int = 0

	for vi: int in n_verts:
		if comp_id[vi] >= 0 or vert_ocean[vi] == 0:
			continue
		# Use a PackedInt32Array as a growing queue with a read-head pointer
		# so we never shrink the backing buffer mid-BFS (no per-pop allocation).
		var queue: PackedInt32Array = PackedInt32Array()
		queue.append(vi)
		comp_id[vi] = next_comp
		var head: int = 0
		while head < queue.size():
			var curr: int = queue[head]
			head += 1
			for fi: int in (vertex_to_faces[curr] as Array):
				for vj: int in (ico.faces[fi] as Array):
					if comp_id[vj] == -1 and vert_ocean[vj] == 1:
						comp_id[vj] = next_comp
						queue.append(vj)
		comp_sizes.append(head)  # head == number of cells visited
		next_comp += 1

	var main_comp: int = 0
	for i: int in comp_sizes.size():
		if comp_sizes[i] > comp_sizes[main_comp]:
			main_comp = i

	# Any disconnected ocean body smaller than this stays a lake.
	# Bodies at or above this size are large enough to classify as sea/ocean
	# and keep their regular ocean biomes.  2.5 % of total cells scales
	# naturally across LOD levels (≈256 cells at LOD 3, ≈64 at LOD 2).
	var lake_size_limit: int = max(1, n_verts / 40)

	# comp_id is checked directly in pass 2 — no dictionary needed.

	# Pass 2 — climate and biome.
	# All types are now known so we can check adjacency for near-ocean detection.
	for vi: int in n_verts:
		var pos: Vector3 = ico.vertices[vi]
		var cell: Dictionary = cells[vi]
		var h: float = cell["height"] as float
		var type: int = cell["type"] as int

		# Latitude: 0 at equator (pos.y = 0), 1 at pole (|pos.y| = 1).
		# Poles are at local ±Y because IcoSphere aligns them there.
		var lat: float = abs(pos.y)

		# Altitude above sea level, normalised 0–1 over the land range.
		var alt: float = 0.0
		if type == LAND:
			alt = clamp((h - land_threshold) / max(1.0 - land_threshold, 0.001), 0.0, 1.0)

		# ── Temperature ──────────────────────────────────────────────────────
		# Driven by latitude (equator warm, poles cold) and altitude cooling.
		# pow(…, 1.3) gives a slightly faster cooling toward the poles than
		# linear, matching real-world insolation patterns.
		var lat_warmth: float = pow(1.0 - lat, 1.3)
		var t_var: float = t_noise.get_noise_3dv(pos * p_noise_scale) * 0.04
		var temperature: float = clamp(
				lat_warmth * (1.0 - alt * 0.42) + t_var, 0.0, 1.0)

		# ── Near-ocean detection (land cells only) ────────────────────────────
		# A land cell is "near ocean" if any vertex sharing a face with it is
		# ocean-typed.  Used for beach biome assignment.
		var near_ocean: bool = false
		if type == LAND:
			for fi: int in (vertex_to_faces[vi] as Array):
				for vj: int in (ico.faces[fi] as Array):
					if vj != vi and (cells[vj] as Dictionary)["type"] as int == OCEAN:
						near_ocean = true
						break
				if near_ocean:
					break

		# ── Moisture ─────────────────────────────────────────────────────────
		# Models the Hadley circulation: equatorial wet → subtropical dry →
		# mid-latitude moderate → polar dry.
		var base_m: float
		if lat < 0.15:
			base_m = 0.38
		elif lat < 0.35:
			base_m = lerpf(0.38, 0.18, (lat - 0.15) / 0.20)
		elif lat < 0.60:
			base_m = lerpf(0.16, 0.46, (lat - 0.35) / 0.25)
		else:
			base_m = lerpf(0.46, 0.10, (lat - 0.60) / 0.40)

		# Coastal cells receive additional moisture from the nearby ocean.
		var ocean_boost: float = 0.10 if near_ocean else 0.0
		# Mountains cause a rain shadow on their upper slopes.
		var mtn_shadow: float = max(0.0, alt - 0.55) * 0.65
		var m_var: float = m_noise.get_noise_3dv(pos * p_noise_scale * 0.8) * 0.28

		var moisture: float = clamp(
				base_m + ocean_boost - mtn_shadow + m_var, 0.0, 1.0)

		# ── Biome classification ──────────────────────────────────────────────
		var biome: int = _classify_biome(
				type, h, temperature, moisture, near_ocean, land_threshold)

		cell["temperature"] = temperature
		cell["moisture"] = moisture
		var isolated: bool = comp_id[vi] >= 0 and comp_id[vi] != main_comp
		cell["biome"] = BIOME_LAKE if (isolated and comp_sizes[comp_id[vi]] <= lake_size_limit) else biome



## Simulate plate tectonics and return per-vertex heights.
##
## Algorithm:
##   1. Scatter N plate seeds randomly on the sphere.
##   2. Domain-warp vertex positions before plate assignment so boundaries
##      are organically jagged rather than straight great-circle arcs.
##   3. Each plate gets a type (oceanic = low base, continental = high base),
##      a random height variation, and a random drift vector.
##   4. At each plate boundary, compute convergence of drift vectors:
##        +conv → converging  (mountains / trenches)
##        −conv → diverging   (mid-ocean ridges / rifts)
##   5. Boundary effects are propagated inward via iterative relaxation
##      (Bellman-Ford style) — unlike single-visit BFS this lets the
##      strongest nearby effect win from any direction, eliminating stripe
##      artefacts where the first-reached direction blocked a stronger one.
##   6. Detail noise blends in for coastline roughness and interior texture.
func _build_tectonic_heights(
		ico: IcoSphere,
		vertex_to_faces: Array[Array],
		noise: FastNoiseLite,
		p_noise_scale: float,
		p_num_plates: int,
		p_oceanic_plate_fraction: float,
		p_mountain_height: float,
		p_detail_strength: float,
) -> Array[float]:
	var n_verts: int = ico.vertices.size()
	var n_faces: int = ico.faces.size()

	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = noise.seed

	# ── 1. Plate seeds, types, drift vectors, and per-plate height variation ─
	var plate_seeds: PackedVector3Array
	var plate_is_oceanic: Array[bool] = []
	var plate_drifts: Array[Vector3] = []
	# Random base-height nudge per plate so interiors are not perfectly flat.
	var plate_height_var: Array[float] = []

	for _i: int in p_num_plates:
		var s: Vector3 = Vector3.ZERO
		while s.length_squared() < 0.01 or s.length_squared() > 1.0:
			s = Vector3(rng.randf_range(-1.0, 1.0),
					rng.randf_range(-1.0, 1.0),
					rng.randf_range(-1.0, 1.0))
		s = s.normalized()
		plate_seeds.append(s)
		plate_is_oceanic.append(rng.randf() < p_oceanic_plate_fraction)
		var ref_v: Vector3 = Vector3.UP if abs(s.y) < 0.9 else Vector3.RIGHT
		var tan0: Vector3 = s.cross(ref_v).normalized()
		var tan1: Vector3 = s.cross(tan0)
		var ang: float = rng.randf() * TAU
		var spd: float = rng.randf_range(0.3, 1.0)
		plate_drifts.append((tan0 * cos(ang) + tan1 * sin(ang)) * spd)
		plate_height_var.append(rng.randf_range(-0.06, 0.08))

	# ── 2. Domain-warp noise for organic plate boundaries ────────────────────
	# Three offset noise samples produce an uncorrelated (wx, wy, wz) warp
	# vector.  Displacing vertices before Voronoi assignment makes plate
	# boundaries jagged and organic rather than straight great-circle arcs.
	var warp: FastNoiseLite = FastNoiseLite.new()
	warp.seed = noise.seed ^ 0xF00D
	warp.frequency = 1.4
	warp.fractal_octaves = 2
	# Fixed spatial offsets ensure the three components are uncorrelated.
	var WO1: Vector3 = Vector3(31.4, 17.3, 83.7)
	var WO2: Vector3 = Vector3(57.1, 91.2, 23.5)

	# ── 3. Assign every vertex to its nearest plate (via warped position) ────
	var cell_plate: Array[int] = []
	cell_plate.resize(n_verts)
	for vi: int in n_verts:
		var pos: Vector3 = ico.vertices[vi]
		var wx: float = warp.get_noise_3dv(pos * 2.0)
		var wy: float = warp.get_noise_3dv(pos * 2.0 + WO1)
		var wz: float = warp.get_noise_3dv(pos * 2.0 + WO2)
		var warped: Vector3 = (pos + Vector3(wx, wy, wz) * 0.35).normalized()
		var best: float = -1.0
		var bp: int = 0
		for pi: int in p_num_plates:
			var d: float = warped.dot(plate_seeds[pi])
			if d > best:
				best = d
				bp = pi
		cell_plate[vi] = bp

	# ── 4. Boundary convergence ──────────────────────────────────────────────
	var boundary_effect: Array[float] = []
	boundary_effect.resize(n_verts)
	for i: int in n_verts:
		boundary_effect[i] = 0.0

	for vi: int in n_verts:
		var my_p: int = cell_plate[vi]
		var my_oceanic: bool = plate_is_oceanic[my_p]
		var my_drift: Vector3 = plate_drifts[my_p]
		var pos: Vector3 = ico.vertices[vi]

		for fi: int in (vertex_to_faces[vi] as Array):
			for vj: int in (ico.faces[fi] as Array):
				if vj == vi:
					continue
				var nb_p: int = cell_plate[vj]
				if nb_p == my_p:
					continue
				var nb_oceanic: bool = plate_is_oceanic[nb_p]
				var toward: Vector3 = (ico.vertices[vj] - pos).normalized()
				var conv: float = (my_drift - plate_drifts[nb_p]).dot(toward)
				var eff: float
				if conv > 0.0:
					if not my_oceanic and not nb_oceanic:
						# Continental-continental collision — Himalaya / Alps style.
						eff = conv * p_mountain_height * 1.3
					elif not my_oceanic:
						# Continental overriding oceanic — Andes / Cascades style.
						eff = conv * p_mountain_height * 1.1
					elif not nb_oceanic:
						eff = -conv * 0.45  # subduction trench (oceanic side)
					else:
						eff = conv * 0.18   # oceanic-oceanic island arc
				else:
					if my_oceanic:
						eff = abs(conv) * 0.20  # mid-ocean ridge
					else:
						eff = conv * 0.05       # continental rift
				if abs(eff) > abs(boundary_effect[vi]):
					boundary_effect[vi] = eff

	# ── 5. Build vertex adjacency ─────────────────────────────────────────────
	var adj: Array[Array] = []
	adj.resize(n_verts)
	for i: int in n_verts:
		adj[i] = []
	for fi: int in n_faces:
		var f: Array = ico.faces[fi]
		for k: int in 3:
			var a: int = f[k]
			var b: int = f[(k + 1) % 3]
			if not (adj[a] as Array).has(b):
				(adj[a] as Array).append(b)
			if not (adj[b] as Array).has(a):
				(adj[b] as Array).append(a)

	# ── 6. Iterative relaxation: propagate boundary effects inland ────────────
	# Bellman-Ford style: each pass lets the strongest reachable effect win
	# from any direction, so mountain ranges extend naturally on both sides of
	# a collision zone with no single-direction blocking artefacts.
	# DECAY 0.76: faster falloff keeps mountain bands 2-3 cells wide for
	# typical convergence, up to ~4 for strong seeds.
	const DECAY: float = 0.76
	const MAX_HOPS: int = 22

	var propagated: Array[float] = boundary_effect.duplicate()
	for _hop: int in MAX_HOPS:
		var any_change: bool = false
		for vi: int in n_verts:
			for vj: int in (adj[vi] as Array):
				# Never propagate across a plate boundary — each plate's
				# tectonic effect should only spread within its own territory.
				if cell_plate[vj] != cell_plate[vi]:
					continue
				var candidate: float = propagated[vj] * DECAY
				if abs(candidate) > abs(propagated[vi]) + 0.002:
					propagated[vi] = candidate
					any_change = true
		if not any_change:
			break

	# ── 7. Final heights: plate base + variation + tectonic + detail noise ───
	const OCEAN_BASE: float = -0.38
	const LAND_BASE: float = 0.04

	var heights: Array[float] = []
	heights.resize(n_verts)
	for vi: int in n_verts:
		var pi: int = cell_plate[vi]
		var base: float = (OCEAN_BASE if plate_is_oceanic[pi] else LAND_BASE) + plate_height_var[pi]
		var detail: float = noise.get_noise_3dv(ico.vertices[vi] * p_noise_scale) * p_detail_strength
		heights[vi] = clamp(base + propagated[vi] + detail, -1.0, 1.0)

	# Retain plate data on the HexPlanet instance for debug visualisation.
	_cell_plate = cell_plate
	_plate_is_oceanic = plate_is_oceanic
	return heights


## Classify a cell into one of the 17 BIOME_* constants.
## Exposed as a static so HexMap2D can reuse the same logic for its
## procedurally generated interior tiles.
static func _classify_biome(
		type: int,
		height: float,
		temperature: float,
		moisture: float,
		near_ocean: bool,
		land_threshold: float,
) -> int:
	# ── Ocean biomes ─────────────────────────────────────────────────────────
	if type == OCEAN:
		if temperature < 0.15:
			return BIOME_ICY_OCEAN
		var depth: float = land_threshold - height  # positive = below sea level
		if depth > 0.35:
			return BIOME_DEEP_OCEAN
		# Coastal band — thin turquoise strip right at the waterline.
		if depth < 0.08:
			return BIOME_COASTAL_OCEAN
		if temperature > 0.60:
			return BIOME_TROPICAL_OCEAN
		return BIOME_SHALLOW_OCEAN

	# ── Land biomes ──────────────────────────────────────────────────────────
	var alt: float = clamp(
			(height - land_threshold) / max(1.0 - land_threshold, 0.001), 0.0, 1.0)

	# Very high alpine.  Coastal cliffs become rocky mountain rather than
	# snow/ice so that white tiles never sit directly on the waterline.
	if alt > 0.82:
		if near_ocean:
			return BIOME_MOUNTAIN
		return BIOME_ICE if temperature < 0.25 else BIOME_SNOW

	# Polar ice cap.
	if temperature < 0.03:
		return BIOME_ICE

	# Sub-polar tundra.
	if temperature < 0.08:
		return BIOME_TUNDRA

	# Mountain zone.  Coastal cells stay rocky (no snow bordering the ocean).
	# alt > 0.52 clips the low-elevation skirts that were making ranges too
	# wide; those border cells fall through to forest/grassland instead.
	# Snow threshold 0.50: tropical mountains stay rocky; mid-latitude and
	# polar mountains get snow once altitude cooling brings temp below 0.50.
	if alt > 0.52:
		if near_ocean or temperature >= 0.50:
			return BIOME_MOUNTAIN
		return BIOME_SNOW

	# Boreal / taiga zone.
	if temperature < 0.38:
		return BIOME_BOREAL_FOREST if moisture > 0.42 else BIOME_TUNDRA

	# Coastal beach — warm, low-lying, ocean-adjacent.
	# alt < 0.01 keeps beach to only the very lowest coastal cells.
	var coastal: bool = near_ocean and alt < 0.01

	# Temperate zone.
	if temperature < 0.60:
		if coastal and temperature > 0.38:
			return BIOME_BEACH
		if moisture > 0.72:
			return BIOME_TEMPERATE_RAINFOREST
		if moisture > 0.45:
			return BIOME_TEMPERATE_FOREST
		if moisture > 0.22:
			return BIOME_GRASSLAND
		return BIOME_SHRUBLAND

	# Hot zone.
	# base_m is now 0.32 with noise ±~0.24, so effective range ≈ 0.08–0.56.
	# Thresholds placed at roughly equal intervals across that range so the
	# noise spread hits all four biomes in proportion.
	if coastal:
		return BIOME_BEACH
	if moisture > 0.46:
		return BIOME_TROPICAL_RAINFOREST
	if moisture > 0.38:
		return BIOME_SAVANNA
	if moisture > 0.30:
		return BIOME_SHRUBLAND
	return BIOME_DESERT


# Returns polygon corners in counter-clockwise order when viewed from outside
# the sphere — required for correct front-face winding in PlanetMesh.build().
func _sort_around(center: Vector3, points: Array[Vector3]) -> PackedVector3Array:
	var ref: Vector3 = Vector3.UP if abs(center.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var tangent: Vector3 = center.cross(ref).normalized()
	var bitangent: Vector3 = center.cross(tangent).normalized()

	var with_angle: Array[Array] = []
	for p: Vector3 in points:
		var angle: float = atan2(p.dot(bitangent), p.dot(tangent))
		with_angle.append([angle, p])
	with_angle.sort_custom(func(x: Array, y: Array) -> bool: return x[0] > y[0])

	var result: PackedVector3Array
	for pair: Array in with_angle:
		result.append(pair[1])
	return result
