class_name ChunkMesher
extends RefCounted
# Construit le maillage d'un chunk à partir de ses données RLE (ChunkData),
# en ne parcourant que la surface : le terrain plein n'expose que son dessus
# et ses flancs (là où la colonne voisine est plus basse) ; seuls les blocs
# d'arbre, rares, sont testés sur leurs 6 faces. Le volume n'est jamais
# balayé, donc la hauteur du chunk n'a aucun coût.

const FACE_TOP := 0
const FACE_BOTTOM := 1
const FACE_SIDE := 2

const BLOCKS := {
	0: {"name" : "Air", "solid" : false},
	1: {"name" : "Grass", "solid" : true, "colors" : {FACE_TOP :Color(0.137, 0.902, 0.137, 1.0), FACE_BOTTOM : Color(0.137, 0.902, 0.137, 1.0), FACE_SIDE : Color(0.137, 0.902, 0.137, 1.0)}},
	2: {"name" : "Wood", "solid" : true, "colors" : {FACE_TOP :Color(0.42, 0.27, 0.11, 1.0), FACE_BOTTOM : Color(0.42, 0.27, 0.11, 1.0), FACE_SIDE : Color(0.48, 0.31, 0.14, 1.0)}},
	3: {"name" : "Leaves", "solid" : true, "colors" : {FACE_TOP :Color(0.10, 0.55, 0.12, 1.0), FACE_BOTTOM : Color(0.10, 0.55, 0.12, 1.0), FACE_SIDE : Color(0.10, 0.55, 0.12, 1.0)}},
}

const DIRECTIONS := [Vector3.UP, Vector3.DOWN, Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK]
const SIDE_DIRECTIONS := [Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK]

const FACE_SHADE := {
	Vector3.UP: 1.0,
	Vector3.DOWN: 0.5,
	Vector3.LEFT: 0.6,
	Vector3.RIGHT: 0.6,
	Vector3.FORWARD: 0.8,
	Vector3.BACK: 0.8,
}

# Coins de chaque face en demi-blocs, ordre = winding horaire vu de face
const FACE_CORNERS := {
	Vector3.UP: [Vector3(-1, 1, -1), Vector3(1, 1, -1), Vector3(1, 1, 1), Vector3(-1, 1, 1)],
	Vector3.DOWN: [Vector3(-1, -1, 1), Vector3(1, -1, 1), Vector3(1, -1, -1), Vector3(-1, -1, -1)],
	Vector3.LEFT: [Vector3(-1, -1, -1), Vector3(-1, 1, -1), Vector3(-1, 1, 1), Vector3(-1, -1, 1)],
	Vector3.RIGHT: [Vector3(1, -1, 1), Vector3(1, 1, 1), Vector3(1, 1, -1), Vector3(1, -1, -1)],
	Vector3.FORWARD: [Vector3(-1, -1, -1), Vector3(1, -1, -1), Vector3(1, 1, -1), Vector3(-1, 1, -1)],
	Vector3.BACK: [Vector3(-1, 1, 1), Vector3(1, 1, 1), Vector3(1, -1, 1), Vector3(-1, -1, 1)],
}

var _verts := PackedVector3Array()
var _norms := PackedVector3Array()
var _cols := PackedColorArray()
var _shaded := {}  # couleurs pré-ombrées : _shaded[direction][id de bloc]

static func build(data : ChunkData) -> ArrayMesh:
	return ChunkMesher.new()._build(data)

static func block_color_for_face(block_id : int, face_dir : Vector3) -> Color:
	var colors = BLOCKS[block_id]["colors"]
	var color : Color
	if face_dir == Vector3.UP:
		color = colors[FACE_TOP]
	elif face_dir == Vector3.DOWN:
		color = colors[FACE_BOTTOM]
	else:
		color = colors[FACE_SIDE]
	var shade : float = FACE_SHADE[face_dir]
	return Color(color.r * shade, color.g * shade, color.b * shade, color.a)

func _build(data : ChunkData) -> ArrayMesh:
	# extremity bound : chunk sans aucun bloc -> pas de maillage du tout
	if data.top_solid_y < 0:
		return null

	for dir in DIRECTIONS:
		_shaded[dir] = [Color(), block_color_for_face(1, dir), block_color_for_face(2, dir), block_color_for_face(3, dir)]

	var height := WorldConfig.HEIGHT

	for x in range(WorldConfig.WIDTH):
		for z in range(WorldConfig.DEPTH):
			var top_y := mini(data.col_top(x, z), height - 1)

			# dessus (sauf si un tronc d'arbre est posé dessus)
			if top_y >= 0 and data.block_at(x, top_y + 1, z) == 0:
				_emit_face(Vector3.UP, x, top_y, z, 1)
			# pas de faces du dessous : le terrain est plein jusqu'en bas

			for dir in SIDE_DIRECTIONS:
				var di := Vector3i(dir)
				var n_top : int = data.col_top(x + di.x, z + di.z)
				# flancs exposés : uniquement au-dessus du sommet de la
				# colonne voisine (en dessous, le voisin est plein)
				for y in range(maxi(n_top + 1, 0), top_y + 1):
					if data.block_at(x + di.x, y, z + di.z) == 0:
						_emit_face(dir, x, y, z, 1)

	for pos in data.tree_blocks:
		var lx : int = pos.x - data.chunk_position.x * WorldConfig.WIDTH
		var ly : int = pos.y - data.chunk_position.y * height
		var lz : int = pos.z - data.chunk_position.z * WorldConfig.DEPTH
		if lx < 0 or lx >= WorldConfig.WIDTH or ly < 0 or ly >= height or lz < 0 or lz >= WorldConfig.DEPTH:
			continue
		var id := data.block_at(lx, ly, lz)
		if id < 2:
			continue  # emplacement finalement occupé par le terrain
		for dir in DIRECTIONS:
			var di := Vector3i(dir)
			if data.block_at(lx + di.x, ly + di.y, lz + di.z) == 0:
				_emit_face(dir, lx, ly, lz, id)

	if _verts.is_empty():
		return null

	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _verts
	arrays[Mesh.ARRAY_NORMAL] = _norms
	arrays[Mesh.ARRAY_COLOR] = _cols

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

func _emit_face(dir : Vector3, x : int, y : int, z : int, id : int) -> void:
	var corners : Array = FACE_CORNERS[dir]
	var half := 0.5 * WorldConfig.CUBE_SIZE
	var p := Vector3(x, y, z) * WorldConfig.CUBE_SIZE
	var v0 : Vector3 = p + corners[0] * half
	var v1 : Vector3 = p + corners[1] * half
	var v2 : Vector3 = p + corners[2] * half
	var v3 : Vector3 = p + corners[3] * half
	_verts.push_back(v0)
	_verts.push_back(v1)
	_verts.push_back(v2)
	_verts.push_back(v0)
	_verts.push_back(v2)
	_verts.push_back(v3)
	var color : Color = _shaded[dir][id]
	for i in range(6):
		_norms.push_back(dir)
		_cols.push_back(color)
