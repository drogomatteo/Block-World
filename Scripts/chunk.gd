class_name Chunk
extends Node3D

# Un chunk = une portion carrée SIZE x SIZE colonnes du monde.
# Rendu   : UN SEUL MultiMeshInstance3D (donc 1 draw call pour tous les cubes).
# Collision: UN SEUL collider trimesh (dessus + faces de falaise exposées),
# construit UNIQUEMENT près du joueur (collision_on, piloté par world.gd) : la
# physique ne sert à rien à 200 m et le trimesh cuit par Jolt coûte cher en RAM.
# Même logique pour les arbres (tree_detail) : loin, seuls les maillages
# grossiers existent — la génération étant déterministe, se rapprocher
# reconstruit exactement le même arbre en plein détail.
# Les instances/faces sont en coordonnées LOCALES ; le nœud Chunk est placé
# à la position monde (cx*SIZE*CUBE, 0, cz*SIZE*CUBE) par world.gd.

# 32 (doublé le 2026-07-25) : à couverture égale en mètres, 4× moins de chunks
# donc 4× moins de nœuds/objets dessinés (chaque chunk porte ~5-7 nœuds fixes :
# MultiMesh terrain, eau, herbe, ombres d'arbres...). La distance de rendu par
# défaut a été divisée par 2 en face (même vue monde qu'avant).
const SIZE := 32
# Taille MONDE d'un cube : le TIERS de la taille du joueur (capsule 1.8 m).
# TerrainGen travaille en indices de cube ; tout ce qui parle en mètres passe par CUBE.
const CUBE := 0.6

# L'herbe de l'utilisateur (Assets/Grass.tscn) fusionnée en UN maillage par
# tools/gen_grass_mesh.gd : chaque chunk l'instancie via son propre MultiMesh
# (1 draw call pour toute l'herbe du chunk).
const GRASS_MESH := preload("res://Assets/grass_mesh.res")

# Vent sur l'herbe : errance pseudo-brownienne (somme de sinus à fréquences
# incommensurables = balancement doux jamais périodique à l'œil), NULLE au pied
# du brin et maximale à la pointe (poids quadratique sur la hauteur mesh 0..0.6).
# La phase dérive de la position du brin dans la touffe ET de la touffe dans le
# monde : chaque brin erre pour son compte. L'amplitude suit l'échelle Y de
# l'instance (l'herbe rase des lisières bouge moins que l'herbe haute).
# fragment() reproduit vertex_color_use_as_albedo (COLOR = nuance par brin
# cuite dans le maillage × couleur d'instance accordée au sol).
const GRASS_SHADER := """
shader_type spatial;

uniform float sway_amp = 0.03; // demi-amplitude à la pointe, en mètres

void vertex() {
	float w = clamp(VERTEX.y / 0.6, 0.0, 1.0);
	w *= w * length(MODEL_MATRIX[1].xyz);
	float ph = VERTEX.x * 17.0 + VERTEX.z * 23.0
		+ MODEL_MATRIX[3].x * 3.1 + MODEL_MATRIX[3].z * 4.7;
	vec2 sway = vec2(
		sin(TIME * 1.9 + ph) + 0.6 * sin(TIME * 3.7 + ph * 1.7),
		sin(TIME * 1.4 + ph * 1.3) + 0.6 * sin(TIME * 2.9 + ph * 0.8));
	VERTEX.xz += sway * sway_amp * w;
}

void fragment() {
	ALBEDO = COLOR.rgb;
}
"""

# Matériau de vent PARTAGÉ par tous les chunks (posé en material_override sur
# leur MultiMesh d'herbe) : un seul Shader compilé pour tout le monde.
static var _grass_material: ShaderMaterial

var gen: TerrainGen
var cx: int
var cz: int
var water_material: Material # partagé, créé une seule fois par world.gd
var grass_view_dist := 0.0   # distance d'affichage de l'herbe (0 = illimitée)
var grass_visible := true    # option « herbe au sol »
var grass_mmi: MultiMeshInstance3D       # relu par world.gd (toggles à chaud)
var tree_shadow_mmi: MultiMeshInstance3D
var tree_detail := 0        # 0 = plein détail, 1 = LOD1+LOD2, 2 = LOD2 seul
var collision_on := true    # collider terrain + corps des arbres (près du joueur)
var _terrain_body: StaticBody3D
var _tree_sites: Array[Vector3i] = []    # (lx, hauteur, lz) des arbres du chunk
var _tree_nodes: Array[Node3D] = []

