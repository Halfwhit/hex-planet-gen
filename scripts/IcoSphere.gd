class_name IcoSphere
extends RefCounted


## Each face is [i0: int, i1: int, i2: int].
var faces: Array[Array] = []
var vertices: PackedVector3Array


## Build an icosphere with the given number of subdivision passes (0 = plain icosahedron).
## Populates vertices and faces; safe to call multiple times to regenerate at a new detail level.
func generate(subdivisions: int) -> void:
	vertices = PackedVector3Array()
	faces = []
	var edge_cache: Dictionary = {}

	# (1 + sqrt(5)) / 2
	const PHI: float = 1.6180339887498949
	var raw: Array[Vector3] = [
		Vector3(-1.0,  PHI,  0.0), Vector3( 1.0,  PHI,  0.0),
		Vector3(-1.0, -PHI,  0.0), Vector3( 1.0, -PHI,  0.0),
		Vector3( 0.0, -1.0,  PHI), Vector3( 0.0,  1.0,  PHI),
		Vector3( 0.0, -1.0, -PHI), Vector3( 0.0,  1.0, -PHI),
		Vector3( PHI,  0.0, -1.0), Vector3( PHI,  0.0,  1.0),
		Vector3(-PHI,  0.0, -1.0), Vector3(-PHI,  0.0,  1.0),
	]
	# Rotate the icosahedron so that vertex 1 (1, φ, 0) aligns with (0, 1, 0) and
	# its antipode (vertex 2) aligns with (0, -1, 0).  This places one pentagon
	# cell at each geographic pole (local ±Y), making the axial tilt visually
	# apparent: the poles sit at the blue RotationAxis line, not the amber TrueNorthAxis.
	# The alignment angle is atan(1/φ) ≈ 31.7°, derived from the icosahedron geometry.
	var align: Basis = Basis.from_euler(Vector3(0.0, 0.0, atan(1.0 / PHI)))
	for v: Vector3 in raw:
		vertices.append((align * v).normalized())

	faces = [
		[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
		[1, 5, 9],  [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
		[3, 9, 4],  [3, 4, 2],  [3, 2, 6],   [3, 6, 8],  [3, 8, 9],
		[4, 9, 5],  [2, 4, 11], [6, 2, 10],  [8, 6, 7],  [9, 8, 1],
	]

	for _i: int in subdivisions:
		var new_faces: Array[Array] = []
		for face: Array in faces:
			var a: int = _midpoint(face[0], face[1], edge_cache)
			var b: int = _midpoint(face[1], face[2], edge_cache)
			var c: int = _midpoint(face[2], face[0], edge_cache)
			new_faces.append([face[0], a, c])
			new_faces.append([face[1], b, a])
			new_faces.append([face[2], c, b])
			new_faces.append([a, b, c])
		faces = new_faces


func _midpoint(a: int, b: int, cache: Dictionary) -> int:
	var lo: int = min(a, b)
	var hi: int = max(a, b)
	var key: int = (lo << 20) | hi
	if key in cache:
		return cache[key]
	var mid: Vector3 = ((vertices[a] + vertices[b]) * 0.5).normalized()
	vertices.append(mid)
	var idx: int = vertices.size() - 1
	cache[key] = idx
	return idx
