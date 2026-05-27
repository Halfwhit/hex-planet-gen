@tool
class_name Planet
extends Node3D


const LOD_SUBDIVISIONS: Array[int] = [2, 3, 4, 5]
# LOD switch distances expressed as multiples of planet_radius so they scale
# automatically when planet_radius changes.
const LOD_THRESHOLDS: Array[float] = [3.5, 2.5, 2.0]

const _HORIZON_SHADER: Shader = preload("res://shaders/HorizonMask.gdshader")
const _ATMOSPHERE_SHADER: Shader = preload("res://shaders/Atmosphere.gdshader")
const _PLANET_SHADER: Shader = preload("res://shaders/Planet.gdshader")


@export_group("Orbit")
## Distance from the sun (world origin) to the planet centre in world units.
@export var orbit_distance: float = 14.0
## Orbit speed in degrees per second around the sun.
@export var orbit_speed: float = 3.0
## Tilt of the orbital plane in degrees (0 = flat X/Z plane).
@export var orbit_inclination: float = 0.0
## Starting angle in degrees for this planet's orbital phase.
@export var orbit_phase: float = 0.0

@export_group("Planet")
## Radius of the planet sphere in world units; scales all LOD switch distances and atmosphere layers.
@export var planet_radius: float = 2.0
## Visual radius of the sun sphere. Used to compute the sun's apparent angular size
## (sun_radius / orbit_distance), which controls how wide the soft terminator is.
@export var sun_radius: float = 8.0
## Fraction of the planet surface that will be ocean (0 = all land, 1 = all ocean).
@export_range(0.0, 1.0) var ocean_fraction: float = 0.55
## Deterministic seed passed to all noise generators; change to get a different planet.
@export var noise_seed: int = 42
## Noise frequency multiplier for terrain height and biome variation.
@export var noise_scale: float = 1.5
## Tilt of the planet's spin axis in degrees relative to world Y.
@export var axial_tilt: float = 23.5
## Planet spin speed in degrees per second.
@export var rotation_speed: float = 4.0

@export_group("Atmosphere")
## Tint colour of the atmospheric glow rendered around the planet silhouette.
@export var atmosphere_color: Color = Color(0.3, 0.52, 1.0)
## Exponent of the Fresnel glow falloff — higher values make the glow thinner.
@export var atmosphere_power: float = 3.5
## Radius of the atmosphere sphere as a multiple of planet_radius.
@export var atmosphere_radius_factor: float = 1.08
## Overall brightness multiplier for the atmospheric glow.
@export var atmosphere_strength: float = 1.1
## Colour blended over polygon edges at the silhouette.
@export var horizon_mask_color: Color = Color(0.467, 0.467, 0.467)
## Exponent of the horizon fade — higher values give a sharper edge.
@export var horizon_mask_power: float = 10.0
## Overall strength of the horizon dissolve effect.
@export var horizon_mask_strength: float = 1.0

@export_group("Tectonics")
## Number of tectonic plates to generate.
@export_range(4, 32) var num_plates: int = 12
## Fraction of plates that are oceanic (low-lying); the rest are continental.
@export_range(0.0, 1.0) var oceanic_plate_fraction: float = 0.65
## Height multiplier for continental collision mountains (higher = taller ranges).
@export var mountain_height: float = 0.85
## Strength of the detail noise blended on top of the tectonic base (0 = perfectly smooth plates).
@export_range(0.0, 0.5) var detail_noise_strength: float = 0.15

@export_group("Occupation")
## Number of rings shown in the local map AND the minimum spacing between occupied cells.
@export_range(1, 5) var map_rings: int = 1

@export_group("Editor Preview")
@export_tool_button("Generate Planet", "MeshInstance3D")
var _gen_btn: Callable = _editor_generate
## Subdivision level used for the in-editor preview.
@export_range(2, 5) var editor_preview_subdivisions: int = 3
## Highlight the 12 pentagon tiles in magenta for debugging purposes.
@export var debug_pentagons: bool = false
## Colour cells by tectonic plate instead of biome.
@export var debug_plates: bool = false


# Signals
signal cell_occupied(planet: Planet, idx: int)
signal cell_vacated(planet: Planet, idx: int)
signal lod_changed(lod: int, cell_count: int)


# Private state
var _planet_pivot: Node3D = null
var _planet_mesh_instance: MeshInstance3D = null
var _orbit_angle: float = 0.0
var _camera: Camera3D = null
var _local_map: LocalMap = null
var _current_lod: int = 0
var _lod_meshes: Array[ArrayMesh] = []
var _lod_cells: Array = []
var _spin_angle: float = 0.0
var _land_threshold: float = 0.0
var _rotation_speed_rad: float = 0.0
var _tilt_basis: Basis = Basis.IDENTITY
var _lock_cell_local: Vector3 = Vector3.ZERO
var _locking: bool = false
var _interactive: bool = true


