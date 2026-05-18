@tool
extends Node3D


const LOD_SUBDIVISIONS: Array[int] = [2, 3, 4, 5]
# Camera distance thresholds; closer than each threshold → higher LOD.
# At the default start distance of 5.0 this opens at LOD 2 (2562 cells).
const LOD_THRESHOLDS: Array[float] = [7.0, 5.0, 3.0]

const _HORIZON_SHADER: Shader = preload("res://shaders/HorizonMask.gdshader")
const _ATMOSPHERE_SHADER: Shader = preload("res://shaders/Atmosphere.gdshader")

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
@export var rotation_speed: float = 8.0

@export_group("Editor Preview")
@export_tool_button("Generate Planet", "MeshInstance3D")
var _gen_btn: Callable = _editor_generate
## Subdivision level used for the in-editor preview (2 = 162 cells, 3 = 642, 4 = 2562).
@export_range(2, 5) var editor_preview_subdivisions: int = 3

var _current_lod: int = 0
var _lod_meshes: Array[ArrayMesh] = []
var _rotation_speed_rad: float = 0.0
var _spin_axis: Vector3 = Vector3.ZERO

@onready var lod_label: Label = $UI/LODLabel
@onready var orbit_camera: OrbitCamera = $OrbitCamera
@onready var planet_mesh_instance: MeshInstance3D = $PlanetMesh


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_spin_axis = Vector3(sin(deg_to_rad(axial_tilt)), cos(deg_to_rad(axial_tilt)), 0.0)
	_rotation_speed_rad = deg_to_rad(rotation_speed)
	_generate_planet()
	_create_atmosphere()
	_create_axis_display()
	orbit_camera.set_distance_limits(planet_radius * 1.1, planet_radius * 6.0)
	orbit_camera.zoom_changed.connect(_on_zoom_changed)
	_on_zoom_changed(orbit_camera.get_distance())


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	planet_mesh_instance.rotate(_spin_axis, _rotation_speed_rad * delta)


func _editor_generate() -> void:
	if not Engine.is_editor_hint():
		return

	var noise: FastNoiseLite = _make_noise()
	var sea_level: float = _compute_sea_level(noise)
	var ico: IcoSphere = IcoSphere.new()
	ico.generate(editor_preview_subdivisions)
	var planet: HexPlanet = HexPlanet.new()
	planet.generate(ico, noise, sea_level, noise_scale)
	planet_mesh_instance.mesh = PlanetMesh.build(planet, planet_radius)

	for child_name: String in ["HorizonMask", "Atmosphere", "AxisDisplay"]:
		var old: Node = get_node_or_null(child_name)
		if old:
			old.free()
	_create_atmosphere()
	_create_axis_display()


func _on_zoom_changed(dist: float) -> void:
	var new_lod: int = 0
	for i: int in LOD_THRESHOLDS.size():
		if dist <= LOD_THRESHOLDS[i]:
			new_lod = i + 1
	_set_lod(new_lod)


func _generate_planet() -> void:
	var noise: FastNoiseLite = _make_noise()
	var sea_level: float = _compute_sea_level(noise)

	_lod_meshes.clear()
	for sub: int in LOD_SUBDIVISIONS:
		var ico: IcoSphere = IcoSphere.new()
		ico.generate(sub)
		var planet: HexPlanet = HexPlanet.new()
		planet.generate(ico, noise, sea_level, noise_scale)
		_lod_meshes.append(PlanetMesh.build(planet, planet_radius))

	_current_lod = -1  # force _set_lod(0) to apply unconditionally
	_set_lod(0)


func _set_lod(lod: int) -> void:
	if lod == _current_lod:
		return
	_current_lod = lod
	planet_mesh_instance.mesh = _lod_meshes[_current_lod]
	if lod_label:
		lod_label.text = "LOD %d  (%d cells)" % [lod, _cell_count(lod)]


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

	var cyl: CylinderMesh = CylinderMesh.new()
	cyl.height = axis_length * 2.0
	cyl.top_radius = planet_radius * 0.012
	cyl.bottom_radius = planet_radius * 0.012
	cyl.radial_segments = 8
	cyl.rings = 1

	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.92, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.6, 0.78, 1.0)
	mat.emission_energy_multiplier = 1.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.name = "AxisDisplay"
	mi.mesh = cyl
	mi.material_override = mat
	mi.rotation_degrees = Vector3(0.0, 0.0, -axial_tilt)
	add_child(mi)


func _cell_count(lod: int) -> int:
	# Vertices of subdivided icosphere: 10 * 4^n + 2
	var n: int = LOD_SUBDIVISIONS[lod]
	return 10 * (1 << (2 * n)) + 2
