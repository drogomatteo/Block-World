class_name TreeGen
extends RefCounted

# Arbres 100 % procéduraux : plus aucune scène pré-voxelisée — chaque arbre est
# CONSTRUIT cube par cube à l'exécution. Tronc qui dévie, fût qui s'affine,
# branches, boules de feuillage grignotées sur les bords, teintes du bois et
# des feuilles : tout est tiré au sort PAR ARBRE, donc chaque arbre du monde
# est unique, comme dans la vraie vie.
# La graine de l'arbre dérive de (graine du monde, position) : c'est aléatoire
# mais DÉTERMINISTE — le même monde redonne exactement les mêmes arbres
# (objectif multijoueur : partager le seed suffit, comme pour le terrain).
#
# Structure du Node3D renvoyé (identique aux anciennes scènes d'arbre) :
#   Tree (meta "cube_count")
#   ├─ Blocks     : UN maillage de tous les cubes, faces internes supprimées,
#   │               couleurs par sommet — 1 draw call par arbre
#   ├─ BlocksLOD1 : palier de TRANSITION, cellules de 2³ cubes (mi-distance)
#   ├─ BlocksLOD2 : palier grossier, cellules de 4³ cubes (loin)
#   └─ Body (StaticBody3D) : colonnes de bois fusionnées en boîtes + une AABB
#                            par masse de feuillage
# Les cubes font Chunk.CUBE et tombent sur la grille du monde. AUCUN cube ne
# partage la case d'un cube de terrain (z-fight au pied des troncs) : le chunk
# fournit un callable `ground(dx, dz)` (hauteur relative du terrain autour du
# pied) et chaque colonne du pied descend jusqu'au sol réel de SA colonne
# (pentes comblées par les racines), côté amont les cubes enterrés sont retirés.

# LOD en DEUX paliers, bascule NETTE (pas de fondu : la transparence du fondu
# empêchait le maillage de projeter son ombre — la lumière traversait l'arbre
# pendant la transition). À la place : distances augmentées pour que le
# changement soit imperceptible, palier intermédiaire discret (cellules 2³)
# qui GARDE son ombre portée (la portée des ombres du soleil est de 180 m),
# et une hystérésis anti-scintillement à chaque frontière. Le palier lointain
# (cellules 4³) n'a pas d'ombre : il vit au-delà de la portée des ombres.
const LOD1_DIST := 120.0 # plein détail -> transition
const LOD2_DIST := 220.0 # transition -> grossier
const LOD_HYST := 4.0    # hystérésis (fade désactivé : sert d'anti-flottement)
const LOD1_FACTOR := 2
const LOD2_FACTOR := 4

const TRUNK_COLOR := Color(0.35, 0.23, 0.12)
const LEAF_COLOR := Color(0.24, 0.54, 0.20)
const SNOW_COLOR := Color(0.92, 0.94, 0.97)

var _rng := RandomNumberGenerator.new()
var _snowy := false
var _trunk_col := TRUNK_COLOR
var _leaf_col := LEAF_COLOR

# key Vector3i (indices de cube, y = 0 posé sur le sol) -> {"color", "leaf"}
var _voxels := {}
var _blob_min := {} # id de masse de feuillage -> AABB en indices de cube
var _blob_max := {}

# Le matériau est le même pour tous les arbres du monde : créé une seule fois.
static var _mat: StandardMaterial3D

static func build(world_seed: int, wx: int, wz: int, snowy := false,
		ground := Callable()) -> Node3D:
	var g := TreeGen.new()
	g._rng.seed = hash(Vector3i(world_seed, wx, wz)) # unique par arbre, déterministe
	g._snowy = snowy
	g._pick_palette()
	g._grow(ground)
	return g._assemble()

# ---------- Croissance ----------

# Chaque arbre décline les couleurs de base : bois plus ou moins sombre,
# vert qui dérive en teinte/saturation/valeur — jamais deux frondaisons égales.
func _pick_palette() -> void:
	_trunk_col.h = wrapf(_trunk_col.h + _rng.randf_range(-0.02, 0.02), 0.0, 1.0)
	_trunk_col.v = clampf(_trunk_col.v * _rng.randf_range(0.8, 1.2), 0.0, 1.0)
	_leaf_col.h = wrapf(_leaf_col.h + _rng.randf_range(-0.06, 0.06), 0.0, 1.0)
	_leaf_col.s = clampf(_leaf_col.s * _rng.randf_range(0.82, 1.15), 0.0, 1.0)
	_leaf_col.v = clampf(_leaf_col.v * _rng.randf_range(0.75, 1.12), 0.0, 1.0)

