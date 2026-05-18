class_name OrbitCamera
extends Node3D

signal zoom_changed(distance: float)

@export var min_distance: float = 3.0
@export var max_distance: float = 12.0
@export var orbit_speed: float = 0.005
@export var zoom_speed: float = 0.3

@onready var camera: Camera3D = $Camera3D

var _yaw: float = 0.0
var _pitch: float = 0.0
var _distance: float = 5.0
var _dragging: bool = false

func _ready() -> void:
	_apply_transform()

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				_dragging = event.pressed
			MOUSE_BUTTON_WHEEL_UP:
				_distance = clamp(_distance - zoom_speed, min_distance, max_distance)
				_apply_transform()
				emit_signal("zoom_changed", _distance)
			MOUSE_BUTTON_WHEEL_DOWN:
				_distance = clamp(_distance + zoom_speed, min_distance, max_distance)
				_apply_transform()
				emit_signal("zoom_changed", _distance)
	elif event is InputEventMouseMotion and _dragging:
		_yaw -= event.relative.x * orbit_speed
		_pitch -= event.relative.y * orbit_speed
		_pitch = clamp(_pitch, -PI * 0.48, PI * 0.48)
		rotation = Vector3(_pitch, _yaw, 0.0)

func get_distance() -> float:
	return _distance

func set_distance_limits(p_min: float, p_max: float) -> void:
	min_distance = p_min
	max_distance = p_max
	_distance = clamp(_distance, min_distance, max_distance)
	_apply_transform()

func _apply_transform() -> void:
	if camera:
		camera.position = Vector3(0.0, 0.0, _distance)
