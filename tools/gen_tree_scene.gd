extends SceneTree

# Générateur des arbres voxel : godot --headless -s res://tools/gen_tree_scene.gd
#
# L'arbre du jeu n'est plus le GLB affiché tel quel : ce script VOXELISE le
# modèle Blender de l'utilisateur (Assets/Tree1.glb — la source artistique de
# la forme reste son objet 3D) en cubes de la taille EXACTE des blocs du
# terrain (Chunk.CUBE), alignés sur la grille du monde, et produit CINQ
# VARIANTES (Scènes/Monde/tree.tscn + tree2..5.tscn) à partir de la même
# forme : silhouette étirée/trapue (échelle hauteur/largeur), boules de
# feuillage légèrement regonflées/dégonflées (aléa déterministe par variante)
# et verts déclinés en teinte/saturation/valeur — AUCUNE couleur nouvelle, le
# tronc garde sa couleur d'origine. Structure de chaque scène :
#   Tree (Node3D, meta "cube_count")
#   ├─ Blocks (MeshInstance3D : UN maillage de tous les cubes, faces internes
#   │          supprimées, couleurs par sommet — 1 draw call par arbre)
#   └─ Body (StaticBody3D)
#      ├─ Trunk* : colonnes de cubes du tronc fusionnées en boîtes (au cube près)
#      └─ Leaves* : une boîte englobante par masse de feuillage
#
# ⚠ Relancer ce script ÉCRASE les 5 scènes (y compris des retouches éditeur).
# Le GLB n'est plus référencé par les scènes : il ne sert qu'ici.

# Mise à l'échelle du GLB (décalage -0.6 : le pied du tronc s'ancre sous la
# surface pour les pentes). 2.3 depuis l'agrandissement du monde du 2026-07-24
# (arbres ~28 % plus grands, à l'échelle des nouveaux reliefs).
const SCALE := 2.3
const OFFSET := Vector3(0.0, -0.6, 0.0)
const OUT_DIR := "res://Scènes/Monde/"

# LOD : au-delà de LOD_DIST mètres de la CAMÉRA (distance fixe, indépendante
# de la distance d'affichage), l'arbre bascule sur un maillage regroupé en
# cellules de LOD_FACTOR³ cubes (~9× moins de faces, silhouette intacte).
# Godot gère la bascule tout seul via visibility_range_begin/end ; le FONDU
# (marge + fade SELF) évite le pop sec — à 80 m la différence reste discrète.
const LOD_DIST := 80.0
const LOD_MARGIN := 8.0
const LOD_FACTOR := 3

# chunk.tscn référence les arbres par ces uid : ils doivent survivre à la
# régénération (ResourceSaver n'écrit pas d'uid en headless, on les réinjecte).
# y/xz = échelle hauteur/largeur ; hue/sat/val = déclinaison du vert du feuillage.
const VARIANTS := [
	{"file": "tree.tscn", "uid": "uid://7khjbuhpus3q",
		"y": 1.0, "xz": 1.0, "hue": 0.0, "sat": 1.0, "val": 1.0},   # l'original
	{"file": "tree2.tscn", "uid": "uid://btree2voxel2",
		"y": 0.78, "xz": 1.06, "hue": 0.015, "sat": 1.08, "val": 0.94}, # trapu, vert chaud
	{"file": "tree3.tscn", "uid": "uid://btree3voxel3",
		"y": 1.22, "xz": 0.88, "hue": -0.02, "sat": 0.90, "val": 1.08}, # élancé, vert tendre
	{"file": "tree4.tscn", "uid": "uid://btree4voxel4",
		"y": 0.92, "xz": 0.97, "hue": 0.05, "sat": 1.05, "val": 0.88},  # vert olive
	{"file": "tree5.tscn", "uid": "uid://btree5voxel5",
		"y": 1.10, "xz": 1.0, "hue": -0.045, "sat": 1.0, "val": 0.80},  # vert profond
]

# Paramètres de la variante en cours de voxelisation.
var _vy := 1.0
var _vxz := 1.0
var _hue := 0.0
var _sat := 1.0
var _val := 1.0
var _blob_rng := RandomNumberGenerator.new()

# key Vector3i(i, k, j) -> {"color": Color, "leaf": bool}
# Centre monde du voxel : (i*CUBE, (k+0.5)*CUBE, j*CUBE) — la colonne x/z tombe
# sur les centres de colonnes du terrain, la couche k=0 est posée sur le sol.
var _voxels := {}
var _blob_min := {} # id de masse de feuillage -> Vector3i
var _blob_max := {}

