extends Node3D

const CHUNCK_SCENE = preload("res://Scènes/Cubes/Cubes.tscn")

# Streaming par QUADTREE de terrain (l'« octree » d'un monde en colonnes :
# le découpage est en x/z, l'axe y vit dans les cellules verticales des
# nœuds). Le disque de view_radius chunks autour de la caméra est pavé de
# nœuds de niveau 0..MAX_LEVEL : un nœud de niveau k couvre 2^k × 2^k chunks
# avec une grille FIXE de 32×32 cellules de 2^k blocs — chaque nœud coûte à
# peu près le même maillage, qu'il fasse 32 ou 512 blocs de large. Près de
# la caméra les nœuds sont fins (arbres, blocs unité), au loin ils sont
# énormes : ~1000 nœuds couvrent un rayon de 100 chunks (3 200 blocs).
#
# Remplacement sans trou : quand une zone change de niveau, l'ancien nœud
# n'est libéré que lorsque TOUTE sa surface est couverte par les nœuds
# désirés arrivés (_prune/_covered) — l'ancien maillage reste affiché entre
# temps. La génération (RLE + maillage) tourne dans un thread de travail.
@export var view_radius : int = 100
@export var chunks_per_frame : int = 4  # maximum de nœuds instanciés par frame
# lod_rings[k-1] : en deçà de cette distance (en chunks), un nœud de
# niveau k est trop grossier et se subdivise en 4.
@export var lod_rings : PackedInt32Array = [10, 20, 40, 80]
const MAX_LEVEL := 4

# Brouillard dynamique : opaque juste avant le nœud MANQUANT le plus proche
# de la caméra — il colle à la frontière de génération au chargement ou en
# vol rapide, puis s'ouvre quand elle s'éloigne.
@export var fog_expand_speed : float = 20.0     # m/s à l'ouverture
@export var fog_contract_speed : float = 100.0  # m/s à la fermeture

@onready var camera : Camera3D = $Camera3D
@onready var water : MeshInstance3D = $Water
@onready var terminal = $Terminal
@onready var sky = $SkyCycle

var nodes : Dictionary = {}     # Vector3i(niveau, tx, tz) -> Chunk
var _desired : Dictionary = {}  # Vector3i -> distance à la caméra (chunks)
var last_center := Vector2i(1 << 30, 0)

var _env : Environment
var _chunks_dirty := true   # l'ensemble des nœuds a changé -> recalculer la frontière
var _frontier := 0.0        # distance (en chunks) du vide non généré le plus proche
var _frontier_wait := 0.0   # recalcul au plus toutes les 0,2 s (tri des manquants)

# Communication avec le thread de génération
var _thread : Thread
var _mutex := Mutex.new()
var _sem := Semaphore.new()
var _work : Array = []      # [clé, gen_id] à générer, les plus proches d'abord
var _done : Array = []      # résultats prêts : [gen_id, clé, ChunkData, maillage]
var _quit := false
var _noise : FastNoiseLite
var _with_trees : bool = true
var _pulling : bool = true  # vertex pulling (cf. Chunk.vertex_pulling)
var _gen_id := 1            # incrémenté par « regenerate » : invalide les résultats en vol

func _ready() -> void:
	RenderingServer.set_debug_generate_wireframes(true)
	# Départ brouillard fermé : rien n'est encore généré, le monde s'ouvrira
	# au rythme de la génération (voir _update_fog).
	_env = $WorldEnvironment.environment
	_env.fog_depth_end = Chunk.width * Chunk.cube_size * 0.5
	_env.fog_depth_begin = _env.fog_depth_end * 0.5
	# Surface de l'océan : juste sous la face supérieure (SEA_LEVEL + 0.5)
	# des colonnes qui affleurent — une colonne de hauteur SEA_LEVEL émerge.
	water.position.y = (WorldConfig.SEA_LEVEL + 0.35) * Chunk.cube_size
	terminal.command.connect(_run_command)
	# le bruit et les réglages de génération sont portés par la scène de chunk
	var template = CHUNCK_SCENE.instantiate()
	_noise = template.noise
	_with_trees = template.generate_trees
	_pulling = template.vertex_pulling
	template.free()
	_thread = Thread.new()
	_thread.start(_worker_loop)