func build() -> void:
	_build_visual()
	_scan_tree_sites()
	_build_trees()
	_build_tree_shadows()
	_build_grass()
	_build_water()
	if collision_on:
		_build_collision()

# Adapte le chunk à sa distance au joueur (appelé par world.gd via sa file de
# détail) : la collision apparaît/disparaît, les arbres sont reconstruits au
# niveau de détail voulu (déterministe : mêmes arbres, maillages en moins).
func set_lod(detail: int, coll: bool) -> void:
	var trees_dirty := detail != tree_detail or coll != collision_on
	if coll != collision_on:
		collision_on = coll
		if coll:
			_build_collision()
		elif _terrain_body != null:
			_terrain_body.queue_free()
			_terrain_body = null
	tree_detail = detail
	if trees_dirty:
		_build_trees()

func _build_visual() -> void:
	var box := BoxMesh.new()
	box.size = Vector3.ONE * CUBE
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true # la couleur par instance devient l'albédo
	box.material = mat

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = box

	var transforms: Array[Transform3D] = []
	var colors: Array[Color] = []
	for lx in SIZE:
		for lz in SIZE:
			var wx := cx * SIZE + lx
			var wz := cz * SIZE + lz
			var h := gen.get_height(wx, wz)
			# On ne remplit la colonne que jusqu'au plus bas voisin : inutile de
			# dessiner des cubes totalement enterrés qu'on ne verra jamais.
			var bottom := _column_bottom(wx, wz, h)
			for y in range(bottom, h + 1):
				transforms.append(Transform3D(Basis(), Vector3(lx, y, lz) * CUBE))
				colors.append(gen.get_color(wx, wz, y, h))

	mm.instance_count = transforms.size()
	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])
		mm.set_instance_color(i, colors[i])

	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	add_child(mmi)

func _build_collision() -> void:
	var faces := PackedVector3Array()
	for lx in SIZE:
		for lz in SIZE:
			var wx := cx * SIZE + lx
			var wz := cz * SIZE + lz
			var h := gen.get_height(wx, wz)
			var top := (float(h) + 0.5) * CUBE
			var x0 := (lx - 0.5) * CUBE
			var x1 := (lx + 0.5) * CUBE
			var z0 := (lz - 0.5) * CUBE
			var z1 := (lz + 0.5) * CUBE
			# Dessus (marchable). Ordre choisi pour que la normale pointe vers le HAUT
			# (au cas où Jolt ignorerait backface_collision, le sol reste solide par-dessus).
			# Les quads voisins se touchent à ±0.5 : aucun trou entre colonnes/chunks.
			_quad(faces,
				Vector3(x0, top, z0), Vector3(x0, top, z1),
				Vector3(x1, top, z1), Vector3(x1, top, z0))
			# Faces de falaise, uniquement vers un voisin plus bas (= vrai mur).
			_side(faces, wx + 1, wz, h, x1, z0, x1, z1)
			_side(faces, wx - 1, wz, h, x0, z1, x0, z0)
			_side(faces, wx, wz + 1, h, x1, z1, x0, z1)
			_side(faces, wx, wz - 1, h, x0, z0, x1, z0)

	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	# backface_collision = true => l'orientation des triangles n'a pas d'importance,
	# on entre en collision des deux côtés. Robuste et suffisant pour une base.
	shape.backface_collision = true

	var cs := CollisionShape3D.new()
	cs.shape = shape
	_terrain_body = StaticBody3D.new()
	_terrain_body.add_child(cs)
	add_child(_terrain_body)

# Repère une fois pour toutes les arbres du chunk : les reconstructions au fil
# des changements de détail repartent de cette liste sans re-balayer les
# 256 colonnes ni resonder le bruit.
func _scan_tree_sites() -> void:
	for lx in SIZE:
		for lz in SIZE:
			var wx := cx * SIZE + lx
			var wz := cz * SIZE + lz
			if gen.has_tree(wx, wz):
				_tree_sites.append(Vector3i(lx, gen.get_height(wx, wz), lz))

