@tool
class_name HexMap2D
extends Control


signal closed

## Radius of the hex grid in cells (MAP_RADIUS = 5 → 91 tiles, 5 per border edge).
const MAP_RADIUS: int = 5
const SQRT3: float = 1.7320508
const HEADER_H: float = 44.0

## Slot order matching LocalMap.HEX_DIRS / ring1_slots exactly.
## Index i here corresponds to index i in the border_data array from LocalMap.get_ring1_data().
const EDGE_SLOTS: Array = [
	Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1),
	Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1),
]

@export var bg_color: Color = Color(0.05, 0.06, 0.10, 0.97)
@export var border_color: Color = Color(0.0, 0.0, 0.0, 0.25)
@export var grid_line_width: float = 0.8

var _tiles: Array = []
var _land_threshold: float = 0.0
var _title_label: Label
var _close_btn: Button


func _ready() -> void:
	custom_minimum_size = Vector2(360.0, 340.0)

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


## Build and display the 2D map.
## center_type / center_height: planet cell terrain for the occupied tile.
## land_threshold: sea-level height value (same as planet).
## border_data: Array[Dictionary] of 6 entries {"type": int, "height": float},
##   one per EDGE_SLOTS direction, from LocalMap.get_ring1_data().
## noise_seed: deterministic seed; pass planet noise_seed + cell_index.
func setup(
		center_type: int,
		center_height: float,
		land_threshold: float,
		border_data: Array,
		noise_seed: int,
) -> void:
	_land_threshold = land_threshold
	_tiles = _generate_tiles(center_type, center_height, border_data, noise_seed)
	_title_label.text = _map_title(center_type, center_height)
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), bg_color, true)
	if _tiles.is_empty():
		return

	var hex_size: float = _compute_hex_size()
	var origin: Vector2 = Vector2(size.x * 0.5, HEADER_H + (size.y - HEADER_H) * 0.5)

	for tile: Dictionary in _tiles:
		var pos: Vector2 = origin + _axial_to_pixel(tile["q"] as int, tile["r"] as int, hex_size)
		var corners: PackedVector2Array = _hex_corners(pos, hex_size)
		draw_colored_polygon(corners, tile["color"] as Color)
		var ring_pts: PackedVector2Array = corners
		ring_pts.append(corners[0])
		draw_polyline(ring_pts, border_color, grid_line_width, true)


