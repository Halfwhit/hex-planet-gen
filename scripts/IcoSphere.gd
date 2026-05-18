class_name IcoSphere
extends RefCounted

var vertices: PackedVector3Array
var faces: Array  # Array of [i0, i1, i2]

func generate(subdivisions: int) -> void:
	vertices = PackedVector3Array()
	faces = []
	var edge_cache: Dictionary = {}

	# Standard icosahedron: 12 vertices using the golden ratio
	const T: float = 1.6180339887498949  # (1 + sqrt(5)) / 2
	var raw: Array = [
		Vector3(-1.0,  T,  0.0), Vector3( 1.0,  T,  0.0),
		Vector3(-1.0, -T,  0.0), Vector3( 1.0, -T,  0.0),
		Vector3( 0.0, -1.0,  T), Vector3( 0.0,  1.0,  T),
		Vector3( 0.0, -1.0, -T), Vector3( 0.0,  1.0, -T),
		Vector3( T,  0.0, -1.0), Vector3( T,  0.0,  1.0),
		Vector3(-T,  0.0, -1.0), Vector3(-T,  0.0,  1.0),
	]
	for v in raw:
		vertices.append(v.normalized())

	# 20 faces with consistent outward winding
	faces = [
		[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
		[1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
		[3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
		[4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1],
	]

	for _i in subdivisions:
		var new_faces: Array = []
		for face in faces:
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