@onready var _planet_gridmap: PlanetGridmap = $PlanetGridmap


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	_rotation_speed_rad = deg_to_rad(rotation_speed)

	# Create pivot that holds all planet visuals (mesh, atmosphere, axis lines).
	_planet_pivot = Node3D.new()
	_planet_pivot.name = "PlanetPivot"
	add_child(_planet_pivot)

	# Reparent the PlanetMesh child under the pivot.
	_planet_mesh_instance = get_node_or_null("PlanetMesh") as MeshInstance3D
	if _planet_mesh_instance == null:
		_planet_mesh_instance = MeshInstance3D.new()
		_planet_mesh_instance.name = "PlanetMesh"
		_planet_pivot.add_child(_planet_mesh_instance)
	else:
		_planet_mesh_instance.reparent(_planet_pivot, false)
	_planet_mesh_instance.position = Vector3.ZERO

	# Set initial orbital angle from phase export.
	_orbit_angle = deg_to_rad(orbit_phase)
	# Place pivot at initial orbit position immediately so the planet doesn't
	# start at the origin on the first rendered frame.
	_update_orbit_position()

	_tilt_basis = Basis.from_euler(Vector3(0.0, 0.0, deg_to_rad(-axial_tilt)))
	_planet_mesh_instance.basis = _tilt_basis

	_generate_planet()
	_apply_planet_shader()
	_create_atmosphere()
	_create_axis_display()
	_create_orbit_ring()

	# LocalMap lives in a CanvasLayer child of Planet.
	var map_layer: CanvasLayer = CanvasLayer.new()
	map_layer.layer = 10
	add_child(map_layer)

	_local_map = LocalMap.new()
	_local_map.rings = map_rings
	_local_map.debug_pentagons = debug_pentagons
	_local_map.anchor_left = 0.58
	_local_map.anchor_right = 1.0
	_local_map.anchor_top = 0.1
	_local_map.anchor_bottom = 0.9
	map_layer.add_child(_local_map)
	_local_map.hide()
	_planet_gridmap.occupation_radius = map_rings


## Connect signals and store camera reference. Must be called by Main after
## the scene is ready.
func setup(camera: Camera3D) -> void:
	_camera = camera
	_planet_gridmap.cell_selected.connect(_on_cell_selected)
	_planet_gridmap.cell_occupied.connect(_on_cell_occupied)
	_planet_gridmap.cell_vacated.connect(_on_cell_vacated)

	_on_zoom_changed(camera.position.z if camera else planet_radius * 3.0)


## Returns the current world-space position of the planet pivot.
func get_world_position() -> Vector3:
	return _planet_pivot.global_position


## Returns the planet radius.
func get_radius() -> float:
	return planet_radius


## Enable or disable interactive cell picking on this planet.
func set_interactive(enabled: bool) -> void:
	_interactive = enabled
	_planet_gridmap.set_process_input(enabled)
	if not enabled:
		_planet_gridmap.clear()
		if _local_map != null:
			_local_map.hide()


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return

	# Advance orbit.
	_orbit_angle += deg_to_rad(orbit_speed) * delta
	_update_orbit_position()

	# Spin the planet mesh.
	_spin_angle += _rotation_speed_rad * delta
	var planet_basis: Basis = _tilt_basis * Basis(Vector3.UP, _spin_angle)
	_planet_mesh_instance.basis = planet_basis

	# Camera lock-on.
	if _locking and _camera != null:
		var orbit_cam: OrbitCamera = _camera.get_parent() as OrbitCamera
		if orbit_cam != null:
			orbit_cam.set_angles_from_dir((planet_basis * _lock_cell_local).normalized())


func _update_orbit_position() -> void:
	var orbit_x: float = cos(_orbit_angle) * orbit_distance
	var orbit_r: float = sin(_orbit_angle) * orbit_distance
	var tilt: float = deg_to_rad(orbit_inclination)
	_planet_pivot.position = Vector3(orbit_x, orbit_r * sin(tilt), orbit_r * cos(tilt))


func _editor_generate() -> void:
	if not Engine.is_editor_hint():
		return

	var mesh_node: MeshInstance3D = get_node_or_null("PlanetMesh") as MeshInstance3D
	if mesh_node == null:
		return

	var noise: FastNoiseLite = _make_noise()
	var ico: IcoSphere = IcoSphere.new()
	ico.generate(editor_preview_subdivisions)
	var planet: HexPlanet = HexPlanet.new()
	planet.generate(ico, noise, noise_scale, ocean_fraction,
			num_plates, oceanic_plate_fraction, mountain_height, detail_noise_strength)
	mesh_node.mesh = PlanetMesh.build(planet, planet_radius, debug_pentagons, debug_plates)

	for child_name: String in ["HorizonMask", "Atmosphere", "RotationAxis", "TrueNorthAxis"]:
		var pivot: Node3D = get_node_or_null("PlanetPivot") as Node3D
		if pivot == null:
			break
		var old: Node = pivot.get_node_or_null(child_name)
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

	_lod_meshes.clear()
	_lod_cells.clear()
	for sub: int in LOD_SUBDIVISIONS:
		var ico: IcoSphere = IcoSphere.new()
		ico.generate(sub)
		var planet: HexPlanet = HexPlanet.new()
		planet.generate(ico, noise, noise_scale, ocean_fraction,
				num_plates, oceanic_plate_fraction, mountain_height, detail_noise_strength)
		_lod_meshes.append(PlanetMesh.build(planet, planet_radius, debug_pentagons, debug_plates))
		_lod_cells.append(planet.cells)
		_land_threshold = planet.land_threshold

	_current_lod = -1  # force _set_lod(0) to apply unconditionally
	_set_lod(0)


