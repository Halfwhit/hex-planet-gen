class_name PlanetGridmap
extends Node3D


signal cell_hovered(index: int)
signal cell_selected(index: int)

const CLICK_THRESHOLD_PX: float = 8.0
const OUTLINE_ELEVATION: float = 1.003
const OUTLINE_WIDTH_FRACTION: float = 0.008

@export var hover_color: Color = Color(1.0, 1.0, 1.0, 0.7)
@export var hover_emission_energy: float = 2.0
@export var select_color: Color = Color(0.2, 0.85, 1.0, 1.0)
@export var select_emission_energy: float = 4.0

var _camera: Camera3D = null
var _planet_node: Node3D = null
var _cells: Array = []
var _cell_positions: PackedVector3Array = []
var _outline_cache: Dictionary = {}
var _radius: float = 1.0
var _hovered_idx: int = -1
var _selected_idx: int = -1
var _press_pos: Vector2 = Vector2.ZERO
var _pending_mouse_pos: Vector2 = Vector2.ZERO
var _mouse_moved: bool = false
var _hover_mi: MeshInstance3D
var _select_mi: MeshInstance3D
var _hover_mat: StandardMaterial3D
var _select_mat: StandardMaterial3D


func _ready() -> void:
	_hover_mat = _make_outline_material(hover_color, hover_emission_energy)
	_select_mat = _make_outline_material(select_color, select_emission_energy)

	_hover_mi = MeshInstance3D.new()
	_hover_mi.name = "HoverOutline"
	_hover_mi.material_override = _hover_mat
	add_child(_hover_mi)

	_select_mi = MeshInstance3D.new()
	_select_mi.name = "SelectOutline"
	_select_mi.material_override = _select_mat
	add_child(_select_mi)


func _process(_delta: float) -> void:
	if not _mouse_moved or _cells.is_empty():
		return
	_mouse_moved = false
	var idx: int = _raycast(_pending_mouse_pos)
	if idx != _hovered_idx:
		_hovered_idx = idx
		_hover_mi.mesh = _outline_for(idx)
		if idx >= 0:
			cell_hovered.emit(idx)


func _input(event: InputEvent) -> void:
	if _camera == null or _planet_node == null or _cells.is_empty():
		return

	if event is InputEventMouseMotion:
		var mm: InputEventMouseMotion = event as InputEventMouseMotion
		_pending_mouse_pos = mm.position
		_mouse_moved = true

	elif event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_press_pos = mb.position
			else:
				if mb.position.distance_to(_press_pos) < CLICK_THRESHOLD_PX:
					var idx: int = _raycast(mb.position)
					_selected_idx = idx
					_select_mi.mesh = _outline_for(idx)
					cell_selected.emit(idx)


func setup(camera: Camera3D, planet_node: Node3D, cells: Array, radius: float) -> void:
	_camera = camera
	_planet_node = planet_node
	_cells = cells
	_radius = radius
	_outline_cache.clear()

	_cell_positions.resize(cells.size())
	for i: int in cells.size():
		_cell_positions[i] = (cells[i] as Dictionary)["position"] as Vector3

	# Reparent outlines under the planet so they rotate with it.
	if _hover_mi.get_parent() != planet_node:
		_hover_mi.reparent(planet_node, false)
	if _select_mi.get_parent() != planet_node:
		_select_mi.reparent(planet_node, false)
	clear()


func clear() -> void:
	_hovered_idx = -1
	_selected_idx = -1
	_mouse_moved = false
	_hover_mi.mesh = null
	_select_mi.mesh = null


func _raycast(mouse_pos: Vector2) -> int:
	# Work in planet-local space so picking is correct regardless of the
	# planet node's world position or rotation.
	var inv: Transform3D = _planet_node.global_transform.affine_inverse()
	var local_origin: Vector3 = inv * _camera.global_position
	var local_dir: Vector3 = inv.basis * _camera.project_ray_normal(mouse_pos)

	var b: float = local_origin.dot(local_dir)
	var c: float = local_origin.dot(local_origin) - _radius * _radius
	var disc: float = b * b - c
	if disc < 0.0:
		return -1

	var t: float = -b - sqrt(disc)
	if t < 0.0:
		return -1

	var hit_dir: Vector3 = (local_origin + local_dir * t).normalized()

	var best_dot: float = -1.0
	var best_idx: int = -1
	for i: int in _cell_positions.size():
		var d: float = _cell_positions[i].dot(hit_dir)
		if d > best_dot:
			best_dot = d
			best_idx = i
	return best_idx


func _outline_for(cell_idx: int) -> ArrayMesh:
	if cell_idx < 0:
		return null
	if not _outline_cache.has(cell_idx):
		_outline_cache[cell_idx] = _build_outline(cell_idx)
	return _outline_cache[cell_idx] as ArrayMesh


func _build_outline(cell_idx: int) -> ArrayMesh:
	var cell: Dictionary = _cells[cell_idx] as Dictionary
	var poly: PackedVector3Array = cell["polygon"] as PackedVector3Array
	var n: int = poly.size()
	var elev: float = _radius * OUTLINE_ELEVATION
	var strip_w: float = _radius * OUTLINE_WIDTH_FRACTION
	var cell_center: Vector3 = (cell["position"] as Vector3) * elev

	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	for i: int in n:
		var p0: Vector3 = poly[i] * elev
		var p1: Vector3 = poly[(i + 1) % n] * elev

		var edge_mid: Vector3 = (p0 + p1) * 0.5
		var inward: Vector3 = (cell_center - edge_mid).normalized()

		var p0_i: Vector3 = p0 + inward * strip_w
		var p1_i: Vector3 = p1 + inward * strip_w

		st.set_normal(edge_mid.normalized())
		st.add_vertex(p0)
		st.add_vertex(p1)
		st.add_vertex(p1_i)
		st.add_vertex(p0)
		st.add_vertex(p1_i)
		st.add_vertex(p0_i)

	return st.commit()


func _make_outline_material(color: Color, emission_energy: float) -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.render_priority = 2
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(color.r, color.g, color.b, 1.0)
	mat.emission_energy_multiplier = emission_energy
	return mat
