@tool
extends Node3D


const LOD_SUBDIVISIONS: Array[int] = [2, 3, 4, 5]
# LOD switch distances expressed as multiples of planet_radius so they scale
# automatically when planet_radius changes.  Closer than each threshold →
# higher LOD.  At the default radius (2.0) and start distance (5.0) this
# opens at LOD 2 (2562 cells): 5.0 ≤ 2.5 × 2.0.
const LOD_THRESHOLDS: Array[float] = [3.5, 2.5, 2.0]

const _HORIZON_SHADER: Shader = preload("res://shaders/HorizonMask.gdshader")
const _ATMOSPHERE_SHADER: Shader = preload("res://shaders/Atmosphere.gdshader")
const _HEX_MAP_2D_SCRIPT: GDScript = preload("res://scripts/HexMap2D.gd")

@export var planet_radius: float = 2.0
## Fraction of the planet surface that will be ocean (0 = all land, 1 = all ocean).
@export_range(0.0, 1.0) var ocean_fraction: float = 0.55
@export var noise_scale: float = 1.5
@export var noise_seed: int = 42

@export_group("Atmosphere")
@export var atmosphere_color: Color = Color(0.3, 0.52, 1.0, 1.0)
@export var atmosphere_power: float = 3.5
@export var atmosphere_radius_factor: float = 1.08
@export var atmosphere_strength: float = 1.1
## Colour blended over polygon edges at the silhouette — match the scene
## background so edge tiles dissolve rather than floating.
@export var horizon_mask_color: Color = Color(0.467, 0.467, 0.467, 1.0)
@export var horizon_mask_power: float = 10.0
@export var horizon_mask_strength: float = 1.0

@export_group("Rotation")
@export var axial_tilt: float = 23.5
@export var rotation_speed: float = 4.0

@export_group("Occupation")
## Number of rings shown in the local map AND the minimum spacing between
## occupied cells — both are kept in sync from this single value.
@export_range(1, 5) var map_rings: int = 1

@export_group("Editor Preview")
@export_tool_button("Generate Planet", "MeshInstance3D")
var _gen_btn: Callable = _editor_generate
## Subdivision level used for the in-editor preview (2 = 162 cells, 3 = 642, 4 = 2562).
@export_range(2, 5) var editor_preview_subdivisions: int = 3
## Highlight the 12 pentagon tiles in magenta for debugging purposes.
@export var debug_pentagons: bool = false

var _current_lod: int = 0
var _lod_meshes: Array[ArrayMesh] = []
var _lod_cells: Array = []
var _spin_angle: float = 0.0
var _land_threshold: float = 0.0
var _rotation_speed_rad: float = 0.0
var _tilt_basis: Basis = Basis.IDENTITY
var _lock_cell_local: Vector3 = Vector3.ZERO
var _locking: bool = false
var _local_map: LocalMap = null
var _hex_map_2d: Control = null