# (Re)construit les arbres au niveau de détail courant. Arbre 100 % procédural
# (TreeGen) : construit cube par cube avec une graine dérivée du seed et de la
# position — chaque arbre du monde est unique, mais le même monde (et la même
# reconstruction) redonne exactement les mêmes arbres. Ses cubes font CUBE et
# tombent pile sur la grille du monde ; le callable donne à TreeGen le relief
# autour du pied (racines qui descendent en aval, cubes enterrés retirés en
# amont : jamais un cube d'arbre sur un cube de terrain). Loin du joueur, seuls
# les maillages grossiers sont générés (VRAM) et la collision est sautée (RAM).
func _build_trees() -> void:
	for t in _tree_nodes:
		t.queue_free()
	_tree_nodes.clear()
	for s in _tree_sites:
		var wx := cx * SIZE + s.x
		var wz := cz * SIZE + s.z
		var h := s.y
		var t := TreeGen.build(gen.world_seed, wx, wz,
			gen.get_biome(wx, wz) == TerrainGen.Biome.SNOW,
			func(dx: int, dz: int) -> int:
				return gen.get_height(wx + dx, wz + dz) - h,
			tree_detail, collision_on)
		add_child(t)
		t.position = Vector3(s.x * CUBE, (float(h) + 0.5) * CUBE, s.z * CUBE)
		_tree_nodes.append(t)

# Ombres rondes sous les troncs : un seul MultiMesh par chunk. Le jeu n'a PLUS
# d'ombres temps réel (choix assumé, 2026-07-26) : ces disques sont LE système
# d'ombre des arbres, affichés en permanence. Indépendant du niveau de
# détail : construit une seule fois.
func _build_tree_shadows() -> void:
	if _tree_sites.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	# Rayon 6 m : de l'ordre des canopées procédurales (12-17 m de large) —
	# agrandi depuis 4 m quand ces disques sont devenus la seule ombre du jeu.
	mm.mesh = FX.blob_shadow_mesh(6.0)
	mm.instance_count = _tree_sites.size()
	for i in _tree_sites.size():
		var s := _tree_sites[i]
		mm.set_instance_transform(i, Transform3D(Basis(),
			Vector3(s.x * CUBE, (float(s.y) + 0.5) * CUBE + 0.04, s.z * CUBE)))
	tree_shadow_mmi = MultiMeshInstance3D.new()
	tree_shadow_mmi.multimesh = mm
	tree_shadow_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(tree_shadow_mmi)

# Hauteur des brins à la NAISSANCE d'une nappe (bruit pile au seuil), en
# fraction de la hauteur de l'asset ; elle monte à 1 au cœur (grass_amount).
const GRASS_MIN_H := 0.35

# Herbe : les touffes (TerrainGen.grass_amount) d'un chunk tiennent dans UN
# seul MultiMesh du maillage fusionné — 1 draw call quelle que soit la densité.
# La quantité de bruit au-dessus du seuil pilote la HAUTEUR par instance
# (échelle Y : herbe rase aux lisières des nappes, haute au cœur). La couleur
# par instance reprend la couleur du bloc de surface (biome + dérive de teinte
# comprises), légèrement éclaircie pour que les brins se détachent du sol.
func _build_grass() -> void:
	var transforms: Array[Transform3D] = []
	var colors: Array[Color] = []
	for lx in SIZE:
		for lz in SIZE:
			var wx := cx * SIZE + lx
			var wz := cz * SIZE + lz
			var amount := gen.grass_amount(wx, wz)
			if amount <= 0.0:
				continue
			var h := gen.get_height(wx, wz)
			# Quart de tour déterministe par bloc : casse la répétition du motif.
			var b := Basis(Vector3.UP, floorf(gen.rand01(wx, wz, 25) * 4.0) * (PI / 2.0)) \
				.scaled(Vector3(1.0, lerpf(GRASS_MIN_H, 1.0, amount), 1.0))
			transforms.append(Transform3D(b, Vector3(lx * CUBE, (float(h) + 0.5) * CUBE, lz * CUBE)))
			colors.append(gen.get_color(wx, wz, h, h).lightened(0.07))
	if transforms.is_empty():
		return

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = GRASS_MESH
	mm.instance_count = transforms.size()
	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])
		mm.set_instance_color(i, colors[i])

	if _grass_material == null:
		var sh := Shader.new()
		sh.code = GRASS_SHADER
		_grass_material = ShaderMaterial.new()
		_grass_material.shader = sh
	grass_mmi = MultiMeshInstance3D.new()
	grass_mmi.multimesh = mm
	grass_mmi.material_override = _grass_material
	grass_mmi.visible = grass_visible
	# Plus d'ombres temps réel dans le jeu (2026-07-26) : projection coupée
	# aussi ici, au cas où une lumière à ombres réapparaîtrait un jour.
	grass_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if grass_view_dist > 0.0:
		# L'herbe disparaît (en fondu) bien avant la limite des chunks :
		# invisible de loin de toute façon, et chaque touffe se paie en sommets.
		grass_mmi.visibility_range_end = grass_view_dist
		grass_mmi.visibility_range_end_margin = 4.0
		grass_mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(grass_mmi)

