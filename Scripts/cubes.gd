class_name Chunk
extends MeshInstance3D


var cube_mesh : ArrayMesh

const width : int = 16
const height : int = 16
const depth : int = 16
const cube_size : float = 1.0
const min_h : int = 4
const max_h : int = 12

const QUAD_UVS := [
	Vector2(0, 1),
	Vector2(1, 1),
	Vector2(1, 0),
	Vector2(0, 0)
]

@export var atlas_texture: Texture2DArray
@export var atlas_cols: int = 2

@export var chunk_position : Vector3i
@export var noise : FastNoiseLite

var voxels : Array = []
var rng := RandomNumberGenerator.new()

const FACE_TOP := 0
const FACE_BOTTOM := 1
const FACE_SIDE := 2

const BLOCKS :={
	0: {"name" : "Air", "solid" : false, "tiles" : {FACE_TOP : Vector2i(0,0), FACE_BOTTOM : Vector2i(0,0), FACE_SIDE : Vector2i(0,0)}},
	1: {"name" : "Grass", "solid" : true, "tiles" : {FACE_TOP : Vector2i(0,0), FACE_BOTTOM : Vector2i(1,0), FACE_SIDE : Vector2i(1,0)}},
	2: {"name" : "Stone", "solid" : true, "tiles" : {FACE_TOP : Vector2i(1,1), FACE_BOTTOM : Vector2i(1,1), FACE_SIDE : Vector2i(1,1)}}
}

func generate_chunk() -> void:
	voxels = generate_voxels()
	generate_mesh(voxels)

func generate_mesh(voxels):
	var faces = []
	
	for x in range(voxels.size()):
		for y in range(voxels[x].size()):
			for z in range(voxels[x][y].size()):
				var block_id : int = voxels[x][y][z]
				if block_id == 0:
					continue
				
				if voxels[x][y][z] != 0:
					var position = Vector3(x,y,z) * cube_size
					
					if is_air(x - 1, y, z):
						var t := block_layer_for_face(block_id, Vector3.LEFT)
						faces.append(create_face(Vector3.LEFT, position, t))
						
					if is_air(x + 1, y, z):
						var t := block_layer_for_face(block_id, Vector3.RIGHT)
						faces.append(create_face(Vector3.RIGHT, position, t))
					
					if is_air(x, y - 1, z):
						var t := block_layer_for_face(block_id, Vector3.DOWN)
						faces.append(create_face(Vector3.DOWN, position, t))
					
					if is_air(x, y + 1, z):
						var t := block_layer_for_face(block_id, Vector3.UP)
						faces.append(create_face(Vector3.UP, position, t))
					
					if is_air(x, y, z - 1):
						var t := block_layer_for_face(block_id, Vector3.FORWARD)
						faces.append(create_face(Vector3.FORWARD, position, t))
					
					if is_air(x, y, z + 1):
						var t := block_layer_for_face(block_id, Vector3.BACK)
						faces.append(create_face(Vector3.BACK, position, t))
	
	var vertices = []
	var normals = []
	var uvs = []
	var layers = []
	
	for face in faces:
		vertices += face["vertices"]
		normals += face["normals"]
		uvs += face["uvs"]
		layers += face["layers"]
	
	var vertex_array = PackedVector3Array(vertices)
	var normal_array = PackedVector3Array(normals)
	var uvs_array = PackedVector3Array(uvs)
	var layers_array = PackedFloat32Array(layers)
	
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertex_array
	arrays[Mesh.ARRAY_NORMAL] = normal_array
	arrays[Mesh.ARRAY_TEX_UV] = uvs_array
	arrays[Mesh.ARRAY_CUSTOM0] = layers_array
	
	cube_mesh = ArrayMesh.new()
	cube_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, Mesh.ARRAY_CUSTOM_R_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	
	self.mesh = cube_mesh

func generate_voxels() -> Array:
	
	var array = []
	array.resize(width)
	
	for x in range(width):
		array[x] = []
		array[x].resize(height)
		
		for y in range(height):
			array[x][y] = []
			array[x][y].resize(depth)
	
	for x in range(width):
		for y in range(height):
			for z in range(depth):
				var gx = chunk_position.x * width + x
				var gz = chunk_position.z * depth + z
				var h = int(remap(noise.get_noise_2d(gx, gz), -1.0, 1.0, min_h, max_h))
				array[x][y][z] = 1 if (chunk_position.y * height + y) <= h else 0
	
	return array

