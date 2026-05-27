class_name OrbitCamera
extends Node3D


signal zoom_changed(distance: float)
signal drag_started

@export var min_distance: float = 3.0
@export var max_distance: float = 12.0
@export var orbit_speed: float = 0.005
@export var zoom_speed: float = 0.3
## Maximum pitch in radians — prevents the camera from looking directly down
## the pole where the north-roll correction becomes degenerate.
@export_range(0.1, 1.55) var max_pitch: float = PI * 0.44
## Yaw rate (rad/s) applied while the camera is idle.
@export var idle_orbit_speed: float = 0.08
## Seconds of inactivity before idle orbit begins.
@export var idle_delay: float = 4.0
## Lerp speed (units/s) for orbit center transitions.
@export var transition_speed: float = 5.0

var _dragging: bool = false
var _distance: float = 5.0
var _pitch: float = 0.0
var _yaw: float = 0.0
var _idle_timer: float = 0.0
var _north: Vector3 = Vector3.UP
var _angles_dirty: bool = true
var _orbit_center: Vector3 = Vector3.ZERO
var _orbit_center_target: Vector3 = Vector3.ZERO
var _transitioning: bool = false

@onready var camera: Camera3D = $Camera3D


func _ready() -> void:
	_apply_transform()


func _process(delta: float) -> void:
	if _dragging:
		_idle_timer = 0.0
	else:
		_idle_timer += delta
		if _idle_timer > idle_delay:
			_yaw += idle_orbit_speed * delta
			_angles_dirty = true
	# Lerp orbit center toward target when a transition is active.
	if _transitioning:
		_orbit_center = _orbit_center.lerp(_orbit_center_target, clamp(transition_speed * delta, 0.0, 1.0))
		if _orbit_center.distance_to(_orbit_center_target) < 0.001:
			_orbit_center = _orbit_center_target
			_transitioning = false
		_apply_transform()
	# Apply north roll only when angles have changed.  Uses _pitch/_yaw directly
	# to avoid reading a potentially-stale global_transform after a rotation write.
	if _angles_dirty:
		_update_north_roll()
		_angles_dirty = false


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				_dragging = mb.pressed
				if _dragging:
					_idle_timer = 0.0
					drag_started.emit()
			MOUSE_BUTTON_WHEEL_UP:
				_idle_timer = 0.0
				_set_distance(_distance - zoom_speed)
			MOUSE_BUTTON_WHEEL_DOWN:
				_idle_timer = 0.0
				_set_distance(_distance + zoom_speed)
	elif event is InputEventMouseMotion and _dragging:
		var mm: InputEventMouseMotion = event as InputEventMouseMotion
		_yaw -= mm.relative.x * orbit_speed
		_pitch -= mm.relative.y * orbit_speed
		_pitch = clamp(_pitch, -max_pitch, max_pitch)
		rotation = Vector3(_pitch, _yaw, 0.0)
		_angles_dirty = true


## Call every frame with the planet's north-pole direction (world space).
## OrbitCamera will keep that direction at the top of the screen.
func set_north(north: Vector3) -> void:
	_north = north


## Returns the current camera distance from the orbit centre.
func get_distance() -> float:
	return _distance


## Set pitch and yaw directly; pitch is clamped to ±max_pitch.
func set_angles(pitch: float, yaw: float) -> void:
	_pitch = clamp(pitch, -max_pitch, max_pitch)
	_yaw = yaw
	rotation = Vector3(_pitch, _yaw, 0.0)
	_angles_dirty = true


## Drive pitch and yaw from a world-space direction vector (e.g. a selected tile position).
func set_angles_from_dir(dir: Vector3) -> void:
	# Treat external angle driving as "activity" so idle orbit never fights
	# with a tile-locked camera.  Main._process runs before OrbitCamera._process,
	# so resetting here keeps _idle_timer at ~delta rather than ever reaching
	# idle_delay while a tile is selected.
	_idle_timer = 0.0
	set_angles(-asin(clamp(dir.y, -1.0, 1.0)), atan2(dir.x, dir.z))


## Update min/max zoom distance and clamp the current distance into range.
func set_distance_limits(p_min: float, p_max: float) -> void:
	min_distance = p_min
	max_distance = p_max
	_set_distance(_distance)


## Begin a smooth transition of the orbit center to the given world-space target.
func set_orbit_center(target: Vector3) -> void:
	_orbit_center_target = target
	_transitioning = true


## Instantly move the orbit center to the given position with no lerp.
func snap_orbit_center(center: Vector3) -> void:
	_orbit_center = center
	_orbit_center_target = center
	_transitioning = false
	_apply_transform()


## Directly set the camera distance (public wrapper for _set_distance).
func set_distance(d: float) -> void:
	_set_distance(d)


func _update_north_roll() -> void:
	# Build the zero-roll basis directly from _pitch/_yaw so we never touch
	# global_transform (which may lag one frame after a rotation write).
	var basis0: Basis = Basis.from_euler(Vector3(_pitch, _yaw, 0.0))
	var cam_dir: Vector3 = basis0.z
	var n_perp: Vector3 = _north - _north.dot(cam_dir) * cam_dir
	if n_perp.length_squared() < 0.001:
		return
	n_perp = n_perp.normalized()
	rotation = Vector3(_pitch, _yaw, atan2(-n_perp.dot(basis0.x), n_perp.dot(basis0.y)))


func _apply_transform() -> void:
	# Move this node to the orbit center in world space so the camera orbits
	# the correct focal point regardless of the scene's node hierarchy.
	global_position = _orbit_center
	if camera:
		camera.position = Vector3(0.0, 0.0, _distance)


func _set_distance(value: float) -> void:
	var clamped: float = clamp(value, min_distance, max_distance)
	if clamped == _distance:
		return
	_distance = clamped
	_apply_transform()
	zoom_changed.emit(_distance)
