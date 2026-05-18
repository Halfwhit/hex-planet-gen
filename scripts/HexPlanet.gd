class_name HexPlanet
extends RefCounted

const OCEAN: int = 0
const LAND: int = 1

var cells: Array  # Array of Dictionary: {position, polygon, height, type}
var land_threshold: float = 0.0
var noise_scale: float = 1.0

func generate(
		ico: IcoSphere,
		noise: FastNoiseLite,
		p_land_threshold: float,
		p_noise_scale: float
) -> void:
	land_threshold = p_land_threshold
	noise_scale = p_noise_scale
	cells = []

	var n_verts: int = ico.vertices.size()
	var n_faces: int = ico.faces.size()

	# Compute normalised centroid for each triangle face
	var face_centroids: PackedVector3Array
	face_centroids.resize(n_faces)
	for fi in n_faces:
		var f: Array = ico.faces[fi]
		var c: Vector3 = ico.vertices[f[0]] + ico.vertices[f[1]] + ico.vertices[f[2]]
		face_centroids[fi] = (c / 3.0).normalized()

	# Map each vertex index → list of adjacent face indices
	var vertex_to_faces: Array = []
	vertex_to_faces.resize(n_verts)
	for i in n_verts:
		vertex_to_faces[i] = []
	for fi in n_faces:
		var f: Array = ico.faces[fi]
		vertex_to_faces[f[0]].append(fi)
		vertex_to_faces[f[1]].append(fi)
		vertex_to_faces[f[2]].append(fi)

	# Build one cell per vertex (dual polygon = surrounding face centroids)
	for vi in n_verts:
		var pos: Vector3 = ico.vertices[vi]
		var adj: Array = vertex_to_faces[vi]

		var pts: Array = []
		for fi in adj:
			pts.append(face_centroids[fi])

		var polygon: PackedVector3Array = _sort_around(pos, pts)
		var h: float = noise.get_noise_3dv(pos * noise_scale)
		var terrain_type: int = LAND if h > land_threshold else OCEAN

		cells.append({
			"position": pos,
			"polygon": polygon,
			"height": h,
			"type": terrain_type,
		})

# Sort polygon corner points angularly around `center` in the tangent plane.
# Returns them in counter-clockwise order when viewed from outside the sphere.
func _sort_around(center: Vector3, points: Array) -> PackedVector3Array:
	var ref: Vector3 = Vector3.UP if abs(center.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var tangent: Vector3 = center.cross(ref).normalized()
	var bitangent: Vector3 = center.cross(tangent).normalized()

	var with_angle: Array = []
	for p in points:
		var angle: float = atan2(p.dot(bitangent), p.dot(tangent))
		with_angle.append([angle, p])
	with_angle.sort_custom(func(x, y): return x[0] > y[0])

	var result: PackedVector3Array
	for pair in with_angle:
		result.append(pair[1])
	return result
