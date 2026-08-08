extends Node3D

const CHUNCK_SCENE = preload("res://Scènes/Cubes/Cubes.tscn")

# Streaming PLEIN DÉTAIL, SANS LOD : le disque de view_radius chunks autour
# de la caméra est pavé de chunks 32×256×32 à l'échelle 1, générés du plus
# proche au plus lointain dans un thread de travail (RLE + maillage), et
# déchargés dès qu'ils sortent du disque (+1 chunk d'hystérésis).
@export var view_radius : int = 50
@export var chunks_per_frame : int = 4  # maximum de chunks instanciés par frame

# Brouillard dynamique : opaque juste avant le chunk MANQUANT le plus proche
# de la caméra — il colle à la frontière de génération au chargement ou en
# vol rapide, puis s'ouvre quand elle s'éloigne.
@export var fog_expand_speed : float = 96.0     # m/s à l'ouverture
@export var fog_contract_speed : float = 600.0  # m/s à la fermeture

@onready var camera : Camera3D = $Camera3D
@onready var water : MeshInstance3D = $Water
@onready var terminal = $Terminal
@onready var sky = $SkyCycle

var nodes : Dictionary = {}     # Vector2i(tx, tz) -> Chunk
var _desired : Dictionary = {}  # Vector2i -> distance à la caméra (chunks)
var last_center := Vector2i(1 << 30, 0)

var _env : Environment
var _chunks_dirty := true   # l'ensemble des chunks a changé -> recalculer la frontière
var _frontier := 0.0        # distance (en chunks) du vide non généré le plus proche
var _frontier_wait := 0.0   # recalcul au plus toutes les 0,2 s

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

# Recalcule le disque désiré, décharge les chunks sortis (hystérésis +1) et
# remet la file du thread : l'ordre redevient « proche d'abord » et les
# chunks sortis du disque ne seront jamais générés.
func recenter(center : Vector2i) -> void:
	_chunks_dirty = true
	_desired.clear()
	var c := Vector2(center) + Vector2(0.5, 0.5)
	for tx in range(center.x - view_radius, center.x + view_radius + 1):
		for tz in range(center.y - view_radius, center.y + view_radius + 1):
			var d := c.distance_to(Vector2(tx, tz) + Vector2(0.5, 0.5))
			if d <= float(view_radius):
				_desired[Vector2i(tx, tz)] = d
	for key in nodes.keys():
		if c.distance_to(Vector2(key) + Vector2(0.5, 0.5)) > float(view_radius) + 1.0:
			nodes[key].queue_free()
			nodes.erase(key)
	var missing : Array = []
	for key in _desired:
		if not nodes.has(key):
			missing.append([_desired[key], key])
	missing.sort_custom(func(a, b): return a[0] < b[0])
	var items : Array = []
	for m in missing:
		items.append([m[1], _gen_id])
	_mutex.lock()
	_work = items
	_mutex.unlock()
	for i in items.size():
		_sem.post()

# Récupère les chunks générés par le thread et les instancie (borné par
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
		var key : Vector2i = r[1]
		if not _desired.has(key) or nodes.has(key):
			continue  # sorti du disque pendant la génération, ou doublon
		var chunk = CHUNCK_SCENE.instantiate()
		chunk.chunk_position = Vector3i(key.x, 0, key.y)
		chunk.position = Vector3(key.x * Chunk.width, 0, key.y * Chunk.depth) * Chunk.cube_size
		add_child(chunk)
		if r[3] is Dictionary:
			chunk.apply_generated_packed(r[2], r[3])
		else:
			chunk.apply_generated(r[2], r[3])
		nodes[key] = chunk
		_chunks_dirty = true

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

# Distance (en chunks) du chunk désiré manquant le plus proche.
func _nearest_missing() -> float:
	var best := float(view_radius) + 1.0
	for key in _desired:
		if not nodes.has(key) and _desired[key] < best:
			best = _desired[key]
	return best

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

		var key : Vector2i = item[0]
		var data := ChunkData.new()
		data.build(_noise, Vector3i(key.x, 0, key.y), _with_trees)
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

# Nouveau monde : vide la file et les chunks, change la seed (le cache de
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
