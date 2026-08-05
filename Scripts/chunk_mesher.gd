class_name ChunkMesher
extends RefCounted
# Binary greedy mesher (d'après le « binary greedy mesher demo » de TanTanDev).
# Le contenu RLE du chunk (ChunkData) est converti en masques de bits par
# colonne : l'axe y tient dans des mots de 63 bits (le bit 63 reste libre car
# >> est arithmétique en GDScript), bornés au plus haut bloc du chunk. Le
# culling des faces se fait alors en quelques opérations binaires par colonne :
#   dessus  = col & ~(col décalée vers le bas)
#   dessous = col & ~(col décalée vers le haut)
#   flanc   = col & ~(colonne voisine)
# Les faces visibles sont ensuite regroupées en plans binaires 2D par
# (direction, id de bloc, niveau, octet d'AO) puis fusionnées en rectangles
# maximaux par manipulation de bits (trailing zeros / trailing ones). Chaque
# rectangle n'émet que 4 sommets et 6 indices : le maillage est indexé.
#
# Ambient occlusion par sommet (règle voxel classique, cf. 0fps) : chaque coin
# de face reçoit un niveau 0-3 d'après les 3 blocs voisins qui le touchent dans
# le plan devant la face (2 côtés + diagonale ; les 2 côtés pleins -> 3). Les
# 4 niveaux (2 bits chacun) forment un octet intégré à la clé des plans : la
# fusion ne réunit que des cellules au même motif d'occlusion, l'AO d'un bord
# ne s'étale donc jamais sur un grand rectangle. Le facteur de lumière du coin
# part au GPU dans UV.x (interpolé sur la face) ; le RGB reste l'albédo
# pré-ombré et l'alpha l'id du bloc.

const FACE_TOP := 0
const FACE_BOTTOM := 1
const FACE_SIDE := 2

const BLOCKS := {
	0: {"name" : "Air", "solid" : false},
	1: {"name" : "Grass", "solid" : true, "colors" : {FACE_TOP :Color(0.137, 0.902, 0.137, 1.0), FACE_BOTTOM : Color(0.137, 0.902, 0.137, 1.0), FACE_SIDE : Color(0.137, 0.902, 0.137, 1.0)}},
	2: {"name" : "Wood", "solid" : true, "colors" : {FACE_TOP :Color(0.42, 0.27, 0.11, 1.0), FACE_BOTTOM : Color(0.42, 0.27, 0.11, 1.0), FACE_SIDE : Color(0.48, 0.31, 0.14, 1.0)}},
	3: {"name" : "Leaves", "solid" : true, "colors" : {FACE_TOP :Color(0.10, 0.55, 0.12, 1.0), FACE_BOTTOM : Color(0.10, 0.55, 0.12, 1.0), FACE_SIDE : Color(0.10, 0.55, 0.12, 1.0)}},
}

# L'ordre indexe les plans : 0 UP, 1 DOWN, 2 LEFT, 3 RIGHT, 4 FORWARD, 5 BACK
const DIRECTIONS := [Vector3.UP, Vector3.DOWN, Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK]

const FACE_SHADE := {
	Vector3.UP: 1.0,
	Vector3.DOWN: 0.5,
	Vector3.LEFT: 0.6,
	Vector3.RIGHT: 0.6,
	Vector3.FORWARD: 0.8,
	Vector3.BACK: 0.8,
}

# Coins de chaque face, ordre = winding horaire vu de face ; -1 devient le
# bord min du rectangle sur cet axe, +1 le bord max.
const FACE_CORNERS := {
	Vector3.UP: [Vector3(-1, 1, -1), Vector3(1, 1, -1), Vector3(1, 1, 1), Vector3(-1, 1, 1)],
	Vector3.DOWN: [Vector3(-1, -1, 1), Vector3(1, -1, 1), Vector3(1, -1, -1), Vector3(-1, -1, -1)],
	Vector3.LEFT: [Vector3(-1, -1, -1), Vector3(-1, 1, -1), Vector3(-1, 1, 1), Vector3(-1, -1, 1)],
	Vector3.RIGHT: [Vector3(1, -1, 1), Vector3(1, 1, 1), Vector3(1, 1, -1), Vector3(1, -1, -1)],
	Vector3.FORWARD: [Vector3(-1, -1, -1), Vector3(1, -1, -1), Vector3(1, 1, -1), Vector3(-1, 1, -1)],
	Vector3.BACK: [Vector3(-1, 1, 1), Vector3(1, 1, 1), Vector3(1, -1, 1), Vector3(-1, -1, 1)],
}

