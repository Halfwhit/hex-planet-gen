class_name LocalMap
extends Control


signal closed

## Number of hex rings to display around the centre cell.
## Must match PlanetGridmap.occupation_radius so the minimap covers the full exclusion zone.
var rings: int = 1
## Highlight the 12 pentagon tiles in magenta for debug purposes.
var debug_pentagons: bool = false
const HEX_SIZE: float = 28.0
const SQRT3: float = 1.7320508
const HEADER_H: float = 44.0

# Flat-top axial hex directions (q, r).
const HEX_DIRS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1),
	Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1),
]

# Pre-computed flat-top corner offsets at HEX_SIZE — avoids 6 trig calls per
# cell per redraw.  Initialised once via a static helper.
static var _HEX_OFFSETS: PackedVector2Array = _init_hex_offsets()

@export var bg_color: Color = Color(0.07, 0.08, 0.13, 0.95)
@export var cell_border_color: Color = Color(0.0, 0.0, 0.0, 0.35)
@export var center_border_color: Color = Color(0.95, 0.85, 0.2, 1.0)
@export var occupied_tint: Color = Color(0.2, 0.9, 0.45, 0.3)

var _region: Array[Dictionary] = []
var _land_threshold: float = 0.0
var _title_label: Label
var _close_btn: Button


func _ready() -> void:
	custom_minimum_size = Vector2(440.0, 400.0)

	_title_label = Label.new()
	_title_label.position = Vector2(12.0, 10.0)
	_title_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.95))
	add_child(_title_label)

	_close_btn = Button.new()
	_close_btn.text = "✕"
	_close_btn.flat = true
	_close_btn.size = Vector2(36.0, 36.0)
	_close_btn.anchor_left = 1.0
	_close_btn.anchor_right = 1.0
	_close_btn.offset_left = -44.0
	_close_btn.offset_right = -8.0
	_close_btn.offset_top = 6.0
	_close_btn.offset_bottom = 42.0
	_close_btn.pressed.connect(func() -> void: hide(); closed.emit())
	add_child(_close_btn)


func setup(
		center_idx: int,
		cells: Array,
		all_neighbors: Array,
		occupied: Dictionary,
		land_threshold: float,
		cam_up_local: Vector3,
) -> void:
	_land_threshold = land_threshold
	_region = _build_region(center_idx, cells, all_neighbors, occupied, cam_up_local)

	var center_cell: Dictionary = cells[center_idx]
	_title_label.text = _cell_description(center_cell)
	queue_redraw()


## Returns the 6 ring-1 neighbour data in HEX_DIRS / EDGE_SLOTS order.
## Each element is a Dictionary {type, height, biome, temperature, moisture}.
## Call after setup() so _region is populated.  Used by HexMap2D to seed
## its border terrain with full climate information.
func get_ring1_data() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for i: int in 6:
		result.append({
			"type": HexPlanet.OCEAN,
			"height": -0.5,
			"biome": HexPlanet.BIOME_SHALLOW_OCEAN,
			"temperature": 0.5,
			"moisture": 0.5,
		})
	for entry: Dictionary in _region:
		var q: int = entry["q"] as int
		var r: int = entry["r"] as int
		if (abs(q) + abs(r) + abs(q + r)) / 2 != 1:
			continue
		var coord: Vector2i = Vector2i(q, r)
		for i: int in HEX_DIRS.size():
			if HEX_DIRS[i] == coord:
				result[i] = {
					"type": entry["type"] as int,
					"height": entry["height"] as float,
					"biome": entry["biome"] as int,
					"temperature": entry.get("temperature", 0.5) as float,
					"moisture": entry.get("moisture", 0.5) as float,
				}
				break
	return result


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), bg_color, true)

	if _region.is_empty():
		return

	var origin: Vector2 = Vector2(size.x * 0.5, HEADER_H + (size.y - HEADER_H) * 0.5)

	for entry: Dictionary in _region:
		var pos: Vector2 = origin + _axial_to_pixel(entry["q"] as int, entry["r"] as int)
		var corners: PackedVector2Array = _hex_corners(pos)

		draw_colored_polygon(corners, PlanetMesh.terrain_color(
				entry["height"] as float,
				entry["type"] as int,
				_land_threshold,
				debug_pentagons and entry["pentagon"] as bool,
				entry["biome"] as int))

		if entry["is_occupied"] as bool:
			draw_colored_polygon(corners, occupied_tint)

		var ring_pts: PackedVector2Array = corners
		ring_pts.append(corners[0])
		if entry["is_center"] as bool:
			draw_polyline(ring_pts, center_border_color, 2.5, true)
		else:
			draw_polyline(ring_pts, cell_border_color, 1.0, true)