func _grow(ground: Callable) -> void:
	# Trois gabarits : il reste de petits arbres, mais la plupart sont massifs
	# et 1 sur 4 est un géant au fût épais.
	var kind := _rng.randf()
	var base_w: int      # largeur du fût à la base (cubes)
	var trunk_h: int
	var branch_n: int
	var branch_len: int
	var brx_max: float   # rayon max des boules de feuillage de branche
	var crx_min: float   # rayon de la couronne
	var crx_max: float
	if kind < 0.22: # petit arbre
		base_w = _rng.randi_range(1, 2)
		trunk_h = _rng.randi_range(8, 13)
		branch_n = _rng.randi_range(1, 2)
		branch_len = 4
		brx_max = 2.5
		crx_min = 3.0
		crx_max = 4.5
	elif kind < 0.75: # arbre moyen
		base_w = _rng.randi_range(2, 3)
		trunk_h = _rng.randi_range(13, 20)
		branch_n = _rng.randi_range(2, 4)
		branch_len = 6
		brx_max = 3.5
		crx_min = 4.5
		crx_max = 6.0
	else: # géant massif
		base_w = 4
		trunk_h = _rng.randi_range(17, 24)
		branch_n = _rng.randi_range(3, 6)
		branch_len = 7
		brx_max = 4.0
		crx_min = 6.0
		crx_max = 7.5
	# Le fût S'AFFINE en montant : pleine largeur à la racine, -1 cube passé
	# taper1, -2 passé taper2 (jamais moins de 1).
	var taper1 := int(float(trunk_h) * _rng.randf_range(0.25, 0.4))
	var taper2 := int(float(trunk_h) * _rng.randf_range(0.6, 0.75))

	# Tronc : monte du sol au sommet en déviant parfois d'un cube — aucun
	# tronc n'est parfaitement droit. On mémorise le centre à chaque hauteur
	# pour y accrocher les branches.
	var ix := 0
	var iz := 0
	var centers: Array[Vector2i] = [] # centre du tronc à la hauteur y
	var base_cols := {} # colonnes du pied (fût + racines) : Vector2i -> true
	for y in range(0, trunk_h + 1):
		if y > 2 and _rng.randf() < 0.18:
			ix = clampi(ix + _rng.randi_range(-1, 1), -3, 3)
		if y > 2 and _rng.randf() < 0.18:
			iz = clampi(iz + _rng.randi_range(-1, 1), -3, 3)
		centers.append(Vector2i(ix, iz))
		var w := base_w
		if y > taper2:
			w = maxi(1, base_w - 2)
		elif y > taper1:
			w = maxi(1, base_w - 1)
		var o := -(w >> 1)
		for dx in w:
			for dz in w:
				_wood(Vector3i(ix + o + dx, y, iz + o + dz))
				if y == 0:
					base_cols[Vector2i(ix + o + dx, iz + o + dz)] = true

	# Racines : le pied s'ÉVASE — un anneau grignoté de cubes autour de la
	# base, l'arbre semble agrippé au sol au lieu d'être posé dessus.
	var o0 := -(base_w >> 1)
	for dx in range(o0 - 1, o0 + base_w + 1):
		for dz in range(o0 - 1, o0 + base_w + 1):
			var c := Vector2i(dx, dz)
			if not base_cols.has(c) and _rng.randf() < 0.55:
				_wood(Vector3i(c.x, 0, c.y))
				base_cols[c] = true

	# Ancrage au TERRAIN, colonne par colonne (callable posé par le chunk,
	# hauteur relative de la colonne de terrain sous (dx, dz)) : en aval les
	# racines DESCENDENT jusqu'au sol réel (pentes comblées), en amont les
	# cubes qui seraient dans la butte sont RETIRÉS — jamais un cube d'arbre
	# et un cube de sol au même endroit (z-fight au pied des troncs).
	for c: Vector2i in base_cols:
		var g := 0
		if ground.is_valid():
			g = clampi(int(ground.call(c.x, c.y)), -6, 6)
		if g < 0:
			for y in range(g, 0):
				_wood(Vector3i(c.x, y, c.y))
		else:
			for y in range(0, g):
				_voxels.erase(Vector3i(c.x, y, c.y))

	# Branches : partent du tronc dans la moitié haute, filent en diagonale ou
	# tout droit en remontant, et portent chacune leur boule de feuillage.
	var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1),
		Vector2i(0, -1), Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]
	for i in branch_n:
		var by := _rng.randi_range(int(float(trunk_h) * 0.45), trunk_h - 2)
		var dir: Vector2i = dirs[_rng.randi_range(0, dirs.size() - 1)]
		var steps := _rng.randi_range(3, branch_len)
		var c0 := centers[by]
		var p := Vector3i(c0.x, by, c0.y)
		for s in steps:
			p += Vector3i(dir.x, 1 if _rng.randf() < 0.45 else 0, dir.y)
			_wood(p)
		var brx := _rng.randf_range(1.5, brx_max)
		_leaf_blob(p + Vector3i(0, 1, 0), brx, brx * 0.8)

	# Couronne au sommet du tronc.
	var crx := _rng.randf_range(crx_min, crx_max)
	var ctop := centers[trunk_h]
	_leaf_blob(Vector3i(ctop.x, trunk_h + 1, ctop.y), crx, crx * _rng.randf_range(0.65, 0.85))

	# Biome neige : les feuilles à ciel ouvert sont saupoudrées de blanc.
	if _snowy:
		for key: Vector3i in _voxels:
			if _voxels[key]["leaf"] and not _voxels.has(key + Vector3i(0, 1, 0)):
				_voxels[key]["color"] = (_voxels[key]["color"] as Color).lerp(SNOW_COLOR, 0.65)

