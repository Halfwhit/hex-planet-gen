class_name OrbitCamera
extends Node3D


signal zoom_changed(distance: float)

@export var min_distance: float = 3.0
@export var max_distance: float = 12.0
@export var orbit_speed: float = 0.005
@export var zoom_speed: float = 0.3

var _dragging: bool = false
var _distance: float = 5.0
var _pitch: float = 0.0
var _yaw: float = 0.0

@onready var camera: Camera3D = $Camera3D


func _ready() -> void:
	_apply_transform()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				_dragging = mb.pressed
			MOUSE_BUTTON_WHEEL_UP:
				_set_distance(_distance - zoom_speed)
			MOUSE_BUTTON_WHEEL_DOWN:
				_set_distance(_distance + zoom_speed)
	elif event is InputEventMouseMotion and _dragging:
		var mm: InputEventMouseMotion = event as InputEventMouseMotion
		_yaw -= mm.relative.x * orbit_speed
		_pitch -= mm.relative.y * orbit_speed
		_pitch = clamp(_pitch, -PI * 0.48, PI * 0.48)
		rotation = Vector3(_pitch, _yaw, 0.0)


func get_distance() -> float:
	return _distance


func set_distance_limits(p_min: float, p_max: float) -> void:
	min_distance = p_min
	max_distance = p_max
	_set_distance(_distance)


func _apply_transform() -> void:
	if camera:
		camera.position = Vector3(0.0, 0.0, _distance)


func _set_distance(value: float) -> void:
	var clamped: float = clamp(value, min_distance, max_distance)
	if clamped == _distance:
		return
	_distance = clamped
	_apply_transform()
	zoom_changed.emit(_distance)