func _set_lod(lod: int) -> void:
	if lod == _current_lod:
		return
	_current_lod = lod
	_planet_mesh_instance.mesh = _lod_meshes[_current_lod]
	var cells: Array = _lod_cells[_current_lod] if _current_lod == _lod_cells.size() - 1 else []
	var cam: Camera3D = _camera
	if cam == null and _planet_gridmap != null:
		cam = _planet_gridmap.get_viewport().get_camera_3d()
	_planet_gridmap.setup(cam, _planet_mesh_instance, cells, planet_radius)
	if _local_map != null:
		_local_map.hide()
	lod_changed.emit(lod, _lod_cells[_current_lod].size())


func _make_noise() -> FastNoiseLite:
	var n: FastNoiseLite = FastNoiseLite.new()
	n.seed = noise_seed
	n.frequency = 0.5
	n.fractal_octaves = 4
	return n


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
	_planet_pivot.add_child(mi)


func _create_atmosphere() -> void:
	if _planet_pivot == null:
		return
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
	if _planet_pivot == null:
		return
	var axis_length: float = planet_radius * 1.4
	_add_axis_line("RotationAxis", axis_length,
			Vector3(0.0, 0.0, -axial_tilt),
			Color(0.55, 0.80, 1.0),
			planet_radius * 0.012)
	_add_axis_line("TrueNorthAxis", axis_length,
			Vector3.ZERO,
			Color(1.0, 0.72, 0.2),
			planet_radius * 0.008)


func _apply_planet_shader() -> void:
	# material_override persists when _planet_mesh_instance.mesh is swapped for
	# a different LOD level, so we only need to set it once here.
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = _PLANET_SHADER
	mat.set_shader_parameter("sun_angular_size",
			sun_radius / max(orbit_distance, 0.001))
	_planet_mesh_instance.material_override = mat


func _create_orbit_ring() -> void:
	# Dotted circle at orbit_distance from the sun (world origin).
	# Added as a direct child of the Planet node (not _planet_pivot) so it
	# stays fixed in space while the planet moves around it.
	const SEGMENTS: int = 120
	const DOT_LEN: int = 3
	const GAP_LEN: int = 2

	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_LINES)
	for i: int in SEGMENTS:
		if i % (DOT_LEN + GAP_LEN) >= DOT_LEN:
			continue
		var a0: float = TAU * float(i) / float(SEGMENTS)
		var a1: float = TAU * float(i + 1) / float(SEGMENTS)
		st.add_vertex(Vector3(cos(a0) * orbit_distance, 0.0, sin(a0) * orbit_distance))
		st.add_vertex(Vector3(cos(a1) * orbit_distance, 0.0, sin(a1) * orbit_distance))

	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.9, 0.9, 1.0, 0.35)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	mat.render_priority = 1

	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.name = "OrbitRing"
	mi.mesh = st.commit()
	mi.material_override = mat
	# Tilt the ring to match orbit_inclination (rotation around world X).
	mi.rotation_degrees = Vector3(orbit_inclination, 0.0, 0.0)
	add_child(mi)


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
	mat.no_depth_test = true
	mat.render_priority = 1

	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.name = line_name
	mi.mesh = cyl
	mi.material_override = mat
	mi.rotation_degrees = rotation_deg
	_planet_pivot.add_child(mi)


func _cam_up_local() -> Vector3:
	return (_planet_mesh_instance.global_transform.basis.inverse() * Vector3.UP).normalized()


func _show_local_map(idx: int) -> void:
	_local_map.setup(
		idx,
		_lod_cells[_current_lod],
		_planet_gridmap.get_all_neighbors(),
		_planet_gridmap.get_occupied_set(),
		_land_threshold,
		_cam_up_local(),
	)
	_local_map.show()


func _on_cell_selected(idx: int) -> void:
	if idx < 0:
		_locking = false
		_local_map.hide()
		return
	var cell: Dictionary = _lod_cells[_current_lod][idx]
	_lock_cell_local = cell["position"] as Vector3
	_locking = true
	if _planet_gridmap.is_occupied(idx):
		_show_local_map(idx)
	else:
		_local_map.hide()


func _on_cell_occupied(idx: int) -> void:
	_show_local_map(idx)
	cell_occupied.emit(self, idx)


func _on_cell_vacated(idx: int) -> void:
	_local_map.hide()
	cell_vacated.emit(self, idx)