func _exit_tree() -> void:
	_mutex.lock()
	_quit = true
	_mutex.unlock()
	_sem.post()
	_thread.wait_to_finish()

func _process(delta: float) -> void:
	var center := Vector2i(
		floori(camera.position.x / (Chunk.width * Chunk.cube_size)),
		floori(camera.position.z / (Chunk.depth * Chunk.cube_size))
	)
	if center != last_center:
		last_center = center
		recenter(center)
	_collect_results()
	_update_fog(delta)
	# le plan d'eau suit la caméra (motif en coordonnées monde dans le shader :
	# le glissement est invisible)
	water.position.x = camera.position.x
	water.position.z = camera.position.z

# Recalcule le pavage désiré (descente de quadtree) et remet la file du
# thread : l'ordre redevient « proche d'abord » et les nœuds sortis du
# disque ne seront jamais générés.
func recenter(center : Vector2i) -> void:
	_chunks_dirty = true
	_desired.clear()
	var c := Vector2(center) + Vector2(0.5, 0.5)
	var S := 1 << MAX_LEVEL
	for tx in range(floori(float(center.x - view_radius) / S), floori(float(center.x + view_radius) / S) + 1):
		for tz in range(floori(float(center.y - view_radius) / S), floori(float(center.y + view_radius) / S) + 1):
			_select(MAX_LEVEL, Vector2i(tx, tz), c)

	# Priorité aux TROUS (zones qu'aucun nœud n'affiche : nouveau terrain au
	# front du déplacement) sur les mises à niveau de LOD (l'ancien nœud reste
	# affiché en attendant) : en vol soutenu, tout le débit du worker part
	# dans le front — le brouillard reste ouvert, le raffinement des anneaux
	# rattrape quand on ralentit.
	var holes : Array = []
	var upgrades : Array = []
	for key in _desired:
		if nodes.has(key):
			continue
		if _rendered(key.x, Vector2i(key.y, key.z)):
			upgrades.append(key)
		else:
			holes.append(key)
	var by_dist := func(a, b): return _desired[a] < _desired[b]
	holes.sort_custom(by_dist)
	upgrades.sort_custom(by_dist)
	var items : Array = []
	for key in holes:
		items.append([key, _gen_id])
	for key in upgrades:
		items.append([key, _gen_id])
	_mutex.lock()
	_work = items
	_mutex.unlock()
	for i in items.size():
		_sem.post()
	_prune()

# Descente du quadtree : garde le nœud tel quel s'il est assez loin pour son
# niveau, sinon le subdivise en 4 ; hors du rayon, rien.
func _select(level : int, t : Vector2i, c : Vector2) -> void:
	var S := 1 << level
	var mn := Vector2(t * S)
	var d := c.distance_to(c.clamp(mn, mn + Vector2(S, S)))
	if d > float(view_radius):
		return
	if level > 0 and d < float(lod_rings[level - 1]):
		var t2 := t * 2
		_select(level - 1, t2, c)
		_select(level - 1, t2 + Vector2i(1, 0), c)
		_select(level - 1, t2 + Vector2i(0, 1), c)
		_select(level - 1, t2 + Vector2i(1, 1), c)
	else:
		_desired[Vector3i(level, t.x, t.y)] = d

# Récupère les nœuds générés par le thread et les instancie (borné par
# chunks_per_frame pour lisser les frames, le reste attend la suivante).
func _collect_results() -> void:
	var results : Array = []
	_mutex.lock()
	while results.size() < chunks_per_frame and not _done.is_empty():
		results.append(_done.pop_front())
	_mutex.unlock()

	for r in results:
		if r[0] != _gen_id:
			continue  # résultat d'un monde régénéré depuis
		var key : Vector3i = r[1]
		if not _desired.has(key) or nodes.has(key):
			continue  # sorti du pavage désiré pendant la génération, ou doublon
		var S := 1 << key.x
		var cpos := Vector2i(key.y, key.z) * S
		var chunk = CHUNCK_SCENE.instantiate()
		chunk.chunk_position = Vector3i(cpos.x, 0, cpos.y)
		chunk.position = Vector3(cpos.x * Chunk.width, 0, cpos.y * Chunk.depth) * Chunk.cube_size
		add_child(chunk)
		if r[3] is Dictionary:
			chunk.apply_generated_packed(r[2], r[3])
		else:
			chunk.apply_generated(r[2], r[3])
		nodes[key] = chunk
		_chunks_dirty = true
	if not results.is_empty():
		_prune()