const BITS := 63                       # bits utiles par mot de colonne
const MASK63 := 0x7FFFFFFFFFFFFFFF

# --- Ambient occlusion -------------------------------------------------------
# Facteur de lumière par niveau d'occlusion (0 = dégagé, 3 = coin enterré).
const AO_LIGHT := [1.0, 0.75, 0.55, 0.4]
# Les 8 voisins d'une face dans son plan, indexés par (a, b) où (a, b) sont les
# 2 axes tangents : 0:(-1,-1) 1:(0,-1) 2:(1,-1) 3:(-1,0) 4:(1,0) 5:(-1,1)
# 6:(0,1) 7:(1,1). Pour les faces y : a = x, b = z. Pour les faces latérales :
# a = axe horizontal du plan (z ou x), b = y.
const AO_RING_DCOL := [-1, 0, 1, -1, 1, -1, 0, 1]
const AO_RING_DBIT := [-1, -1, -1, 0, 0, 1, 1, 1]
# Pour chaque direction, les 4 coins de FACE_CORNERS (même ordre) -> indices
# [côté 1, côté 2, diagonale] dans l'anneau ci-dessus.
const AO_CORNERS := [
	[[3, 1, 0], [4, 1, 2], [4, 6, 7], [3, 6, 5]],  # UP
	[[3, 6, 5], [4, 6, 7], [4, 1, 2], [3, 1, 0]],  # DOWN
	[[1, 3, 0], [6, 3, 5], [6, 4, 7], [1, 4, 2]],  # LEFT
	[[1, 4, 2], [6, 4, 7], [6, 3, 5], [1, 3, 0]],  # RIGHT
	[[3, 1, 0], [4, 1, 2], [4, 6, 7], [3, 6, 5]],  # FORWARD
	[[3, 6, 5], [4, 6, 7], [4, 1, 2], [3, 1, 0]],  # BACK
]

var _verts := PackedVector3Array()
var _norms := PackedVector3Array()
var _cols := PackedColorArray()
var _uvs := PackedVector2Array()
var _idx := PackedInt32Array()
var _shaded := {}  # couleurs pré-ombrées : _shaded[direction][id de bloc]
var _ring := [0, 0, 0, 0, 0, 0, 0, 0]  # solidité des 8 voisins (réutilisé)
var _yoff : Array   # décalage (en mots) des 8 colonnes voisines, faces y
var _soff : Array   # par direction latérale : décalages des 3 colonnes du plan

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