## Generate tile data for every cell in the hex grid.
##
## Terrain is blended from the center outward using two forces:
##   1. Radial factor t  (0 at center, 1 at outer ring) determines how much the
##      border types dominate.
##   2. Angular weights  distribute border influence across the 6 directions - a
##      tile pointing toward a water border gets more water influence than one
##      pointing toward a land border.
## Noise is added on top to make boundaries organic rather than perfectly circular.
func _generate_tiles(
		center_type: int,
		center_height: float,
		border_data: Array,
		noise_seed: int,
) -> Array:
	# Type noise determines ocean/land boundary variation.
	var tnoise: FastNoiseLite = FastNoiseLite.new()
	tnoise.seed = noise_seed
	tnoise.frequency = 0.45
	tnoise.fractal_octaves = 3
	tnoise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH

	# Height noise adds texture within each terrain band.
	var hnoise: FastNoiseLite = FastNoiseLite.new()
	hnoise.seed = noise_seed + 9973
	hnoise.frequency = 0.8
	hnoise.fractal_octaves = 2

	var center_ocean: float = 1.0 if center_type == HexPlanet.OCEAN else 0.0

	var tiles: Array = []
	for q: int in range(-MAP_RADIUS, MAP_RADIUS + 1):
		for r: int in range(-MAP_RADIUS, MAP_RADIUS + 1):
			var dist: int = (abs(q) + abs(r) + abs(q + r)) / 2
			if dist > MAP_RADIUS:
				continue

			# Radial blend factor: 0 at center, 1 at outermost ring.
			var t: float = float(dist) / float(MAP_RADIUS)

			# Angular weights: how much each of the 6 border directions contributes
			# to this tile based on directional alignment.
			var border_ocean_sum: float = 0.0
			var border_height_sum: float = 0.0
			var weight_total: float = 0.0

			if dist > 0:
				var px: float = -1.5 * float(q)
				var py: float = SQRT3 * (float(r) + float(q) * 0.5)
				var tile_len: float = sqrt(px * px + py * py)

				for i: int in EDGE_SLOTS.size():
					var dq: int = (EDGE_SLOTS[i] as Vector2i).x
					var dr: int = (EDGE_SLOTS[i] as Vector2i).y
					var dpx: float = -1.5 * float(dq)
					var dpy: float = SQRT3 * (float(dr) + float(dq) * 0.5)
					var slot_len: float = sqrt(dpx * dpx + dpy * dpy)

					# Cosine similarity clamped to [0, 1] - only forward-facing borders matter.
					var cos_sim: float = (px * dpx + py * dpy) / (tile_len * slot_len)
					var weight: float = max(0.0, cos_sim)

					var bd: Dictionary = border_data[i] as Dictionary
					var b_ocean: float = 1.0 if (bd["type"] as int) == HexPlanet.OCEAN else 0.0
					border_ocean_sum += weight * b_ocean
					border_height_sum += weight * (bd["height"] as float)
					weight_total += weight

			var weighted_ocean: float = border_ocean_sum / max(weight_total, 0.001)
			var weighted_height: float = border_height_sum / max(weight_total, 0.001) if dist > 0 else center_height

			# Blend center vs borders radially, then perturb with noise.
			var ocean_tendency: float = lerpf(center_ocean, weighted_ocean, t)
			var nv: float = tnoise.get_noise_2d(float(q), float(r))
			ocean_tendency = clamp(ocean_tendency + nv * 0.32, 0.0, 1.0)

			var tile_type: int = HexPlanet.OCEAN if ocean_tendency > 0.5 else HexPlanet.LAND

			# Blend height radially, add fine noise for texture.
			var base_height: float = lerpf(center_height, weighted_height, t)
			var hn: float = hnoise.get_noise_2d(float(q) * 1.5, float(r) * 1.5) * 0.07
			var tile_height: float = clamp(base_height + hn, -1.0, 1.0)

			# Clamp height into the valid range for the determined type so colour
			# boundaries don't produce mismatched palette entries.
			if tile_type == HexPlanet.OCEAN:
				tile_height = min(tile_height, _land_threshold - 0.01)
			else:
				tile_height = max(tile_height, _land_threshold + 0.01)

			tiles.append({
				"q": q,
				"r": r,
				"type": tile_type,
				"height": tile_height,
				"color": PlanetMesh.terrain_color(tile_height, tile_type, _land_threshold),
			})

	return tiles


## Fit the hex grid inside the usable panel area.
func _compute_hex_size() -> float:
	var usable_w: float = size.x
	var usable_h: float = size.y - HEADER_H
	# Width of grid: (3 * MAP_RADIUS + 2) * hex_size
	var fit_w: float = usable_w / (3.0 * float(MAP_RADIUS) + 2.0)
	# Height of grid: sqrt(3) * (2 * MAP_RADIUS + 1) * hex_size
	var fit_h: float = usable_h / (SQRT3 * float(2 * MAP_RADIUS + 1))
	return min(fit_w, fit_h) * 0.94


## Flat-top axial to pixel, x negated to match LocalMap orientation (east = screen-left).
func _axial_to_pixel(q: int, r: int, hex_size: float) -> Vector2:
	return Vector2(
		-hex_size * 1.5 * float(q),
		hex_size * SQRT3 * (float(r) + float(q) * 0.5),
	)


func _hex_corners(center: Vector2, hex_size: float) -> PackedVector2Array:
	var pts: PackedVector2Array = PackedVector2Array()
	for i: int in 6:
		var a: float = deg_to_rad(60.0 * float(i))
		pts.append(center + Vector2(cos(a), sin(a)) * hex_size)
	return pts


func _map_title(type: int, height: float) -> String:
	if type == HexPlanet.OCEAN:
		return "Ocean - %s" % ("deep" if height < -0.3 else "shallow")
	var t: float = clamp((height - _land_threshold) / max(1.0 - _land_threshold, 0.001), 0.0, 1.0)
	if t < 0.15:
		return "Coastal land"
	elif t < 0.4:
		return "Lowland"
	elif t < 0.7:
		return "Highland"
	return "Mountain"
