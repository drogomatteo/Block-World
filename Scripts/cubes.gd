class_name Chunk
extends MeshInstance3D
# Nœud chunk : orchestre la génération. Le contenu vit dans ChunkData (RLE),
# la hauteur du terrain dans TerrainHeight (bruit up-samplé + cache), les
# arbres dans TreeGen et le maillage dans ChunkMesher.

static var block_material : ShaderMaterial
static var pulled_shader : Shader
static var show_borders : bool = false  # état F3, appliqué aux nouveaux matériaux

# Maillages « compteurs » du vertex pulling, PARTAGÉS entre tous les chunks :
# 4 sommets à zéro + 6 indices par rectangle, le vertex shader reconstruit la
# géométrie depuis la texture de données. Paliers pour ne pas payer le pire
# cas partout ; un chunk prend le plus petit palier suffisant.
static var _counter_meshes : Dictionary = {}
const BUCKETS := [64, 256, 1024, 4096, 16320]

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
# Rendu par vertex pulling (texture de rectangles + maillage compteur) au lieu
# d'un ArrayMesh par chunk. Le chemin classique reste disponible (flag off,
# et generate_chunk() des tests l'utilise toujours).
@export var vertex_pulling : bool = true

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
		block_material = ShaderMaterial.new()
		block_material.shader = load("res://Ressource/Shaders/chunk.gdshader")
		block_material.set_shader_parameter("block_size", WorldConfig.CUBE_SIZE)
		block_material.set_shader_parameter("chunk_span", WorldConfig.WIDTH * WorldConfig.CUBE_SIZE)
	generated_mesh.surface_set_material(0, block_material)
	self.mesh = generated_mesh

# Chemin vertex pulling : le chunk reçoit un maillage compteur partagé et un
# matériau à lui (la texture de rectangles est par chunk — les uniforms
# par-instance de Godot n'acceptent pas les sampler2D). packed vient de
# ChunkMesher.build_packed : {count, image}.
func apply_generated_packed(chunk_data : ChunkData, packed : Dictionary) -> void:
	data = chunk_data
	cube_mesh = null
	var count : int = packed["count"]
	if count == 0:
		self.mesh = null
		return
	if count > BUCKETS[-1]:
		# chunk plus dense que le plus grand palier : repli classique (rare)
		apply_generated(chunk_data, ChunkMesher.build(chunk_data))
		return

	if pulled_shader == null:
		pulled_shader = load("res://Ressource/Shaders/chunk_pulled.gdshader")
	var mat := ShaderMaterial.new()
	mat.shader = pulled_shader
	mat.set_shader_parameter("rect_data", ImageTexture.create_from_image(packed["image"]))
	mat.set_shader_parameter("quad_count", count)
	mat.set_shader_parameter("cell_size", WorldConfig.CUBE_SIZE * chunk_data.step)
	mat.set_shader_parameter("block_size", WorldConfig.CUBE_SIZE)
	mat.set_shader_parameter("chunk_span", WorldConfig.WIDTH * WorldConfig.CUBE_SIZE)
	if show_borders:
		mat.set_shader_parameter("show_chunk_borders", true)
	material_override = mat
	self.mesh = _counter_mesh(count)
	# les sommets du maillage compteur sont tous à zéro : l'AABB de culling
	# doit couvrir l'emprise réelle du nœud (step×step chunks au LOD)
	var s : int = chunk_data.step
	custom_aabb = AABB(Vector3(-2, -2, -2),
		Vector3(width * s + 4, height + 4, depth * s + 4) * cube_size)

# Plus petit maillage compteur couvrant `count` rectangles (créé à la demande,
# thread principal uniquement).
static func _counter_mesh(count : int) -> ArrayMesh:
	var size : int = BUCKETS[-1]
	for b in BUCKETS:
		if count <= b:
			size = b
			break
	if _counter_meshes.has(size):
		return _counter_meshes[size]
	var verts := PackedVector3Array()
	verts.resize(size * 4)  # tous à zéro : seule l'identité VERTEX_ID compte
	var idx := PackedInt32Array()
	idx.resize(size * 6)
	for q in range(size):
		var v := q * 4
		var i := q * 6
		idx[i] = v
		idx[i + 1] = v + 1
		idx[i + 2] = v + 2
		idx[i + 3] = v
		idx[i + 4] = v + 2
		idx[i + 5] = v + 3
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_counter_meshes[size] = mesh
	return mesh

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