@warning_ignore("integer_division")
func _build(data : ChunkData) -> ArrayMesh:
	# extremity bound : chunk sans aucun bloc -> pas de maillage du tout
	if data.top_solid_y < 0:
		return null

	# couleurs pré-ombrées ; l'alpha (inutilisé : matériau opaque) transporte
	# l'id du bloc vers le shader (id / 255), qui ne teinte que l'herbe
	for dir in DIRECTIONS:
		var shaded := [Color()]
		for id in range(1, 4):
			var c := block_color_for_face(id, dir)
			c.a = id / 255.0
			shaded.append(c)
		_shaded[dir] = shaded

	var W := WorldConfig.WIDTH
	var D := WorldConfig.DEPTH
	var D2 := D + 2
	var ncols := (W + 2) * D2
	# nombre de mots par colonne : le bit b correspond à y = b - 1 (marge du
	# dessous comprise), borné au plus haut bloc + 1 bit d'air au-dessus
	var nw := ceili(float(data.top_solid_y + 2) / BITS)
	var cap := nw * BITS
	var run_data := data.run_data
	var run_start := data.run_start

	# décalages des colonnes voisines pour l'AO (dépendent de nw)
	_yoff = [(-D2 - 1) * nw, -nw, (D2 - 1) * nw, -D2 * nw,
		D2 * nw, (-D2 + 1) * nw, nw, (D2 + 1) * nw]
	_soff = [null, null,
		[(-D2 - 1) * nw, -D2 * nw, (-D2 + 1) * nw],  # LEFT    : plan x-1, a = z
		[(D2 - 1) * nw, D2 * nw, (D2 + 1) * nw],     # RIGHT   : plan x+1, a = z
		[(-D2 - 1) * nw, -nw, (D2 - 1) * nw],        # FORWARD : plan z-1, a = x
		[(-D2 + 1) * nw, nw, (D2 + 1) * nw]]         # BACK    : plan z+1, a = x

	# --- 1. masques de solidité par colonne, directement depuis les plages RLE
	var cols := PackedInt64Array()
	cols.resize(ncols * nw)
	for ci in range(ncols):
		var i : int = run_start[ci]
		var end : int = run_start[ci + 1]
		var b := 0
		var base := ci * nw
		while i < end:
			var l : int = run_data[i + 1]
			if run_data[i] != 0:
				var hi := mini(b + l, cap)
				var s := b
				while s < hi:
					var w := s / BITS
					var lo := s - w * BITS
					var take := mini(BITS - lo, hi - s)
					cols[base + w] |= _range_mask(lo, lo + take)
					s += take
			b += l
			i += 2

	# --- 2. culling binaire + répartition des faces dans les plans 2D
	var planes := [{}, {}, {}, {}, {}, {}]
	var side_rows := data.top_solid_y + 1  # rangées y des plans latéraux

	for x in range(W):
		for z in range(D):
			var ci := ChunkData.col_index(x, z)
			var base := ci * nw

			# plages solides de la colonne : [id, bit début, bit fin)
			var runs := []
			var i : int = run_start[ci]
			var end : int = run_start[ci + 1]
			var b := 0
			while i < end:
				var l : int = run_data[i + 1]
				if run_data[i] != 0:
					runs.append([run_data[i], b, b + l])
				b += l
				i += 2

			var base_l := (ci - D2) * nw
			var base_r := (ci + D2) * nw
			var base_f := (ci - 1) * nw
			var base_b := (ci + 1) * nw
			var xbit := 1 << x
			var zbit := 1 << z

			for w in range(nw):
				var c : int = cols[base + w]
				if c == 0:
					continue
				# voisins verticaux de chaque bit, mot suivant / précédent inclus
				var above : int = c >> 1
				if w + 1 < nw:
					above |= (cols[base + w + 1] & 1) << 62
				var below : int = (c << 1) & MASK63
				if w > 0:
					below |= cols[base + w - 1] >> 62
				# le bit 0 du mot 0 (y = -1) est la marge, jamais une face du chunk
				var cut : int = ~1 if w == 0 else ~0
				_scatter_y(planes[0], c & ~above & cut, w, runs, z, xbit, true, base, cols, cap)
				_scatter_y(planes[1], c & ~below & cut, w, runs, z, xbit, false, base, cols, cap)
				_scatter_side(planes[2], c & ~cols[base_l + w] & cut, w, runs, x, zbit, side_rows, 2, base, cols, cap)
				_scatter_side(planes[3], c & ~cols[base_r + w] & cut, w, runs, x, zbit, side_rows, 3, base, cols, cap)
				_scatter_side(planes[4], c & ~cols[base_f + w] & cut, w, runs, z, xbit, side_rows, 4, base, cols, cap)
				_scatter_side(planes[5], c & ~cols[base_b + w] & cut, w, runs, z, xbit, side_rows, 5, base, cols, cap)

	# --- 3. greedy meshing binaire de chaque plan, émission des rectangles
	for d in range(6):
		var dict : Dictionary = planes[d]
		for key in dict:
			_greedy_plane(d, key >> 10, (key >> 2) & 0xFF, key & 3, dict[key])

	if _verts.is_empty():
		return null

	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _verts
	arrays[Mesh.ARRAY_NORMAL] = _norms
	arrays[Mesh.ARRAY_COLOR] = _cols
	arrays[Mesh.ARRAY_TEX_UV] = _uvs  # UV.x = facteur de lumière AO du coin
	arrays[Mesh.ARRAY_INDEX] = _idx

	# vertex packing natif : positions 16 bits normalisées sur l'AABB, normales
	# octaédriques, couleurs RGBA8 — moitié moins de mémoire GPU par sommet
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
		Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES)
	return mesh