func _initialize() -> void:
	var glb := load("res://Assets/Tree1.glb") as PackedScene
	if glb == null:
		printerr("FAIL : Assets/Tree1.glb introuvable (lancer --import ?)")
		quit(1)
		return
	var src := glb.instantiate()
	for vi in VARIANTS.size():
		var v: Dictionary = VARIANTS[vi]
		_vy = v["y"]
		_vxz = v["xz"]
		_hue = v["hue"]
		_sat = v["sat"]
		_val = v["val"]
		_blob_rng.seed = 7000 + vi # jitter des feuillages propre à la variante
		_voxels = {}
		_blob_min = {}
		_blob_max = {}
		_collect(src, Transform3D.IDENTITY)
		if not _save_variant(String(v["file"]), String(v["uid"])):
			quit(1)
			return
	src.free()
	quit(0)

func _save_variant(file: String, uid: String) -> bool:
	var tree := Node3D.new()
	tree.name = "Tree"
	tree.set_meta("cube_count", _voxels.size()) # lu par le smoke test
	var blocks := _build_blocks()
	blocks.visibility_range_end = LOD_DIST
	blocks.visibility_range_end_margin = LOD_MARGIN
	blocks.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	tree.add_child(blocks)
	var lod := _build_blocks_lod()
	lod.visibility_range_begin = LOD_DIST
	lod.visibility_range_begin_margin = LOD_MARGIN
	lod.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	tree.add_child(lod)
	tree.add_child(_build_body())
	_set_owner_rec(tree, tree)
	var path := OUT_DIR + file
	var ps := PackedScene.new()
	if ps.pack(tree) != OK or ResourceSaver.save(ps, path) != OK:
		printerr("FAIL pack/save ", path)
		return false
	var txt := FileAccess.get_file_as_string(path)
	txt = txt.replace("[gd_scene format=3]", "[gd_scene format=3 uid=\"%s\"]" % uid)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(txt)
	f.close()
	print("OK   %s : %d cubes, %d feuillages" % [path, _voxels.size(), _blob_min.size()])
	tree.free()
	return true

# ---------- Voxelisation ----------

func _collect(n: Node, xf: Transform3D) -> void:
	if n is Node3D:
		xf = xf * (n as Node3D).transform
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		# Le GLB de l'utilisateur : tronc = "Cube", feuillages = "Icosphere*".
		var leaf := String(mi.name).begins_with("Icosphere")
		var blob_id := _blob_min.size() if leaf else -1
		var mxf := xf
		if leaf:
			# Chaque boule de feuillage se regonfle/dégonfle un peu autour de
			# son centre : silhouette propre à la variante (aléa déterministe).
			mxf.basis = mxf.basis * Basis.from_scale(Vector3.ONE * _blob_rng.randf_range(0.82, 1.15))
		for s in mi.mesh.get_surface_count():
			var col := Color(0.35, 0.23, 0.12)
			var mat := mi.get_active_material(s)
			if mat is BaseMaterial3D:
				col = (mat as BaseMaterial3D).albedo_color
			if leaf:
				col = _tint(col) # déclinaison du vert — le tronc reste intact
			_sample_surface(mi.mesh, s, mxf, col, leaf, blob_id)
	for ch in n.get_children():
		_collect(ch, xf)

# Décline le vert d'origine en teinte/saturation/valeur (pas de couleur neuve).
func _tint(c: Color) -> Color:
	return Color.from_hsv(fposmod(c.h + _hue, 1.0),
		clampf(c.s * _sat, 0.0, 1.0), clampf(c.v * _val, 0.0, 1.0), 1.0)

# Échantillonne les triangles d'une surface (pas ~1/3 de cube : aucun trou) et
# marque le voxel contenant chaque point. Le tronc a priorité sur le feuillage.
func _sample_surface(mesh: Mesh, s: int, xf: Transform3D, col: Color, leaf: bool, blob_id: int) -> void:
	var arrays := mesh.surface_get_arrays(s)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if idx.is_empty(): # surface non indexée : les sommets se suivent par 3
		idx = PackedInt32Array(range(verts.size()))
	# Pas d'échantillonnage en unités GLB : ~1/3 de cube APRÈS toutes les mises
	# à l'échelle (variante + regonflage des boules), pour ne laisser aucun trou.
	var step := Chunk.CUBE / (SCALE * maxf(_vy, _vxz) * 1.15) / 3.0
	for t in range(0, idx.size(), 3):
		var a := verts[idx[t]]
		var ab := verts[idx[t + 1]] - a
		var ac := verts[idx[t + 2]] - a
		var n := ceili(maxf(ab.length(), ac.length()) / step) + 1
		for u in n + 1:
			for v in n + 1 - u:
				_mark(xf * (a + ab * (float(u) / n) + ac * (float(v) / n)), col, leaf, blob_id)