func _build_region(
		center_idx: int,
		cells: Array,
		all_neighbors: Array,
		occupied: Dictionary,
		cam_up_local: Vector3,
) -> Array[Dictionary]:
	var center_pos: Vector3 = cells[center_idx]["position"] as Vector3

	# Orient the tangent frame using orbital north (world Y) expressed in planet-local
	# space at the current spin angle — supplied as cam_up_local by Main._cam_up_local().
	# This keeps the tilemap aligned with the camera view (which also uses orbital north
	# as its fixed up direction), so ocean/land neighbours always appear on the same
	# side in the tilemap as they appear on-screen, regardless of the planet's axial
	# tilt or current spin angle.
	# Fallbacks: if cam_up_local is nearly parallel to the cell normal (rare, polar
	# edge case), fall back to planet-north then the equatorial axis.
	var up_proj: Vector3 = cam_up_local - cam_up_local.dot(center_pos) * center_pos
	if up_proj.length_squared() < 0.001:
		up_proj = Vector3.UP - Vector3.UP.dot(center_pos) * center_pos
	if up_proj.length_squared() < 0.001:
		up_proj = Vector3(0.0, 0.0, -1.0) - Vector3(0.0, 0.0, -1.0).dot(center_pos) * center_pos
	var e_north: Vector3 = up_proj.normalized()
	# e1 = camera-right in tangent plane (east, maps to negated screen-x = left in tilemap)
	# e2 = camera-down in tangent plane (south, maps to +screen-y = down in tilemap)
	var e1: Vector3 = center_pos.cross(e_north)
	var e2: Vector3 = -e_north

	# Coordinate assignment.
	#
	# Ring-1 uses a greedy bipartite match: score every (neighbour, hex-slot) pair by
	# how well the tangent-plane direction of the neighbour aligns with the expected
	# direction of the slot, then assign the best-scoring pair first and remove both
	# from contention.  This avoids the cascading-fallback problem where _sorted_hex_dirs
	# would displace several cells from their correct geographic positions whenever two
	# neighbours fell in the same 60° sector.
	#
	# Ring-2+ still uses sorted-dirs BFS from the ring-1 anchors, with claimed-coord
	# tracking to prevent collisions and a dist != ring guard to block ring-N+1 cells
	# from filling ring-N pentagon gaps with wrong terrain.
	var axial: Dictionary = {center_idx: Vector2i(0, 0)}
	var claimed: Dictionary = {Vector2i(0, 0): true}

	# --- Ring-1: greedy bipartite matching ---
	var ring1_candidates: Array = all_neighbors[center_idx].duplicate()
	var ring1_slots: Array[Vector2i] = [
		Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1),
		Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1),
	]
	while not ring1_candidates.is_empty() and not ring1_slots.is_empty():
		var best_score: float = -INF
		var best_ci: int = 0
		var best_si: int = 0
		for ci: int in ring1_candidates.size():
			var nb: int = ring1_candidates[ci]
			var to_pos: Vector3 = cells[nb]["position"] as Vector3
			var dx: float = to_pos.dot(e1) - center_pos.dot(e1)
			var dy: float = to_pos.dot(e2) - center_pos.dot(e2)
			for si: int in ring1_slots.size():
				var pv: Vector2 = _axial_to_pixel(
						ring1_slots[si].x,
						ring1_slots[si].y)
				# Dot product of tangent offset with the slot's expected direction.
				# pv.x is negated in _axial_to_pixel (east = screen-left), so negate
				# it back to get the tangent-space direction vector.
				var score: float = dx * (-pv.x) + dy * pv.y
				if score > best_score:
					best_score = score
					best_ci = ci
					best_si = si
		var nb: int = ring1_candidates[best_ci]
		var slot: Vector2i = ring1_slots[best_si]
		axial[nb] = slot
		claimed[slot] = true
		ring1_candidates.remove_at(best_ci)
		ring1_slots.remove_at(best_si)

	# --- Ring-2+: sorted-dirs BFS from ring-1 anchors ---
	var frontier: Array[int] = []
	for idx: int in axial:
		if idx != center_idx:
			frontier.append(idx)
	for ring: int in range(2, rings + 1):
		var next_frontier: Array[int] = []
		for idx: int in frontier:
			var parent_coord: Vector2i = axial[idx] as Vector2i
			var from_pos: Vector3 = cells[idx]["position"] as Vector3
			for nb: int in all_neighbors[idx]:
				if axial.has(nb):
					continue
				var to_pos: Vector3 = cells[nb]["position"] as Vector3
				var dx: float = to_pos.dot(e1) - from_pos.dot(e1)
				var dy: float = to_pos.dot(e2) - from_pos.dot(e2)
				for dir_idx: int in _sorted_hex_dirs(dx, dy):
					var coord: Vector2i = parent_coord + HEX_DIRS[dir_idx]
					var dist: int = (abs(coord.x) + abs(coord.y) + abs(coord.x + coord.y)) / 2
					if dist != ring:
						continue
					if claimed.has(coord):
						continue
					axial[nb] = coord
					claimed[coord] = true
					next_frontier.append(nb)
					break
		frontier = next_frontier

	# Build region; deduplicate by coord in case two same-ring cells collide.
	var used_coords: Dictionary = {}
	var region: Array[Dictionary] = []
	for idx: int in axial:
		var cell: Dictionary = cells[idx]
		var coord: Vector2i = axial[idx] as Vector2i
		if used_coords.has(coord):
			continue
		used_coords[coord] = true
		region.append({
			"q": coord.x,
			"r": coord.y,
			"type": cell["type"] as int,
			"height": cell["height"] as float,
			"is_center": idx == center_idx,
			"is_occupied": occupied.has(idx),
			"pentagon": cell["pentagon"] as bool,
			"biome": cell.get("biome", -1) as int,
		})

	# --- Gap filling ---
	# Positions that BFS missed (pentagon gaps, curvature edge cases) are filled by
	# finding the nearest physical cell in the BFS halo (axial cells + their
	# immediate neighbours). This is ~200 candidates at most — cheap in GDScript.
	# The tangent-to-pixel scale is derived from ring-1 assignments so the search
	# uses the same units as _axial_to_pixel.

	# Compute scale: average ratio of tangent distance to pixel distance for ring-1 cells.
	var scale_sum: float = 0.0
	var scale_count: int = 0
	for idx: int in axial:
		var coord: Vector2i = axial[idx] as Vector2i
		if (abs(coord.x) + abs(coord.y) + abs(coord.x + coord.y)) / 2 != 1:
			continue
		var cp: Vector3 = cells[idx]["position"] as Vector3
		var t_len: float = Vector2(cp.dot(e1), cp.dot(e2)).length()
		var p_len: float = _axial_to_pixel(coord.x, coord.y).length()
		if p_len > 0.0 and t_len > 0.0:
			scale_sum += t_len / p_len
			scale_count += 1
	if scale_count == 0:
		return region
	var scale: float = scale_sum / float(scale_count)

	# Halo: every cell in axial plus its immediate neighbours.
	var halo: Dictionary = {}
	for idx: int in axial:
		halo[idx] = true
		for nb: int in all_neighbors[idx]:
			halo[nb] = true

	# Fill any expected position not yet covered.
	for q: int in range(-rings, rings + 1):
		for r: int in range(-rings, rings + 1):
			var hex_dist: int = (abs(q) + abs(r) + abs(q + r)) / 2
			if hex_dist == 0 or hex_dist > rings:
				continue
			var coord: Vector2i = Vector2i(q, r)
			if used_coords.has(coord):
				continue
			var pv: Vector2 = _axial_to_pixel(q, r)
			# _axial_to_pixel negates x so that east appears screen-left, but
			# cp.dot(e1) is positive for eastern cells. Negate pv.x to restore
			# the correct sign before comparing against the tangent projection.
			var target_e1: float = -pv.x * scale
			var target_e2: float = pv.y * scale
			var best_sq: float = INF
			var best_cell: Dictionary = {}
			for ci: int in halo:
				var cp: Vector3 = cells[ci]["position"] as Vector3
				var dx: float = cp.dot(e1) - target_e1
				var dy: float = cp.dot(e2) - target_e2
				var sq: float = dx * dx + dy * dy
				if sq < best_sq:
					best_sq = sq
					best_cell = cells[ci]
			if best_cell.is_empty():
				continue
			used_coords[coord] = true
			region.append({
				"q": q,
				"r": r,
				"type": best_cell["type"] as int,
				"height": best_cell["height"] as float,
				"is_center": false,
				"is_occupied": false,
				"pentagon": best_cell["pentagon"] as bool,
				"biome": best_cell.get("biome", -1) as int,
			})

	return region


