class_name PlanetGridmap
extends Node3D


signal cell_hovered(index: int)
signal cell_selected(index: int)
signal cell_occupied(index: int)
signal cell_vacated(index: int)

const CLICK_THRESHOLD_PX: float = 8.0
const OUTLINE_ELEVATION: float = 1.003
const FILL_ELEVATION: float = 1.004
const OUTLINE_WIDTH_FRACTION: float = 0.008

@export var hover_color: Color = Color(1.0, 1.0, 1.0, 0.7)
@export var hover_emission_energy: float = 2.0
@export var select_color: Color = Color(0.2, 0.85, 1.0, 1.0)
@export var select_emission_energy: float = 4.0
@export var occupy_color: Color = Color(0.2, 0.9, 0.45, 0.55)
@export var occupy_emission_energy: float = 1.5

var _camera: Camera3D = null
var _planet_node: Node3D = null
var _cells: Array = []
var _cell_positions: PackedVector3Array = []
var _neighbors: Array[Array] = []
var _occupied: Dictionary = {}
var _outline_cache: Dictionary = {}
var _fill_cache: Dictionary = {}
var _fill_mis: Dictionary = {}
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
var _occupy_mat: StandardMaterial3D


func _ready() -> void:
	_hover_mat = _make_outline_material(hover_color, hover_emission_energy)
	_select_mat = _make_outline_material(select_color, select_emission_energy)
	_occupy_mat = _make_outline_material(occupy_color, occupy_emission_energy)

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

	elif event is InputEventKey:
		var ke: InputEventKey = event as InputEventKey
		if ke.pressed and ke.keycode == KEY_E and _selected_idx >= 0:
			_toggle_occupy(_selected_idx)


func setup(camera: Camera3D, planet_node: Node3D, cells: Array, radius: float) -> void:
	_free_fill_nodes()
	_occupied.clear()
	_fill_cache.clear()

	_camera = camera
	_planet_node = planet_node
	_cells = cells
	_radius = radius
	_outline_cache.clear()

	_cell_positions.resize(cells.size())
	for i: int in cells.size():
		_cell_positions[i] = cells[i]["position"] as Vector3

	_build_neighbors()

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


func get_all_neighbors() -> Array[Array]:
	return _neighbors


func get_occupied_set() -> Dictionary:
	return _occupied


func is_occupied(idx: int) -> bool:
	return _occupied.has(idx)


## Minimum hop distance between any two occupied cells.
## Kept in sync with LocalMap.rings by Main.
var occupation_radius: int = 1


func can_occupy(idx: int) -> bool:
	# BFS outward up to occupation_radius hops; reject if any visited cell is
	# already occupied (the candidate cell itself is excluded from this check).
	var visited: Dictionary = {idx: true}
	var frontier: Array[int] = [idx]
	for _ring: int in occupation_radius:
		var next: Array[int] = []
		for cell: int in frontier:
			for nb: int in _neighbors[cell]:
				if visited.has(nb):
					continue
				if _occupied.has(nb):
					return false
				visited[nb] = true
				next.append(nb)
		frontier = next
	return true


func _build_neighbors() -> void:
	_neighbors.resize(_cells.size())
	for i: int in _cells.size():
		_neighbors[i] = []

	# Map each polygon vertex to the list of cells that contain it.
	# Vertices are snapped to a fixed-precision integer grid so that the same
	# geometric point computed via slightly different floating-point paths still
	# maps to the same dictionary key.
	const SNAP: float = 100000.0
	var vertex_to_cells: Dictionary = {}
	for i: int in _cells.size():
		var poly: PackedVector3Array = _cells[i]["polygon"] as PackedVector3Array
		for v: Vector3 in poly:
			var key: Vector3i = Vector3i(
				roundi(v.x * SNAP),
				roundi(v.y * SNAP),
				roundi(v.z * SNAP),
			)
			if not vertex_to_cells.has(key):
				vertex_to_cells[key] = []
			(vertex_to_cells[key] as Array).append(i)

	# Count shared vertices per cell pair; pairs sharing 2+ are edge-adjacent.
	# Key encodes the pair as a * MAX_CELLS + b with a < b.
	const MAX_CELLS: int = 20000
	var shared: Dictionary = {}
	for cells_at_v: Array in vertex_to_cells.values():
		var list: Array = cells_at_v
		for ai: int in list.size():
			for bi: int in range(ai + 1, list.size()):
				var a: int = list[ai]
				var b: int = list[bi]
				var pair: int = a * MAX_CELLS + b if a < b else b * MAX_CELLS + a
				shared[pair] = (shared.get(pair, 0) as int) + 1

	for pair: int in shared:
		if (shared[pair] as int) >= 2:
			var a: int = pair / MAX_CELLS
			var b: int = pair % MAX_CELLS
			_neighbors[a].append(b)
			_neighbors[b].append(a)


func _toggle_occupy(idx: int) -> void:
	if _occupied.has(idx):
		_occupied.erase(idx)
		if _fill_mis.has(idx):
			(_fill_mis[idx] as MeshInstance3D).queue_free()
			_fill_mis.erase(idx)
		cell_vacated.emit(idx)
	elif can_occupy(idx):
		_occupied[idx] = true
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.mesh = _fill_for(idx)
		mi.material_override = _occupy_mat
		_planet_node.add_child(mi)
		_fill_mis[idx] = mi
		cell_occupied.emit(idx)


func _free_fill_nodes() -> void:
	for mi: MeshInstance3D in _fill_mis.values():
		mi.queue_free()
	_fill_mis.clear()


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


func _fill_for(cell_idx: int) -> ArrayMesh:
	if not _fill_cache.has(cell_idx):
		_fill_cache[cell_idx] = _build_fill(cell_idx)
	return _fill_cache[cell_idx] as ArrayMesh


func _build_outline(cell_idx: int) -> ArrayMesh:
	var cell: Dictionary = _cells[cell_idx]
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


func _build_fill(cell_idx: int) -> ArrayMesh:
	var cell: Dictionary = _cells[cell_idx]
	var poly: PackedVector3Array = cell["polygon"] as PackedVector3Array
	var n: int = poly.size()
	var elev: float = _radius * FILL_ELEVATION
	var center: Vector3 = (cell["position"] as Vector3) * elev
	var normal: Vector3 = center.normalized()

	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_normal(normal)

	for i: int in n:
		st.add_vertex(center)
		st.add_vertex(poly[i] * elev)
		st.add_vertex(poly[(i + 1) % n] * elev)

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
