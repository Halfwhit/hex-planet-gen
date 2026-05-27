@tool
extends Node3D


const MODE_SOLAR: int = 0
const MODE_FOCUS: int = 1

## Highlight the 12 pentagon tiles in magenta for debugging purposes.
@export var debug_pentagons: bool = false
## Colour cells by tectonic plate instead of biome (bright = continental, dark = oceanic).
@export var debug_plates: bool = false

# Untyped so Planet methods resolve via dynamic dispatch at runtime.
# Planet type annotation is avoided here because @tool load order makes it
# unavailable at parse time when Main.gd is compiled first.
var _planets: Array = []
var _focused_planet = null  # Planet node or null
var _camera_mode: int = MODE_SOLAR

@onready var _lod_label: Label = $UI/LODLabel
@onready var _orbit_camera: OrbitCamera = $OrbitCamera


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	# Collect child nodes that expose the Planet public API.
	for child: Node in get_children():
		if child.has_method("get_world_position"):
			_planets.append(child)
			child.setup(_orbit_camera.camera)
			child.lod_changed.connect(_on_lod_changed)

	_enter_solar_mode()


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return

	# In focus mode, keep the orbit camera centred on the moving planet.
	if _camera_mode == MODE_FOCUS and _focused_planet != null:
		_orbit_camera.set_orbit_center(_focused_planet.get_world_position())


func _input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return

	if event is InputEventKey:
		var ke: InputEventKey = event as InputEventKey
		if ke.pressed and ke.keycode == KEY_ESCAPE:
			_enter_solar_mode()
			return

	if _camera_mode == MODE_SOLAR and event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_try_focus_planet(mb.position)


func _enter_solar_mode() -> void:
	_camera_mode = MODE_SOLAR
	_focused_planet = null
	_orbit_camera.snap_orbit_center(Vector3.ZERO)

	# Wide zoom limits so all planets are visible.
	var max_orbit: float = 0.0
	for p in _planets:
		max_orbit = maxf(max_orbit, p.orbit_distance as float)
	if max_orbit > 0.0:
		_orbit_camera.set_distance_limits(max_orbit * 0.3, max_orbit * 3.0)
		_orbit_camera.set_distance(max_orbit * 1.8)

	for p in _planets:
		p.set_interactive(false)


func _enter_focus_mode(planet) -> void:
	_camera_mode = MODE_FOCUS
	_focused_planet = planet
	var r: float = planet.get_radius() as float
	_orbit_camera.snap_orbit_center(planet.get_world_position())
	_orbit_camera.set_distance_limits(r * 1.1, r * 6.0)
	_orbit_camera.set_distance(r * 3.5)
	for p in _planets:
		p.set_interactive(p == planet)


## Ray-vs-sphere test against each planet. Enters focus mode for the closest hit.
func _try_focus_planet(screen_pos: Vector2) -> void:
	var cam: Camera3D = _orbit_camera.camera
	if cam == null:
		return
	var ray_origin: Vector3 = cam.project_ray_origin(screen_pos)
	var ray_dir: Vector3 = cam.project_ray_normal(screen_pos)

	var best_t: float = INF
	var best_planet = null

	for p in _planets:
		var center: Vector3 = p.get_world_position() as Vector3
		# Use planet_radius * 2 as pick radius so small planets are easier to click.
		var r: float = (p.get_radius() as float) * 2.0
		var oc: Vector3 = ray_origin - center
		var b: float = oc.dot(ray_dir)
		var c: float = oc.dot(oc) - r * r
		var disc: float = b * b - c
		if disc < 0.0:
			continue
		var t: float = -b - sqrt(disc)
		if t < 0.0:
			t = -b + sqrt(disc)
		if t > 0.0 and t < best_t:
			best_t = t
			best_planet = p

	if best_planet != null:
		_enter_focus_mode(best_planet)


func _on_lod_changed(lod: int, cell_count: int) -> void:
	if _lod_label:
		_lod_label.text = "LOD %d  (%d cells)" % [lod, cell_count]