# Libère les nœuds qui ne sont plus désirés dès que toute leur surface est
# couverte par les nœuds désirés présents — jamais de trou pendant les
# changements de niveau.
func _prune() -> void:
	for key in nodes.keys():
		if _desired.has(key):
			continue
		if _covered(key.x, Vector2i(key.y, key.z)):
			nodes[key].queue_free()
			nodes.erase(key)

# La zone (niveau, tuile) est-elle rendue ? Oui si le nœud désiré qui la
# contient (elle-même ou un ancêtre) est instancié, ou si ses 4 quarts le
# sont récursivement ; une zone hors pavage désiré (hors rayon) est libre.
func _covered(level : int, t : Vector2i) -> bool:
	var key := Vector3i(level, t.x, t.y)
	if _desired.has(key):
		return nodes.has(key)
	var l := level
	var tt := t
	while l < MAX_LEVEL:
		l += 1
		tt = Vector2i(tt.x >> 1, tt.y >> 1)
		var k := Vector3i(l, tt.x, tt.y)
		if _desired.has(k):
			return nodes.has(k)
	if level == 0:
		return true
	var t2 := t * 2
	return _covered(level - 1, t2) and _covered(level - 1, t2 + Vector2i(1, 0)) \
		and _covered(level - 1, t2 + Vector2i(0, 1)) and _covered(level - 1, t2 + Vector2i(1, 1))

# Vise la frontière moins une marge de 1,5 chunk, et s'y rend à vitesse
# bornée : fermeture rapide (cacher la frontière qui se rapproche), ouverture
# douce (pas d'à-coup quand un trou se comble).
func _update_fog(delta: float) -> void:
	_frontier_wait -= delta
	if _chunks_dirty and _frontier_wait <= 0.0:
		_chunks_dirty = false
		_frontier_wait = 0.2
		_frontier = _nearest_missing()
	var span := Chunk.width * Chunk.cube_size
	var target : float = maxf((_frontier - 1.5) * span, span * 0.25)
	var end : float = _env.fog_depth_end
	var speed := fog_expand_speed if target > end else fog_contract_speed
	end = move_toward(end, target, speed * delta)
	_env.fog_depth_end = end
	_env.fog_depth_begin = end * 0.5

# Distance (en chunks) du VIDE le plus proche : le nœud désiré manquant le
# plus près dont la zone n'est affichée par AUCUN nœud instancié — un nœud
# en attente de re-génération (changement de niveau en se déplaçant) dont
# l'ancien nœud couvre encore la zone ne referme PAS le brouillard.
func _nearest_missing() -> float:
	var missing : Array = []
	for key in _desired:
		if not nodes.has(key):
			missing.append(key)
	missing.sort_custom(func(a, b):
		return _desired[a] < _desired[b])
	for key in missing:
		if not _rendered(key.x, Vector2i(key.y, key.z)):
			return _desired[key]
	return float(view_radius) + 1.0

# La zone (niveau, tuile) est-elle affichée par un nœud instancié, désiré ou
# non ? (contrairement à _covered, les nœuds périmés comptent : ils restent
# affichés jusqu'à leur remplacement)
func _rendered(level : int, t : Vector2i) -> bool:
	var l := level
	var tt := t
	while l <= MAX_LEVEL:
		if nodes.has(Vector3i(l, tt.x, tt.y)):
			return true
		l += 1
		tt = Vector2i(tt.x >> 1, tt.y >> 1)
	if level == 0:
		return false
	var t2 := t * 2
	return _rendered(level - 1, t2) and _rendered(level - 1, t2 + Vector2i(1, 0)) \
		and _rendered(level - 1, t2 + Vector2i(0, 1)) and _rendered(level - 1, t2 + Vector2i(1, 1))