@onready var lod_label: Label = $UI/LODLabel
@onready var orbit_camera: OrbitCamera = $OrbitCamera
@onready var planet_mesh_instance: MeshInstance3D = $PlanetMesh
@onready var planet_gridmap: PlanetGridmap = $PlanetGridmap


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_rotation_speed_rad = deg_to_rad(rotation_speed)
	# Pre-tilt the planet mesh so its local Y axis (= the planet's north pole)
	# points in the intended world-space direction.  All subsequent behaviour —
	# camera north lock, lighting — reads this axis directly from the mesh
	# rather than keeping a separate _spin_axis variable.
	_tilt_basis = Basis.from_euler(Vector3(0.0, 0.0, deg_to_rad(-axial_tilt)))
	planet_mesh_instance.basis = _tilt_basis
	# Aim the light from the +Z side, perpendicular to true north (world Y).
	# look_at_from_position keeps the light at a fixed world position so it
	# never drifts with the planet's rotation or tilt.
	$DirectionalLight3D.look_at_from_position(Vector3(0.0, 0.0, 10.0), Vector3.ZERO, Vector3.UP)
	_generate_planet()
	_create_atmosphere()
	_create_axis_display()
	orbit_camera.set_distance_limits(planet_radius * 1.1, planet_radius * 6.0)
	orbit_camera.zoom_changed.connect(_on_zoom_changed)
	planet_gridmap.cell_selected.connect(_on_cell_selected)
	planet_gridmap.cell_occupied.connect(_on_cell_occupied)
	planet_gridmap.cell_vacated.connect(_on_cell_vacated)
	orbit_camera.drag_started.connect(func() -> void: _locking = false)

	var map_layer: CanvasLayer = CanvasLayer.new()
	map_layer.layer = 10
	add_child(map_layer)

	_hex_map_2d = _HEX_MAP_2D_SCRIPT.new()
	_hex_map_2d.anchor_left = 0.01
	_hex_map_2d.anchor_right = 0.56
	_hex_map_2d.anchor_top = 0.05
	_hex_map_2d.anchor_bottom = 0.95
	map_layer.add_child(_hex_map_2d)
	_hex_map_2d.hide()

	_local_map = LocalMap.new()
	_local_map.rings = map_rings
	_local_map.debug_pentagons = debug_pentagons
	_local_map.anchor_left = 0.58
	_local_map.anchor_right = 1.0
	_local_map.anchor_top = 0.1
	_local_map.anchor_bottom = 0.9
	map_layer.add_child(_local_map)
	_local_map.hide()
	planet_gridmap.occupation_radius = map_rings

	_on_zoom_changed(orbit_camera.get_distance())


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	# Rebuild the planet basis from scratch each frame: cached tilt composed with
	# a spin around the resulting local Y axis.  Explicit rather than incremental
	# so there is no floating-point drift and the spin axis provably matches the
	# RotationAxis line.
	_spin_angle += _rotation_speed_rad * delta
	planet_mesh_instance.basis = _tilt_basis * Basis(Vector3.UP, _spin_angle)
	if _locking:
		orbit_camera.set_angles_from_dir(
				(planet_mesh_instance.global_transform.basis * _lock_cell_local).normalized())


func _editor_generate() -> void:
	if not Engine.is_editor_hint():
		return

	var noise: FastNoiseLite = _make_noise()
	var sea_level: float = _compute_sea_level(noise)
	var ico: IcoSphere = IcoSphere.new()
	ico.generate(editor_preview_subdivisions)
	var planet: HexPlanet = HexPlanet.new()
	planet.generate(ico, noise, sea_level, noise_scale)
	planet_mesh_instance.mesh = PlanetMesh.build(planet, planet_radius, debug_pentagons)

	for child_name: String in ["HorizonMask", "Atmosphere", "RotationAxis", "TrueNorthAxis"]:
		var old: Node = get_node_or_null(child_name)
		if old:
			old.free()
	_create_atmosphere()
	_create_axis_display()


func _on_zoom_changed(dist: float) -> void:
	var new_lod: int = 0
	for i: int in LOD_THRESHOLDS.size():
		if dist <= LOD_THRESHOLDS[i] * planet_radius:
			new_lod = i + 1
	_set_lod(new_lod)


func _generate_planet() -> void:
	var noise: FastNoiseLite = _make_noise()
	var sea_level: float = _compute_sea_level(noise)
	_land_threshold = sea_level

	_lod_meshes.clear()
	_lod_cells.clear()
	for sub: int in LOD_SUBDIVISIONS:
		var ico: IcoSphere = IcoSphere.new()
		ico.generate(sub)
		var planet: HexPlanet = HexPlanet.new()
		planet.generate(ico, noise, sea_level, noise_scale)
		_lod_meshes.append(PlanetMesh.build(planet, planet_radius, debug_pentagons))
		_lod_cells.append(planet.cells)

	_current_lod = -1  # force _set_lod(0) to apply unconditionally
	_set_lod(0)


func _set_lod(lod: int) -> void:
	if lod == _current_lod:
		return
	_current_lod = lod
	planet_mesh_instance.mesh = _lod_meshes[_current_lod]
	var cells: Array = _lod_cells[_current_lod] if _current_lod == 3 else []
	planet_gridmap.setup(orbit_camera.camera, planet_mesh_instance, cells, planet_radius)
	_locking = false
	if _local_map != null:
		_local_map.hide()
	if _hex_map_2d != null:
		_hex_map_2d.hide()
	if lod_label:
		lod_label.text = "LOD %d  (%d cells)" % [lod, (_lod_cells[_current_lod] as Array).size()]


func _make_noise() -> FastNoiseLite:
	var n: FastNoiseLite = FastNoiseLite.new()
	n.seed = noise_seed
	n.frequency = 0.5
	n.fractal_octaves = 4
	return n