# Masque des bits [lo, hi) d'un mot, hi <= 63.
static func _range_mask(lo : int, hi : int) -> int:
	var mhi : int = MASK63 if hi == BITS else (1 << hi) - 1
	return mhi & ~((1 << lo) - 1)

# Faces UP / DOWN : un plan par y, rangée = z, bit = x. Les 8 voisins d'AO
# sont tous au même niveau (le plan à y ± 1) : un seul mot/décalage pour les 8.
@warning_ignore("integer_division")
func _scatter_y(dict : Dictionary, m : int, w : int, runs : Array, z : int, xbit : int,
		up : bool, base : int, cols : PackedInt64Array, cap : int) -> void:
	while m != 0:
		var bit := w * BITS + _tz(m)
		m &= m - 1
		var ao := 0
		var t := bit + 1 if up else bit - 1
		if t < cap:
			var wt := t / BITS
			var lot := t - wt * BITS
			var any := 0
			for i in range(8):
				var s : int = (cols[base + _yoff[i] + wt] >> lot) & 1
				_ring[i] = s
				any |= s
			if any != 0:  # anneau vide (terrain plat) = cas majoritaire
				ao = _ao_byte(0 if up else 1)
		var key := ((bit - 1) << 10) | (ao << 2) | _id_at(runs, bit)
		var rows = dict.get(key)
		if rows == null:
			rows = []
			rows.resize(WorldConfig.DEPTH)
			rows.fill(0)
			dict[key] = rows
		rows[z] |= xbit

# Faces latérales : un plan par niveau (x ou z), rangée = y, bit = z ou x.
# Les voisins d'AO vivent dans les 3 colonnes du plan devant la face, aux
# bits y-1 / y / y+1.
@warning_ignore("integer_division")
func _scatter_side(dict : Dictionary, m : int, w : int, runs : Array, level : int,
		bitmask : int, nrows : int, d : int, base : int, cols : PackedInt64Array, cap : int) -> void:
	var coff : Array = _soff[d]
	while m != 0:
		var bit := w * BITS + _tz(m)
		m &= m - 1
		for i in range(8):
			var t : int = bit + AO_RING_DBIT[i]
			if t >= cap:
				_ring[i] = 0
			else:
				var wt := t / BITS
				_ring[i] = (cols[base + coff[AO_RING_DCOL[i] + 1] + wt] >> (t - wt * BITS)) & 1
		var key := (level << 10) | (_ao_byte(d) << 2) | _id_at(runs, bit)
		var rows = dict.get(key)
		if rows == null:
			rows = []
			rows.resize(nrows)
			rows.fill(0)
			dict[key] = rows
		rows[bit - 1] |= bitmask

# Assemble l'octet d'AO (4 coins x 2 bits, ordre de FACE_CORNERS) depuis la
# solidité des 8 voisins dans _ring. Règle : les 2 côtés pleins -> niveau 3
# (la diagonale est cachée de toute façon), sinon somme des 3 voisins.
func _ao_byte(d : int) -> int:
	var tbl : Array = AO_CORNERS[d]
	var ao := 0
	for k in range(4):
		var e : Array = tbl[k]
		var s1 : int = _ring[e[0]]
		var s2 : int = _ring[e[1]]
		var lvl : int = 3 if (s1 == 1 and s2 == 1) else s1 + s2 + _ring[e[2]]
		ao |= lvl << (k << 1)
	return ao

# Fusionne un plan binaire en rectangles maximaux : expansion en hauteur le
# long des bits (trailing ones), puis en largeur sur les rangées suivantes
# tant qu'elles contiennent le même motif (dont les bits sont alors éteints).
func _greedy_plane(d : int, level : int, ao : int, id : int, rows : Array) -> void:
	var n := rows.size()
	for r in range(n):
		var y := 0
		while true:
			var rest : int = rows[r] >> y
			if rest == 0:
				break
			y += _tz(rest)
			var h := _tz(~(rows[r] >> y))
			var h_mask : int = (1 << h) - 1
			var clear : int = ~(h_mask << y)
			var w := 1
			while r + w < n:
				if ((rows[r + w] >> y) & h_mask) != h_mask:
					break
				rows[r + w] &= clear
				w += 1
			_emit_quad(d, level, ao, id, y, r, h, w)
			y += h

