class_name ChunkData
extends RefCounted
# Contenu d'un chunk compressé en RLE (Run Length Encoding) : chaque colonne
# (marge de 1 bloc comprise, coordonnées locales -1..taille) est une suite de
# plages [id, longueur] démarrant à y = -1. Tout ce qui dépasse la dernière
# plage est de l'air : la colonne est « coupée » à son dernier bloc plein
# (extremity bound), donc un chunk de hauteur 256 ne stocke que ses ~20
# premiers mètres. Un chunk sans aucun bloc a des colonnes vides.

const W : int = WorldConfig.WIDTH
const H : int = WorldConfig.HEIGHT
const D : int = WorldConfig.DEPTH
const D2 : int = D + 2

var chunk_position : Vector3i
# Toutes les plages bout à bout ; run_start[ci] .. run_start[ci+1] délimite
# les paires [id, longueur] de la colonne ci.
var run_data : PackedInt32Array = PackedInt32Array()
var run_start : PackedInt32Array = PackedInt32Array()
var col_tops : PackedInt32Array = PackedInt32Array()  # sommet local du terrain par colonne, marge comprise
var tree_blocks : Dictionary = {}
var top_solid_y : int = -1  # plus haut y local occupé (terrain ou arbre), marge comprise

static func col_index(x : int, z : int) -> int:
	return (x + 1) * D2 + (z + 1)

func build(noise : FastNoiseLite, position : Vector3i, with_trees : bool) -> void:
	chunk_position = position
	col_tops.resize((W + 2) * D2)
	run_start.resize((W + 2) * D2 + 1)
	run_data.clear()
	top_solid_y = -1
	var base_y := position.y * H

	tree_blocks = TreeGen.compute_tree_blocks(noise, position) if with_trees else {}

	# blocs d'arbre regroupés par colonne : Vector2i(y local, id)
	var tree_cols := {}
	for pos in tree_blocks:
		var lx : int = pos.x - position.x * W
		var ly : int = pos.y - base_y
		var lz : int = pos.z - position.z * D
		if lx >= -1 and lx <= W and ly >= -1 and ly <= H and lz >= -1 and lz <= D:
			var ci := col_index(lx, lz)
			if not tree_cols.has(ci):
				tree_cols[ci] = []
			tree_cols[ci].append(Vector2i(ly, tree_blocks[pos]))

	var ci := 0
	for x in range(-1, W + 1):
		for z in range(-1, D + 1):
			run_start[ci] = run_data.size()
			var gx := position.x * W + x
			var gz := position.z * D + z
			var terrain_top := TerrainHeight.height_at(noise, gx, gz) - base_y
			col_tops[ci] = terrain_top
			var t := mini(terrain_top, H - 1)

			if not tree_cols.has(ci):
				# colonne pleine du pied (y = -1) au sommet du terrain
				if t >= -1:
					run_data.push_back(1)
					run_data.push_back(t + 2)
					if t > top_solid_y:
						top_solid_y = t
			else:
				var last_solid := _encode_column_with_trees(t, tree_cols[ci])
				if last_solid > top_solid_y:
					top_solid_y = last_solid
			ci += 1
	run_start[ci] = run_data.size()

	top_solid_y = mini(top_solid_y, H - 1)

# Colonne mixte terrain + arbre : reconstruite dans un petit tampon borné au
# plus haut bloc, puis encodée en plages. Renvoie le dernier y plein.
func _encode_column_with_trees(terrain_top : int, cells : Array) -> int:
	var span_top := terrain_top
	for c in cells:
		span_top = maxi(span_top, c.x)
	span_top = mini(span_top, H)

	var buf := PackedByteArray()
	buf.resize(span_top + 2)  # index i <-> y = i - 1
	for i in range(mini(terrain_top, span_top) + 2):
		buf[i] = 1
	for c in cells:
		if c.x <= span_top and buf[c.x + 1] == 0:
			buf[c.x + 1] = c.y

	var i := 0
	while i < buf.size():
		var id := buf[i]
		var j := i
		while j < buf.size() and buf[j] == id:
			j += 1
		run_data.push_back(id)
		run_data.push_back(j - i)
		i = j
	# coupe une éventuelle traîne d'air (extremity bound)
	var n := run_data.size()
	if n >= 2 and run_data[n - 2] == 0:
		var trimmed : int = run_data[n - 1]
		run_data.resize(n - 2)
		return span_top - trimmed
	return span_top

# Id du bloc en (x, y, z) locaux, marge -1..taille comprise ; 0 = air.
func block_at(x : int, y : int, z : int) -> int:
	var ci := col_index(x, z)
	var i := run_start[ci]
	var end := run_start[ci + 1]
	var yy := y + 1
	while i < end:
		var l := run_data[i + 1]
		if yy < l:
			return run_data[i]
		yy -= l
		i += 2
	return 0

# Sommet local du terrain (sans les arbres) pour une colonne, marge comprise.
func col_top(x : int, z : int) -> int:
	return col_tops[col_index(x, z)]