# Sample the noise at subdivision-3 resolution and return the height at the
# ocean_fraction percentile — guarantees the target ocean coverage regardless
# of seed or scale.
func _compute_sea_level(noise: FastNoiseLite) -> float:
	var probe: IcoSphere = IcoSphere.new()
	probe.generate(3)
	var heights: Array[float] = []
	for v: Vector3 in probe.vertices:
		heights.append(noise.get_noise_3dv(v * noise_scale))
	heights.sort()
	return heights[clamp(int(heights.size() * ocean_fraction), 0, heights.size() - 1)]


func _make_sphere_layer(
		layer_name: String,
		radius: float,
		shader: Shader,
		params: Dictionary,
) -> void:
	var sphere: SphereMesh = SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = 64
	sphere.rings = 32
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = shader
	for key: String in params:
		mat.set_shader_parameter(key, params[key])
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.name = layer_name
	mi.mesh = sphere
	mi.material_override = mat
	add_child(mi)


func _create_atmosphere() -> void:
	_make_sphere_layer("HorizonMask", planet_radius * 1.025, _HORIZON_SHADER, {
		"mask_color": horizon_mask_color,
		"mask_power": horizon_mask_power,
		"mask_strength": horizon_mask_strength,
	})
	_make_sphere_layer("Atmosphere", planet_radius * atmosphere_radius_factor, _ATMOSPHERE_SHADER, {
		"atm_color": atmosphere_color,
		"glow_power": atmosphere_power,
		"glow_strength": atmosphere_strength,
	})


func _create_axis_display() -> void:
	var axis_length: float = planet_radius * 1.4
	# Rotational north — the planet's actual spin axis, tilted by axial_tilt.
	# Blue/cyan to suggest a geographic / compass direction.
	_add_axis_line("RotationAxis", axis_length,
			Vector3(0.0, 0.0, -axial_tilt),
			Color(0.55, 0.80, 1.0),
			planet_radius * 0.012)
	# True north — the fixed world Y axis, independent of axial tilt.
	# Amber so it reads as a separate, absolute reference.
	_add_axis_line("TrueNorthAxis", axis_length,
			Vector3.ZERO,
			Color(1.0, 0.72, 0.2),
			planet_radius * 0.008)


func _add_axis_line(
		line_name: String,
		half_length: float,
		rotation_deg: Vector3,
		color: Color,
		radius: float,
) -> void:
	var cyl: CylinderMesh = CylinderMesh.new()
	cyl.height = half_length * 2.0
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.radial_segments = 8
	cyl.rings = 1

	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 1.2
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.name = line_name
	mi.mesh = cyl
	mi.material_override = mat
	mi.rotation_degrees = rotation_deg
	add_child(mi)


func _cam_up_local() -> Vector3:
	# Express orbital north (world Y = the camera's fixed up direction) in
	# planet-local space at the current spin angle.  This makes the tilemap
	# always oriented the same way as the camera view so ocean/land neighbours
	# appear on the correct side regardless of the planet's current rotation.
	return (planet_mesh_instance.global_transform.basis.inverse() * Vector3.UP).normalized()


func _show_local_map(idx: int) -> void:
	_local_map.setup(
		idx,
		_lod_cells[_current_lod],
		planet_gridmap.get_all_neighbors(),
		planet_gridmap.get_occupied_set(),
		_land_threshold,
		_cam_up_local(),
	)
	_local_map.show()

	var cell: Dictionary = _lod_cells[_current_lod][idx] as Dictionary
	_hex_map_2d.call("setup",
		cell["type"] as int,
		cell["height"] as float,
		_land_threshold,
		_local_map.get_ring1_data(),
		noise_seed + idx,
	)
	_hex_map_2d.show()


func _on_cell_selected(idx: int) -> void:
	if idx < 0:
		_locking = false
		_local_map.hide()
		return
	var cell: Dictionary = _lod_cells[_current_lod][idx] as Dictionary
	_lock_cell_local = cell["position"] as Vector3
	_locking = true
	if planet_gridmap.is_occupied(idx):
		_show_local_map(idx)
	else:
		_local_map.hide()


func _on_cell_occupied(idx: int) -> void:
	_show_local_map(idx)


func _on_cell_vacated(idx: int) -> void:
	_local_map.hide()
	_hex_map_2d.hide()
