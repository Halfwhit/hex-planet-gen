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
## center_temperature / center_moisture: climate values from HexPlanet (0–1).
## land_threshold: sea-level height value (same as planet).
## border_data: Array of 6 Dicts {type, height, biome, temperature, moisture}
##   in EDGE_SLOTS order, from LocalMap.get_ring1_data().
## noise_seed: deterministic seed; pass planet noise_seed + cell_index.
func setup(
		center_type: int,
		center_height: float,
		center_temperature: float,
		center_moisture: float,
		land_threshold: float,
		border_data: Array,
		noise_seed: int,
) -> void:
	_land_threshold = land_threshold
	_tiles = _generate_tiles(
			center_type, center_height, center_temperature, center_moisture,
			border_data, noise_seed)
	_title_label.text = _map_title(center_type, center_temperature, center_moisture)
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
## Each tile's climate is computed by blending the center cell's temperature
## and moisture outward toward the 6 border directions, weighted by angular
## alignment.  Biome is then classified from the blended climate values using
## the same HexPlanet._classify_biome() logic as the planet surface, so the
## 2D map stays consistent with what is displayed in the LocalMap minimap.
func _generate_tiles(
		center_type: int,
		center_height: float,
		center_temperature: float,
		center_moisture: float,
		border_data: Array,
		noise_seed: int,
) -> Array:
	# Ocean / land boundary noise.
	var onoise: FastNoiseLite = FastNoiseLite.new()
	onoise.seed = noise_seed
	onoise.frequency = 0.45
	onoise.fractal_octaves = 3
	onoise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH

	# Climate noise — perturbs temperature and moisture for organic variation.
	var cnoise: FastNoiseLite = FastNoiseLite.new()
	cnoise.seed = noise_seed ^ 0x1A2B3C
	cnoise.frequency = 0.38
	cnoise.fractal_octaves = 2

	# Fine height noise for micro-terrain texture.
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

			# Radial blend: 0 at center, 1 at outer ring.
			var t: float = float(dist) / float(MAP_RADIUS)

			# Angular weights — cosine similarity of each tile's pixel direction
			# with each of the 6 border slot directions.
			var w_ocean: float = 0.0
			var w_temp: float = 0.0
			var w_moist: float = 0.0
			var w_height: float = 0.0
			var w_total: float = 0.0

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
					var weight: float = max(0.0, (px * dpx + py * dpy) / (tile_len * slot_len))

					var bd: Dictionary = border_data[i] as Dictionary
					w_ocean  += weight * (1.0 if (bd["type"] as int) == HexPlanet.OCEAN else 0.0)
					w_temp   += weight * (bd.get("temperature", 0.5) as float)
					w_moist  += weight * (bd.get("moisture", 0.5) as float)
					w_height += weight * (bd["height"] as float)
					w_total  += weight

			var inv_w: float = 1.0 / max(w_total, 0.001)
			var b_ocean:  float = w_ocean  * inv_w if dist > 0 else center_ocean
			var b_temp:   float = w_temp   * inv_w if dist > 0 else center_temperature
			var b_moist:  float = w_moist  * inv_w if dist > 0 else center_moisture
			var b_height: float = w_height * inv_w if dist > 0 else center_height

			# Blend center → border, then add noise.
			var nv: float = onoise.get_noise_2d(float(q), float(r))
			var cv: float = cnoise.get_noise_2d(float(q), float(r))

			var ocean_t: float = clamp(lerpf(center_ocean,       b_ocean,  t) + nv * 0.30, 0.0, 1.0)
			var eff_T:   float = clamp(lerpf(center_temperature, b_temp,   t) + cv * 0.05, 0.0, 1.0)
			var eff_M:   float = clamp(lerpf(center_moisture,    b_moist,  t) + cv * 0.18, 0.0, 1.0)

			var tile_type: int = HexPlanet.OCEAN if ocean_t > 0.5 else HexPlanet.LAND

			# Height: blend then add fine noise.
			var hn: float = hnoise.get_noise_2d(float(q) * 1.5, float(r) * 1.5) * 0.07
			var tile_height: float = clamp(lerpf(center_height, b_height, t) + hn, -1.0, 1.0)
			if tile_type == HexPlanet.OCEAN:
				tile_height = min(tile_height, _land_threshold - 0.01)
			else:
				tile_height = max(tile_height, _land_threshold + 0.01)

			# Near-ocean: a land tile strongly influenced by ocean borders counts
			# as coastal for beach/grassland biome purposes.
			var near_ocean: bool = (tile_type == HexPlanet.LAND and ocean_t > 0.28)

			var tile_biome: int = HexPlanet._classify_biome(
					tile_type, tile_height, eff_T, eff_M, near_ocean, _land_threshold)

			tiles.append({
				"q": q,
				"r": r,
				"type": tile_type,
				"height": tile_height,
				"color": PlanetMesh.terrain_color(
						tile_height, tile_type, _land_threshold, false, tile_biome),
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


func _map_title(type: int, temperature: float, moisture: float) -> String:
	var biome: int = HexPlanet._classify_biome(
			type, _land_threshold + (0.1 if type == HexPlanet.LAND else -0.1),
			temperature, moisture, false, _land_threshold)
	match biome:
		HexPlanet.BIOME_DEEP_OCEAN:          return "Deep Ocean"
		HexPlanet.BIOME_SHALLOW_OCEAN:       return "Shallow Ocean"
		HexPlanet.BIOME_TROPICAL_OCEAN:      return "Tropical Ocean"
		HexPlanet.BIOME_ICY_OCEAN:           return "Icy Ocean"
		HexPlanet.BIOME_COASTAL_OCEAN:       return "Coastal Waters"
		HexPlanet.BIOME_LAKE:                return "Lake"
		HexPlanet.BIOME_BEACH:               return "Beach"
		HexPlanet.BIOME_TROPICAL_RAINFOREST: return "Tropical Rainforest"
		HexPlanet.BIOME_SAVANNA:             return "Savanna"
		HexPlanet.BIOME_DESERT:              return "Desert"
		HexPlanet.BIOME_GRASSLAND:           return "Grassland"
		HexPlanet.BIOME_SHRUBLAND:           return "Shrubland"
		HexPlanet.BIOME_TEMPERATE_FOREST:    return "Temperate Forest"
		HexPlanet.BIOME_TEMPERATE_RAINFOREST:return "Temperate Rainforest"
		HexPlanet.BIOME_BOREAL_FOREST:       return "Boreal Forest"
		HexPlanet.BIOME_TUNDRA:              return "Tundra"
		HexPlanet.BIOME_MOUNTAIN:            return "Mountain"
		HexPlanet.BIOME_SNOW:                return "Snow"
		HexPlanet.BIOME_ICE:                 return "Ice"
	return "Unknown Terrain"