# Boucle du thread de génération : ne touche jamais l'arbre de scène. Le
# cache statique de TerrainHeight n'est utilisé que par ce thread.
func _worker_loop() -> void:
	while true:
		_sem.wait()
		_mutex.lock()
		if _quit:
			_mutex.unlock()
			return
		var item = _work.pop_front() if not _work.is_empty() else null
		_mutex.unlock()
		if item == null:
			continue

		var key : Vector3i = item[0]
		var step := 1 << key.x
		var cpos := Vector2i(key.y, key.z) * step
		var data := ChunkData.new()
		data.build(_noise, Vector3i(cpos.x, 0, cpos.y), _with_trees and key.x == 0, step)
		var result = ChunkMesher.build_packed(data) if _pulling else ChunkMesher.build(data)

		_mutex.lock()
		_done.append([item[1], key, data, result])
		_mutex.unlock()

# --- Terminal ---------------------------------------------------------------

func _run_command(text : String) -> void:
	var parts := text.split(" ", false)
	match parts[0]:
		"help":
			terminal.println("regenerate [seed] — régénère le monde (seed aléatoire si omise)")
			terminal.println("seed              — affiche la seed du monde")
			terminal.println("tp <x> <z>        — téléporte la caméra")
			terminal.println("time <0..1>       — heure du cycle (0 aube, 0.25 midi, 0.75 minuit)")
		"regenerate":
			var s : int = int(parts[1]) if parts.size() > 1 else randi()
			_regenerate(s)
		"seed":
			terminal.println("seed : %d" % _noise.seed)
		"tp":
			if parts.size() < 3:
				terminal.println("usage : tp <x> <z>")
				return
			var x := float(parts[1])
			var z := float(parts[2])
			# hauteur via BiomeMap directement : le cache de TerrainHeight
			# appartient au thread de génération
			var h := BiomeMap.height_sample(_noise.seed, x, z)
			camera.position = Vector3(x, maxf(h, WorldConfig.SEA_LEVEL) + 24.0, z)
			terminal.println("téléporté en (%.0f, %.0f)" % [x, z])
		"time":
			if parts.size() < 2:
				terminal.println("usage : time <0..1>")
				return
			sky.time = sky._time_from_percent(clampf(float(parts[1]), 0.0, 1.0))
			terminal.println("heure réglée")
		_:
			terminal.println("commande inconnue : " + parts[0])

# Nouveau monde : vide la file et les nœuds, change la seed (le cache de
# TerrainHeight se vide tout seul au prochain échantillon : seed différente),
# referme le brouillard et force un recenter. Les résultats en vol portent
# l'ancien gen_id et seront jetés.
func _regenerate(new_seed : int) -> void:
	_gen_id += 1
	_mutex.lock()
	_work.clear()
	_mutex.unlock()
	for c in nodes.values():
		c.queue_free()
	nodes.clear()
	_desired.clear()
	_noise.seed = new_seed
	_env.fog_depth_end = Chunk.width * Chunk.cube_size * 0.5
	_env.fog_depth_begin = _env.fog_depth_end * 0.5
	_chunks_dirty = true
	last_center = Vector2i(1 << 30, 0)
	terminal.println("nouveau monde, seed %d" % new_seed)

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_F1:
				var vp := get_viewport()
				if vp.debug_draw == Viewport.DEBUG_DRAW_WIREFRAME:
					vp.debug_draw = Viewport.DEBUG_DRAW_DISABLED
				else:
					vp.debug_draw = Viewport.DEBUG_DRAW_WIREFRAME
			KEY_F2:
				_env.fog_enabled = not _env.fog_enabled
			KEY_F3:
				# état porté par Chunk.show_borders : le matériau partagé du
				# chemin classique + le matériau par nœud du vertex pulling
				# (y compris ceux créés après l'appui, via apply_generated_packed)
				Chunk.show_borders = not Chunk.show_borders
				if Chunk.block_material != null:
					Chunk.block_material.set_shader_parameter("show_chunk_borders", Chunk.show_borders)
				for c in nodes.values():
					if c.material_override is ShaderMaterial:
						c.material_override.set_shader_parameter("show_chunk_borders", Chunk.show_borders)
