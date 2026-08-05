class_name ChunkData
extends RefCounted
# Contenu d'un chunk compressé en RLE (Run Length Encoding) : chaque colonne
# (marge de 1 bloc comprise, coordonnées locales -1..taille) est une suite de
# plages [id, longueur] démarrant à y = -1. Tout ce qui dépasse la dernière
# plage est de l'air : la colonne est « coupée » à son dernier bloc plein
# (extremity bound), donc un chunk de hauteur 256 ne stocke que ses ~20
# premiers mètres. Un chunk sans aucun bloc a des colonnes vides.
#
# LOD : au pas `step` (1, 2, 4…), la grille est en CELLULES de step³ blocs
# (toutes les coordonnées locales de cette classe sont alors en cellules).
# Une cellule prend le MAX des 4 coins de hauteur : le terrain grossier
# enveloppe le fin, les raccords entre niveaux se recouvrent au lieu de se
# fissurer. Les colonnes de marge restent VIDES quand step > 1 : le mesher
# émet alors tous les murs de bordure, ce qui bouche les fissures restantes
# (surcoût invisible, les murs sont enfouis chez le voisin). Pas d'arbres
# au-delà du pas 1.

const W : int = WorldConfig.WIDTH
const H : int = WorldConfig.HEIGHT
const D : int = WorldConfig.DEPTH

var chunk_position : Vector3i
var step : int = 1          # taille d'une cellule en blocs (LOD)
var w_cells : int = W       # dimensions de la grille en cellules
var h_cells : int = H
var d_cells : int = D
var d2 : int = D + 2
# Toutes les plages bout à bout ; run_start[ci] .. run_start[ci+1] délimite
# les paires [id, longueur] de la colonne ci.
var run_data : PackedInt32Array = PackedInt32Array()
var run_start : PackedInt32Array = PackedInt32Array()
var col_tops : PackedInt32Array = PackedInt32Array()  # sommet local du terrain par colonne, marge comprise
var tree_blocks : Dictionary = {}
var top_solid_y : int = -1  # plus haute cellule locale occupée (terrain ou arbre), marge comprise

func col_index(x : int, z : int) -> int:
	return (x + 1) * d2 + (z + 1)

@warning_ignore("integer_division")
func build(noise : FastNoiseLite, position : Vector3i, with_trees : bool, lod_step : int = 1) -> void:
	chunk_position = position
	step = lod_step
	w_cells = W / step
	h_cells = H / step
	d_cells = D / step
	d2 = d_cells + 2
	col_tops.resize((w_cells + 2) * d2)
	run_start.resize((w_cells + 2) * d2 + 1)
	run_data.clear()
	top_solid_y = -1
	var base_y := position.y * H

	tree_blocks = TreeGen.compute_tree_blocks(noise, position) if (with_trees and step == 1) else {}

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
	for x in range(-1, w_cells + 1):
		for z in range(-1, d_cells + 1):
			run_start[ci] = run_data.size()
			# LOD : marges vides -> le mesher émet tous les murs de bordure
			if step > 1 and (x < 0 or x >= w_cells or z < 0 or z >= d_cells):
				col_tops[ci] = -2
				ci += 1
				continue
			var gx := position.x * W + x * step
			var gz := position.z * D + z * step
			var terrain_top : int
			if step == 1:
				terrain_top = TerrainHeight.height_at(noise, gx, gz) - base_y
			else:
				# max des 4 coins de la cellule, arrondi au nombre de cellules
				var h := maxi(
					maxi(TerrainHeight.height_at(noise, gx, gz),
						TerrainHeight.height_at(noise, gx + step, gz)),
					maxi(TerrainHeight.height_at(noise, gx, gz + step),
						TerrainHeight.height_at(noise, gx + step, gz + step)))
				terrain_top = roundi(float(h - base_y + 1) / step) - 1
			col_tops[ci] = terrain_top
			var t := mini(terrain_top, h_cells - 1)

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

	top_solid_y = mini(top_solid_y, h_cells - 1)

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

# Id du bloc en (x, y, z) locaux (en CELLULES au pas du LOD), marge -1..taille
# comprise ; 0 = air.
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