# p est en unités GLB : conversion monde = échelle globale × échelle de la
# variante (largeur/hauteur), puis ancrage OFFSET.
func _mark(p: Vector3, col: Color, leaf: bool, blob_id: int) -> void:
	var world := Vector3(p.x * SCALE * _vxz, p.y * SCALE * _vy, p.z * SCALE * _vxz) + OFFSET
	var key := Vector3i(roundi(world.x / Chunk.CUBE), floori(world.y / Chunk.CUBE),
		roundi(world.z / Chunk.CUBE))
	if key.y < -1:
		return # au plus une couche enterrée sous le point de plantation
	if leaf:
		_blob_min[blob_id] = _blob_min[blob_id].min(key) if _blob_min.has(blob_id) else key
		_blob_max[blob_id] = _blob_max[blob_id].max(key) if _blob_max.has(blob_id) else key
		if _voxels.has(key) and not _voxels[key]["leaf"]:
			return # le tronc garde la priorité là où les deux se chevauchent
		# Légère variation de teinte par cube (déterministe) : feuillage vivant.
		var f := 0.86 + 0.28 * _hash01(key)
		_voxels[key] = {"color": Color(col.r * f, col.g * f, col.b * f), "leaf": true}
	else:
		_voxels[key] = {"color": col, "leaf": false}

func _hash01(v: Vector3i) -> float:
	return fposmod(sin(float(v.x) * 12.9898 + float(v.y) * 78.233 + float(v.z) * 37.719) * 43758.5453, 1.0)

# ---------- Construction de la scène ----------

func _voxel_center(key: Vector3i) -> Vector3:
	return Vector3(float(key.x), float(key.y) + 0.5, float(key.z)) * Chunk.CUBE

# Un seul ArrayMesh pour tout l'arbre : on n'émet que les faces dont le voxel
# voisin est vide (l'intérieur du tronc et des feuillages ne coûte rien).
# NB : pas de MultiMesh ici — son buffer d'instances vit dans le RenderingServer
# et ne se sérialise pas depuis un script --headless (renderer dummy).
func _build_blocks() -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true # même rendu que les cubes du terrain
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	st.set_material(mat)
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

# Maillage LOD : les voxels regroupés en cellules de LOD_FACTOR³ (couleur
# moyenne), faces exposées seulement. Pas d'ombre portée (trop loin pour
# qu'elle se voie, et c'est autant de rendu économisé).
func _build_blocks_lod() -> MeshInstance3D:
	var cells := {}
	for key: Vector3i in _voxels:
		var ck := Vector3i(floori(float(key.x) / LOD_FACTOR),
			floori(float(key.y) / LOD_FACTOR), floori(float(key.z) / LOD_FACTOR))
		if not cells.has(ck):
			cells[ck] = []
		cells[ck].append(_voxels[key]["color"])
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	st.set_material(mat)
	for ck: Vector3i in cells:
		var avg := Color(0, 0, 0)
		for c: Color in cells[ck]:
			avg += c
		avg /= float((cells[ck] as Array).size())
		for d: Vector3i in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
				Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
			if not cells.has(ck + d):
				_emit_lod_face(st, ck, d, avg)
	var mi := MeshInstance3D.new()
	mi.name = "BlocksLOD"
	mi.mesh = st.commit()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

# Centre monde d'une cellule LOD : la cellule couvre les voxels
# [ck*F .. ck*F+F-1] sur chaque axe (mêmes conventions que _voxel_center).
func _lod_center(ck: Vector3i) -> Vector3:
	var f := float(LOD_FACTOR)
	return Vector3(float(ck.x) * f + (f - 1.0) * 0.5,
		float(ck.y) * f + f * 0.5,
		float(ck.z) * f + (f - 1.0) * 0.5) * Chunk.CUBE

func _emit_lod_face(st: SurfaceTool, ck: Vector3i, d: Vector3i, col: Color) -> void:
	var half := Chunk.CUBE * float(LOD_FACTOR) * 0.5
	var n := Vector3(d)
	var u := Vector3(0, 1, 0) if d.x != 0 else Vector3(1, 0, 0)
	var v := Vector3(0, 0, 1) if d.z == 0 else Vector3(0, 1, 0)
	var fc := _lod_center(ck) + n * half
	st.set_color(col)
	st.set_normal(n)
	var quad: Array[Vector3] = [fc - u * half - v * half, fc + u * half - v * half,
		fc + u * half + v * half, fc - u * half + v * half]
	for t: int in [0, 1, 2, 0, 2, 3]:
		st.add_vertex(quad[t])

func _build_body() -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "Body"
	# Tronc : les cubes d'une même colonne (i, j) sont fusionnés en boîtes
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

func _set_owner_rec(n: Node, root: Node) -> void:
	for ch in n.get_children():
		ch.owner = root
		_set_owner_rec(ch, root)
