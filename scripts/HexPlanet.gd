class_name HexPlanet
extends RefCounted


const OCEAN: int = 0
const LAND: int = 1

## Each element is a Dictionary with keys: position, polygon, height, type.
var cells: Array[Dictionary] = []
var land_threshold: float = 0.0
var noise_scale: float = 1.0


func generate(
		ico: IcoSphere,
		noise: FastNoiseLite,
		p_land_threshold: float,
		p_noise_scale: float,
) -> void:
	land_threshold = p_land_threshold
	noise_scale = p_noise_scale
	cells = []

	var n_verts: int = ico.vertices.size()
	var n_faces: int = ico.faces.size()

	var face_centroids: PackedVector3Array
	face_centroids.resize(n_faces)
	for fi: int in n_faces:
		var f: Array = ico.faces[fi]
		var c: Vector3 = ico.vertices[f[0]] + ico.vertices[f[1]] + ico.vertices[f[2]]
		face_centroids[fi] = (c / 3.0).normalized()

	var vertex_to_faces: Array[Array] = []
	vertex_to_faces.resize(n_verts)
	for i: int in n_verts:
		vertex_to_faces[i] = []
	for fi: int in n_faces:
		var f: Array = ico.faces[fi]
		vertex_to_faces[f[0]].append(fi)
		vertex_to_faces[f[1]].append(fi)
		vertex_to_faces[f[2]].append(fi)

	for vi: int in n_verts:
		var pos: Vector3 = ico.vertices[vi]
		var adj: Array = vertex_to_faces[vi]

		var pts: Array[Vector3] = []
		for fi: int in adj:
			pts.append(face_centroids[fi])

		var polygon: PackedVector3Array = _sort_around(pos, pts)
		var h: float = noise.get_noise_3dv(pos * noise_scale)
		var terrain_type: int = LAND if h > land_threshold else OCEAN

		cells.append({
			"position": pos,
			"polygon": polygon,
			"height": h,
			"type": terrain_type,
			# Exactly 12 cells on any Goldberg polyhedron are pentagons (5 sides).
			# Flag them so renderers can treat them as landmarks.
			"pentagon": polygon.size() == 5,
		})


# Returns polygon corners in counter-clockwise order when viewed from outside
# the sphere — required for correct front-face winding in PlanetMesh.build().
func _sort_around(center: Vector3, points: Array[Vector3]) -> PackedVector3Array:
	var ref: Vector3 = Vector3.UP if abs(center.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var tangent: Vector3 = center.cross(ref).normalized()
	var bitangent: Vector3 = center.cross(tangent).normalized()

	var with_angle: Array[Array] = []
	for p: Vector3 in points:
		var angle: float = atan2(p.dot(bitangent), p.dot(tangent))
		with_angle.append([angle, p])
	with_angle.sort_custom(func(x: Array, y: Array) -> bool: return x[0] > y[0])

	var result: PackedVector3Array
	for pair: Array in with_angle:
		result.append(pair[1])
	return result
