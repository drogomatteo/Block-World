class_name Chunk
extends MeshInstance3D
# Nœud chunk : orchestre la génération. Le contenu vit dans ChunkData (RLE),
# la hauteur du terrain dans TerrainHeight (bruit up-samplé + cache), les
# arbres dans TreeGen et le maillage dans ChunkMesher.

static var block_material : StandardMaterial3D

# Raccourcis vers la configuration et les tables partagées
const width : int = WorldConfig.WIDTH
const height : int = WorldConfig.HEIGHT
const depth : int = WorldConfig.DEPTH
const cube_size : float = WorldConfig.CUBE_SIZE
const BLOCKS := ChunkMesher.BLOCKS
const DIRECTIONS := ChunkMesher.DIRECTIONS

var chunk_position : Vector3i
@export var noise : FastNoiseLite
@export var generate_trees : bool = true

var data : ChunkData
var cube_mesh : ArrayMesh

var tree_blocks : Dictionary :
	get:
		return data.tree_blocks if data != null else {}

var top_solid_y : int :
	get:
		return data.top_solid_y if data != null else -1

func generate_chunk() -> void:
	var d := ChunkData.new()
	d.build(noise, chunk_position, generate_trees)
	apply_generated(d, ChunkMesher.build(d))

# Applique des données et un maillage préparés ailleurs (typiquement dans le
# thread de génération) : seul ce passage-ci touche le nœud, sur le thread
# principal.
func apply_generated(chunk_data : ChunkData, generated_mesh : ArrayMesh) -> void:
	data = chunk_data
	cube_mesh = generated_mesh
	if generated_mesh == null:
		self.mesh = null
		return

	if block_material == null:
		block_material = StandardMaterial3D.new()
		block_material.vertex_color_use_as_albedo = true
		block_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	generated_mesh.surface_set_material(0, block_material)
	self.mesh = generated_mesh

func block_at(x : int, y : int, z : int) -> int:
	return data.block_at(x, y, z)

func block_color_for_face(block_id : int, face_dir : Vector3) -> Color:
	return ChunkMesher.block_color_for_face(block_id, face_dir)

func height_at(gx : int, gz : int) -> int:
	return TerrainHeight.height_at(noise, gx, gz)

func is_solid_at(gx : int, gy : int, gz : int) -> bool:
	return gy <= height_at(gx, gz)

func is_air(x : int, y : int, z : int) -> bool:
	if x >= -1 and x <= width and y >= -1 and y <= height and z >= -1 and z <= depth:
		return data.block_at(x, y, z) == 0
	var g := Vector3i(
		chunk_position.x * width + x,
		chunk_position.y * height + y,
		chunk_position.z * depth + z
	)
	if tree_blocks.has(g):
		return false
	return not is_solid_at(g.x, g.y, g.z)

# --- Aides de vérification (utilisées par tests/smoke.gd) -----------------
# Reconstruisent les faces exposées par balayage de masques, indépendamment
# du chemin rapide de ChunkMesher.

func axis_info(direction : Vector3) -> Dictionary:
	if direction == Vector3.UP or direction == Vector3.DOWN:
		return {"slices": height, "u":width, "v":depth}
	elif direction == Vector3.LEFT or direction == Vector3.RIGHT:
		return {"slices":width, "u":depth, "v":height}
	else:
		return {"slices":depth, "u":width, "v":height}

func local_coords(direction : Vector3, s:int, u:int, v:int) -> Vector3i:
	if direction == Vector3.UP or direction == Vector3.DOWN:
		return Vector3i(u,s,v)
	elif direction == Vector3.LEFT or direction == Vector3.RIGHT:
		return Vector3i(s,v,u)
	else:
		return Vector3i(u,v,s)

func build_mask(direction:Vector3, s:int) -> Array:
	var info := axis_info(direction)
	var dir_i := Vector3i(direction)
	var mask := []
	mask.resize(info["u"])

	for u in range(info["u"]):
		mask[u] = []
		mask[u].resize(info["v"])

		for v in range(info["v"]):
			var p := local_coords(direction,s,u,v)
			var block_id : int = block_at(p.x, p.y, p.z)

			if block_id != 0 and is_air(p.x + dir_i.x, p.y + dir_i.y, p.z + dir_i.z):
				mask[u][v] = block_id
			else:
				mask[u][v] = -1

	return mask