# Émet le rectangle couvrant les bits [b0, b0+h) des rangées [r0, r0+w) du
# plan `level` de la direction d : 4 sommets + 6 indices.
func _emit_quad(d : int, level : int, ao : int, id : int, b0 : int, r0 : int, h : int, w : int) -> void:
	var fp := level + 0.5 if (d == 0 or d == 3 or d == 5) else level - 0.5
	var bmin := b0 - 0.5
	var bmax := b0 + h - 0.5
	var rmin := r0 - 0.5
	var rmax := r0 + w - 0.5
	var pmin : Vector3
	var pmax : Vector3
	match d:
		0, 1:  # bits = x, rangées = z
			pmin = Vector3(bmin, fp, rmin)
			pmax = Vector3(bmax, fp, rmax)
		2, 3:  # bits = z, rangées = y
			pmin = Vector3(fp, rmin, bmin)
			pmax = Vector3(fp, rmax, bmax)
		4, 5:  # bits = x, rangées = y
			pmin = Vector3(bmin, rmin, fp)
			pmax = Vector3(bmax, rmax, fp)

	var dir : Vector3 = DIRECTIONS[d]
	var s := WorldConfig.CUBE_SIZE
	var vbase := _verts.size()
	var color : Color = _shaded[dir][id]
	for corner in FACE_CORNERS[dir]:
		_verts.push_back(Vector3(
			(pmin.x if corner.x < 0 else pmax.x) * s,
			(pmin.y if corner.y < 0 else pmax.y) * s,
			(pmin.z if corner.z < 0 else pmax.z) * s))
		_norms.push_back(dir)
		_cols.push_back(color)
	var a0 := ao & 3
	var a1 := (ao >> 2) & 3
	var a2 := (ao >> 4) & 3
	var a3 := (ao >> 6) & 3
	_uvs.push_back(Vector2(AO_LIGHT[a0], 0.0))
	_uvs.push_back(Vector2(AO_LIGHT[a1], 0.0))
	_uvs.push_back(Vector2(AO_LIGHT[a2], 0.0))
	_uvs.push_back(Vector2(AO_LIGHT[a3], 0.0))
	# Anisotropie : l'interpolation se fait par triangle — couper le quad par
	# la diagonale reliant les coins les plus occlus, sinon le dégradé d'AO
	# dessine des artefacts en croix selon l'orientation. L'ordre de l'anneau
	# est préservé : le winding reste horaire.
	if a0 + a2 > a1 + a3:
		_idx.push_back(vbase + 1)
		_idx.push_back(vbase + 2)
		_idx.push_back(vbase + 3)
		_idx.push_back(vbase + 1)
		_idx.push_back(vbase + 3)
		_idx.push_back(vbase)
	else:
		_idx.push_back(vbase)
		_idx.push_back(vbase + 1)
		_idx.push_back(vbase + 2)
		_idx.push_back(vbase)
		_idx.push_back(vbase + 2)
		_idx.push_back(vbase + 3)

# Id du bloc au bit donné d'après les plages solides de la colonne.
static func _id_at(runs : Array, bit : int) -> int:
	for r in runs:
		if bit < r[2]:
			return r[0] if bit >= r[1] else 0
	return 0

# Nombre de zéros de poids faible (v != 0).
static func _tz(v : int) -> int:
	var n := 0
	if v & 0xFFFFFFFF == 0:
		n = 32
		v >>= 32
	if v & 0xFFFF == 0:
		n += 16
		v >>= 16
	if v & 0xFF == 0:
		n += 8
		v >>= 8
	if v & 0xF == 0:
		n += 4
		v >>= 4
	if v & 0x3 == 0:
		n += 2
		v >>= 2
	if v & 0x1 == 0:
		n += 1
	return n