func create_face(direction: Vector3, position: Vector3, layer: int) -> Dictionary:
	var vertices = []
	var normals = []
	var uvs = []
	
	normals.resize(4)
	
	match direction:
		Vector3.UP:
			vertices =[
				position + Vector3(-0.5, 0.5, -0.5) * cube_size,
				position + Vector3(0.5, 0.5, -0.5) * cube_size,
				position + Vector3(0.5, 0.5, 0.5) * cube_size,
				position + Vector3(-0.5, 0.5, 0.5) * cube_size
			]
			normals.fill(Vector3.UP)
			uvs = QUAD_UVS
		Vector3.DOWN:
			vertices = [
				position + Vector3(-0.5, -0.5, 0.5) * cube_size,
				position + Vector3(0.5, -0.5, 0.5) * cube_size,
				position + Vector3(0.5, -0.5, -0.5) * cube_size,
				position + Vector3(-0.5, -0.5, -0.5) * cube_size
			]
			normals.fill(Vector3.DOWN)
			uvs = QUAD_UVS
		Vector3.LEFT:
			vertices =[
				position + Vector3(-0.5, -0.5, -0.5) * cube_size,
				position + Vector3(-0.5, 0.5, -0.5) * cube_size,
				position + Vector3(-0.5, 0.5, 0.5) * cube_size,
				position + Vector3(-0.5, -0.5, 0.5) * cube_size
			]
			normals.fill(Vector3.LEFT)
			uvs = QUAD_UVS
		Vector3.RIGHT:
			vertices =[
				position + Vector3(0.5, -0.5, 0.5) * cube_size,
				position + Vector3(0.5, 0.5, 0.5) * cube_size,
				position + Vector3(0.5, 0.5, -0.5) * cube_size,
				position + Vector3(0.5, -0.5, -0.5) * cube_size
			]
			normals.fill(Vector3.RIGHT)
			uvs = QUAD_UVS
		Vector3.FORWARD:
			vertices =[
				position + Vector3(-0.5, -0.5, -0.5) * cube_size,
				position + Vector3(0.5, -0.5, -0.5) * cube_size,
				position + Vector3(0.5, 0.5, -0.5) * cube_size,
				position + Vector3(-0.5, 0.5, -0.5) * cube_size
			]
			normals.fill(Vector3.FORWARD)
			uvs = QUAD_UVS
		Vector3.BACK:
			vertices =[
				position + Vector3(-0.5, 0.5, 0.5) * cube_size,
				position + Vector3(0.5, 0.5, 0.5) * cube_size,
				position + Vector3(0.5, -0.5, 0.5) * cube_size,
				position + Vector3(-0.5, -0.5, 0.5) * cube_size
			]
			normals.fill(Vector3.BACK)
			uvs = QUAD_UVS
	
	return {
		"vertices" :[
			vertices[0], vertices[1], vertices[2],
			vertices[0], vertices[2], vertices[3]
		],
		"normals" :[
			normals[0], normals[1], normals[2],
			normals[0], normals[2], normals[3]
		],
		"uvs" :[
			uvs[0], uvs[1], uvs[2],
			uvs[0], uvs[2], uvs[3]
		],
		"layers" : [layer, layer, layer, layer, layer, layer]
	}

func block_layer_for_face(block_id : int, face_dir : Vector3) -> int:
	var t := block_tile_for_face(block_id, face_dir)
	return t.y * atlas_cols + t.x

func block_tile_for_face(block_id : int, face_dir: Vector3) -> Vector2i:
	var block = BLOCKS.get(block_id, BLOCKS[0])
	var tiles = block["tiles"]
	
	if face_dir == Vector3.UP:
		return tiles[FACE_TOP]
	elif face_dir == Vector3.DOWN:
		return tiles[FACE_BOTTOM]
	else:
		return tiles[FACE_SIDE]

func height_at(gx : int, gz : int) -> int:
	return int(remap(noise.get_noise_2d(gx,gz),-1.0, 1.0, min_h, max_h))

func is_solid_at(gx : int, gy : int, gz : int) -> bool:
	return gy <= height_at(gx, gz)

func is_air(x : int, y : int, z : int) -> bool:
	if x >= 0 and x < width and y >= 0 and y < height and z >= 0 and z < depth:
		return voxels[x][y][z] == 0
	return not is_solid_at(
		chunk_position.x * width + x,
		chunk_position.y * height + y,
		chunk_position.z * depth + z 
	)