func _wood(key: Vector3i) -> void:
	var f := 0.88 + 0.24 * _hash01(key) # veinage : nuance par cube (déterministe)
	_voxels[key] = {"color": Color(_trunk_col.r * f, _trunk_col.g * f, _trunk_col.b * f),
		"leaf": false}

# Ellipsoïde de feuilles au bord grignoté (des cubes de la surface sautent au
# hasard) : aucune boule n'est lisse ni pareille à une autre.
func _leaf_blob(center: Vector3i, rx: float, ry: float) -> void:
	var id := _blob_min.size()
	var col := _leaf_col
	col.v = clampf(col.v * _rng.randf_range(0.9, 1.1), 0.0, 1.0) # nuance par masse
	var nx := ceili(rx)
	var ny := ceili(ry)
	for dx in range(-nx, nx + 1):
		for dy in range(-ny, ny + 1):
			for dz in range(-nx, nx + 1):
				var key := center + Vector3i(dx, dy, dz)
				if key.y < 0:
					continue # le feuillage ne descend jamais sous le sol
				var d := Vector3(float(dx) / rx, float(dy) / ry, float(dz) / rx).length_squared()
				if d > 1.0 - 0.35 * _hash01(key):
					continue # bord grignoté
				_blob_min[id] = _blob_min[id].min(key) if _blob_min.has(id) else key
				_blob_max[id] = _blob_max[id].max(key) if _blob_max.has(id) else key
				if _voxels.has(key) and not _voxels[key]["leaf"]:
					continue # le bois garde la priorité
				var f := 0.86 + 0.28 * _hash01(key) # feuillage vivant : nuance par cube
				_voxels[key] = {"color": Color(col.r * f, col.g * f, col.b * f), "leaf": true}

func _hash01(v: Vector3i) -> float:
	return fposmod(sin(float(v.x) * 12.9898 + float(v.y) * 78.233 + float(v.z) * 37.719) * 43758.5453, 1.0)

# ---------- Construction du nœud ----------

func _assemble() -> Node3D:
	var tree := Node3D.new()
	tree.name = "Tree"
	tree.set_meta("cube_count", _voxels.size()) # lu par le smoke test
	var blocks := _build_blocks()
	blocks.visibility_range_end = LOD1_DIST
	blocks.visibility_range_end_margin = LOD_HYST
	tree.add_child(blocks)
	var lod1 := _build_blocks_lod(LOD1_FACTOR, "BlocksLOD1")
	lod1.visibility_range_begin = LOD1_DIST
	lod1.visibility_range_begin_margin = LOD_HYST
	lod1.visibility_range_end = LOD2_DIST
	lod1.visibility_range_end_margin = LOD_HYST
	# Le palier de transition PROJETTE son ombre (défaut) : sans elle, l'arbre
	# devenait « transparent » à la lumière dès 120 m alors que les ombres du
	# soleil portent à 180 m.
	tree.add_child(lod1)
	var lod2 := _build_blocks_lod(LOD2_FACTOR, "BlocksLOD2")
	lod2.visibility_range_begin = LOD2_DIST
	lod2.visibility_range_begin_margin = LOD_HYST
	lod2.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	tree.add_child(lod2)
	tree.add_child(_build_body())
	return tree

static func _material() -> StandardMaterial3D:
	if _mat == null:
		_mat = StandardMaterial3D.new()
		_mat.vertex_color_use_as_albedo = true # même rendu que les cubes du terrain
		_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _mat

func _voxel_center(key: Vector3i) -> Vector3:
	return Vector3(float(key.x), float(key.y) + 0.5, float(key.z)) * Chunk.CUBE

# Un seul ArrayMesh pour tout l'arbre : on n'émet que les faces dont le voxel
# voisin est vide (l'intérieur du tronc et des feuillages ne coûte rien).
func _build_blocks() -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_material())
	for key: Vector3i in _voxels:
		for d: Vector3i in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
				Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
			if not _voxels.has(key + d):
				_emit_face(st, key, d)
	var mi := MeshInstance3D.new()
	mi.name = "Blocks"
	mi.mesh = st.commit()
	return mi