# L'eau est un BLOC comme les autres, SANS COLLISION : chaque colonne immergée
# porte un bloc d'eau de surface, aligné sur la grille du monde, dont on émet
# la face du dessus (les faces latérales et le dessous sont toujours contre du
# terrain ou un autre bloc d'eau : jamais visibles, on ne les génère pas). Le
# dessus du bloc est posé au niveau WATER_Y (bloc de surface partiel, comme le
# gameplay l'attend).
# Aucun StaticBody : on traverse l'eau librement (la nage sonde le terrain).
func _build_water() -> void:
	if water_material == null:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any := false
	var y := TerrainGen.WATER_Y * CUBE # dessus du bloc d'eau de surface
	for lx in SIZE:
		for lz in SIZE:
			var wx := cx * SIZE + lx
			var wz := cz * SIZE + lz
			if float(gen.get_height(wx, wz)) + 0.5 >= TerrainGen.WATER_Y:
				continue # colonne émergée : pas de bloc d'eau ici
			any = true
			var x0 := (lx - 0.5) * CUBE
			var x1 := (lx + 0.5) * CUBE
			var z0 := (lz - 0.5) * CUBE
			var z1 := (lz + 0.5) * CUBE
			_water_vertex(st, Vector3(x0, y, z0), Vector2(0, 0))
			_water_vertex(st, Vector3(x1, y, z0), Vector2(1, 0))
			_water_vertex(st, Vector3(x1, y, z1), Vector2(1, 1))
			_water_vertex(st, Vector3(x0, y, z0), Vector2(0, 0))
			_water_vertex(st, Vector3(x1, y, z1), Vector2(1, 1))
			_water_vertex(st, Vector3(x0, y, z1), Vector2(0, 1))
	if not any:
		return
	st.generate_tangents() # requis par le NORMAL_MAP du shader d'eau
	st.index() # fusionne les sommets répétés des quads (6 -> 4 par bloc)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = water_material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

func _water_vertex(st: SurfaceTool, v: Vector3, uv: Vector2) -> void:
	st.set_normal(Vector3.UP)
	# UV locales au bloc (0..1 par face). Les vaguelettes du shader, elles,
	# s'ancrent en coordonnées MONDE (via MODEL_MATRIX) : aucune couture entre
	# blocs ni entre chunks.
	st.set_uv(uv)
	st.add_vertex(v)

func _column_bottom(wx: int, wz: int, h: int) -> int:
	var m := h
	m = mini(m, gen.get_height(wx + 1, wz))
	m = mini(m, gen.get_height(wx - 1, wz))
	m = mini(m, gen.get_height(wx, wz + 1))
	m = mini(m, gen.get_height(wx, wz - 1))
	return m

func _quad(faces: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	faces.append(a); faces.append(b); faces.append(c)
	faces.append(a); faces.append(c); faces.append(d)

func _side(faces: PackedVector3Array, nwx: int, nwz: int, h: int, xa: float, za: float, xb: float, zb: float) -> void:
	var nh := gen.get_height(nwx, nwz)
	if nh >= h:
		return # voisin aussi haut ou plus haut : rien d'exposé
	var y_top := (float(h) + 0.5) * CUBE
	var y_bot := (float(nh) + 0.5) * CUBE
	_quad(faces,
		Vector3(xa, y_bot, za), Vector3(xb, y_bot, zb),
		Vector3(xb, y_top, zb), Vector3(xa, y_top, za))
