@tool
class_name Sun
extends Node3D


## Distance from the planet centre to the sun in world units.
@export var sun_distance: float = 10.0
## Orbit speed in degrees per second (positive = counter-clockwise viewed from above).
@export var sun_orbit_speed: float = 3.0
## Tilt of the orbital plane in degrees (0 = orbits in world X/Y, 23.5 = Earth-like).
@export var sun_inclination: float = 15.0
## Colour of the sun light and emissive sphere.
@export var sun_color: Color = Color(1.0, 0.92, 0.6, 1.0)
## Radius of the visible sun sphere in world units.
@export var sun_size: float = 0.35
## OmniLight3D brightness.
@export var sun_light_energy: float = 2.5
## OmniLight3D range — how far the light reaches.
@export var sun_light_range: float = 40.0

var _angle: float = 0.0
var _planet_position: Vector3 = Vector3.ZERO
var _light: OmniLight3D
var _mesh_instance: MeshInstance3D


## Returns the current world-space position where the planet should sit.
## Main.gd reads this each frame and moves the planet pivot there.
func get_planet_position() -> Vector3:
	return _planet_position


func _ready() -> void:
	_build_sun()


func _build_sun() -> void:
	# Clear stale children when the tool script re-runs in the editor.
	for c: Node in get_children():
		c.queue_free()

	# ── Emissive sphere ──────────────────────────────────────────────────────
	var sphere: SphereMesh = SphereMesh.new()
	sphere.radius = sun_size
	sphere.height = sun_size * 2.0
	sphere.radial_segments = 32
	sphere.rings = 16

	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = sun_color
	mat.emission_enabled = true
	mat.emission = sun_color
	mat.emission_energy_multiplier = 6.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "SunMesh"
	_mesh_instance.mesh = sphere
	_mesh_instance.material_override = mat
	add_child(_mesh_instance)

	# ── Light ────────────────────────────────────────────────────────────────
	_light = OmniLight3D.new()
	_light.name = "SunLight"
	_light.light_color = sun_color
	_light.light_energy = sun_light_energy
	_light.omni_range = sun_light_range
	_light.shadow_enabled = true
	add_child(_light)

	_update_position()


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_angle += deg_to_rad(sun_orbit_speed) * delta
	_update_position()


func _update_position() -> void:
	# Compute where the planet should be: orbiting the sun (which sits at
	# world origin).  The sun node does not move — only the planet pivot does.
	var flat_x: float = cos(_angle) * sun_distance
	var flat_y: float = sin(_angle) * sun_distance
	var tilt: float = deg_to_rad(sun_inclination)
	_planet_position = Vector3(flat_x, flat_y * sin(tilt), flat_y * cos(tilt))