func _emit_face(st: SurfaceTool, key: Vector3i, d: Vector3i) -> void:
	var half := Chunk.CUBE * 0.5
	var n := Vector3(d)
	var u := Vector3(0, 1, 0) if d.x != 0 else Vector3(1, 0, 0)
	var v := Vector3(0, 0, 1) if d.z == 0 else Vector3(0, 1, 0)
	var fc := _voxel_center(key) + n * half
	st.set_color(_voxels[key]["color"])
	st.set_normal(n)
	var quad: Array[Vector3] = [fc - u * half - v * half, fc + u * half - v * half,
		fc + u * half + v * half, fc - u * half + v * half]
	for t: int in [0, 1, 2, 0, 2, 3]:
		st.add_vertex(quad[t])

# Maillage LOD : les voxels regroupés en cellules de factor³ (couleur
# moyenne), faces exposées seulement — silhouette intacte, coût divisé.
func _build_blocks_lod(factor: int, node_name: String) -> MeshInstance3D:
	var cells := {}
	for key: Vector3i in _voxels:
		var ck := Vector3i(floori(float(key.x) / factor),
			floori(float(key.y) / factor), floori(float(key.z) / factor))
		if not cells.has(ck):
			cells[ck] = []
		cells[ck].append(_voxels[key]["color"])
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_material())
	for ck: Vector3i in cells:
		var avg := Color(0, 0, 0)
		for c: Color in cells[ck]:
			avg += c
		avg /= float((cells[ck] as Array).size())
		for d: Vector3i in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
				Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
			if not cells.has(ck + d):
				_emit_lod_face(st, ck, d, avg, factor)
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = st.commit()
	return mi

# Centre monde d'une cellule LOD : la cellule couvre les voxels
# [ck*F .. ck*F+F-1] sur chaque axe (mêmes conventions que _voxel_center).
func _lod_center(ck: Vector3i, factor: int) -> Vector3:
	var f := float(factor)
	return Vector3(float(ck.x) * f + (f - 1.0) * 0.5,
		float(ck.y) * f + f * 0.5,
		float(ck.z) * f + (f - 1.0) * 0.5) * Chunk.CUBE

func _emit_lod_face(st: SurfaceTool, ck: Vector3i, d: Vector3i, col: Color, factor: int) -> void:
	var half := Chunk.CUBE * float(factor) * 0.5
	var n := Vector3(d)
	var u := Vector3(0, 1, 0) if d.x != 0 else Vector3(1, 0, 0)
	var v := Vector3(0, 0, 1) if d.z == 0 else Vector3(0, 1, 0)
	var fc := _lod_center(ck, factor) + n * half
	st.set_color(col)
	st.set_normal(n)
	var quad: Array[Vector3] = [fc - u * half - v * half, fc + u * half - v * half,
		fc + u * half + v * half, fc - u * half + v * half]
	for t: int in [0, 1, 2, 0, 2, 3]:
		st.add_vertex(quad[t])

func _build_body() -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "Body"
	# Bois : les cubes d'une même colonne (i, j) sont fusionnés en boîtes
	# verticales — la collision épouse le tronc et ses branches au cube près.
	var columns := {}
	for key: Vector3i in _voxels:
		if not _voxels[key]["leaf"]:
			var cx := Vector2i(key.x, key.z)
			if not columns.has(cx):
				columns[cx] = []
			columns[cx].append(key.y)
	var ti := 0
	for cx: Vector2i in columns:
		var ks: Array = columns[cx]
		ks.sort()
		var start: int = ks[0]
		var prev: int = ks[0]
		for m in range(1, ks.size() + 1):
			if m < ks.size() and ks[m] == prev + 1:
				prev = ks[m]
				continue
			body.add_child(_box_shape("Trunk%d" % ti,
				Vector3i(cx.x, start, cx.y), Vector3i(cx.x, prev, cx.y)))
			ti += 1
			if m < ks.size():
				start = ks[m]
				prev = ks[m]
	# Feuillage : une boîte englobante par masse (assez fin pour s'y poser,
	# assez grossier pour rester léger — une forêt entière reste bon marché).
	for blob_id: int in _blob_min:
		body.add_child(_box_shape("Leaves%d" % blob_id, _blob_min[blob_id], _blob_max[blob_id]))
	return body

func _box_shape(shape_name: String, lo: Vector3i, hi: Vector3i) -> CollisionShape3D:
	var shape := BoxShape3D.new()
	shape.size = Vector3(hi - lo + Vector3i.ONE) * Chunk.CUBE
	var cs := CollisionShape3D.new()
	cs.name = shape_name
	cs.shape = shape
	cs.position = (_voxel_center(lo) + _voxel_center(hi)) * 0.5
	return cs