func _axial_to_pixel(q: int, r: int) -> Vector2:
	# Flat-top layout. Negate x to match the camera-facing view (east = screen left).
	return Vector2(-HEX_SIZE * 1.5 * q, HEX_SIZE * SQRT3 * (r + q * 0.5))


static func _init_hex_offsets() -> PackedVector2Array:
	var pts: PackedVector2Array = PackedVector2Array()
	for i: int in 6:
		var a: float = deg_to_rad(60.0 * i)  # 0° first corner = flat-top
		pts.append(Vector2(cos(a), sin(a)) * HEX_SIZE)
	return pts


func _hex_corners(center: Vector2) -> PackedVector2Array:
	var pts: PackedVector2Array = PackedVector2Array()
	for off: Vector2 in _HEX_OFFSETS:
		pts.append(center + off)
	return pts


func _cell_description(cell: Dictionary) -> String:
	var biome: int = cell.get("biome", -1) as int
	var name: String = HexPlanet.biome_name(biome)
	if not name.is_empty():
		return name
	# Fallback for cells with biome == -1 (before pass 2 runs, e.g. editor preview).
	var is_ocean: bool = (cell["type"] as int) == 0
	var h: float = cell["height"] as float
	if is_ocean:
		return "Ocean — %s" % ("deep" if h < -0.3 else "shallow")
	var t: float = clamp((h - _land_threshold) / max(1.0 - _land_threshold, 0.001), 0.0, 1.0)
	if t < 0.15: return "Land — coast"
	elif t < 0.4: return "Land — lowland"
	elif t < 0.7: return "Land — highland"
	return "Land — mountain"


# Returns all six direction indices sorted from best to worst match for (dx, dy).
# Used by the BFS to fall back to the next-best direction when the best is taken.
static func _sorted_hex_dirs(dx: float, dy: float) -> Array[int]:
	var dots: Array[float] = [
		dx * 0.866025 + dy * 0.5,
		dx * 0.866025 - dy * 0.5,
		-dy,
		-dx * 0.866025 - dy * 0.5,
		-dx * 0.866025 + dy * 0.5,
		dy,
	]
	var order: Array[int] = [0, 1, 2, 3, 4, 5]
	order.sort_custom(func(a: int, b: int) -> bool: return dots[a] > dots[b])
	return order
