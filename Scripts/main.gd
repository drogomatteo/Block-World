extends Node3D

const CHUNCK_SCENE = preload("res://Scènes/Cubes/Cubes.tscn")

# Streaming : les chunks dans un disque de view_radius autour de la caméra
# sont générés (les plus proches d'abord), ceux qui en sortent sont libérés —
# zone circulaire, comme le brouillard de distance qui la borde.
# La génération (données RLE + maillage) tourne dans un thread de travail ;
# le thread principal ne fait qu'instancier les nœuds des maillages prêts,
# donc les fps ne dépendent plus du coût de génération.
@export var view_radius : int = 15
@export var chunks_per_frame : int = 4  # maximum de chunks instanciés par frame

# LOD : pas du voxel selon la distance (en chunks) — cellules de 1 bloc
# jusqu'à lod1_radius, de 2 jusqu'à lod2_radius, de 4 au-delà (la transition
# 2 -> 4 se fait dans le brouillard). Un chunk qui change d'anneau est
# régénéré par le thread puis REMPLACÉ à l'arrivée du résultat : l'ancien
# maillage reste affiché entre-temps, jamais de trou.
@export var lod1_radius : int = 8
@export var lod2_radius : int = 12

# Brouillard dynamique : opaque juste avant le chunk MANQUANT le plus proche
# de la caméra (pas au rayon visé) — il colle à la frontière de génération au
# chargement ou en vol rapide, puis s'ouvre quand elle s'éloigne.
@export var fog_expand_speed : float = 96.0     # m/s à l'ouverture
@export var fog_contract_speed : float = 600.0  # m/s à la fermeture

@onready var camera : Camera3D = $Camera3D

var chunks : Dictionary = {}          # Vector2i(cx, cz) -> Chunk
var last_center := Vector2i(1 << 30, 0)
var _steps : Dictionary = {}          # Vector2i -> pas de LOD du chunk instancié

var _env : Environment
var _chunks_dirty := true   # l'ensemble des chunks a changé -> recalculer la frontière
var _frontier := 0.0        # distance (en chunks) du chunk manquant le plus proche
var _scan_offsets : Array = []  # offsets du disque de rayon view_radius+1, proches d'abord

# Communication avec le thread de génération
var _thread : Thread
var _mutex := Mutex.new()
var _sem := Semaphore.new()
var _work : Array = []      # positions à générer, les plus proches d'abord
var _done : Array = []      # résultats prêts : [position, ChunkData, ArrayMesh]
var _quit := false
var _noise : FastNoiseLite
var _with_trees : bool = true
var _pulling : bool = true  # vertex pulling (cf. Chunk.vertex_pulling)

func _ready() -> void:
	RenderingServer.set_debug_generate_wireframes(true)
	# Départ brouillard fermé : rien n'est encore généré, le monde s'ouvrira
	# au rythme de la génération (voir _update_fog).
	_env = $WorldEnvironment.environment
	_env.fog_depth_end = Chunk.width * Chunk.cube_size * 0.5
	_env.fog_depth_begin = _env.fog_depth_end * 0.5
	# Offsets du disque de streaming triés par distance : sert d'ordre de
	# génération (proche d'abord) et de parcours pour trouver la frontière.
	# Rayon +1 : l'anneau jamais chargé fait butée naturelle du balayage.
	var outer := (view_radius + 1) * (view_radius + 1)
	for dx in range(-view_radius - 1, view_radius + 2):
		for dz in range(-view_radius - 1, view_radius + 2):
			var o := Vector2i(dx, dz)
			if o.length_squared() <= outer:
				_scan_offsets.append(o)
	_scan_offsets.sort_custom(func(a, b):
		return a.length_squared() < b.length_squared())
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

# Marge de 1 chunk avant déchargement pour ne pas alterner charge / décharge
# quand la caméra oscille autour d'une frontière de chunk.
func recenter(center : Vector2i) -> void:
	_chunks_dirty = true
	var keep := (view_radius + 1) * (view_radius + 1)
	for pos in chunks.keys():
		if (pos - center).length_squared() > keep:
			chunks[pos].queue_free()
			chunks.erase(pos)
			_steps.erase(pos)

	# _scan_offsets est déjà trié proche d'abord ; on ne génère que le disque
	# de view_radius (l'anneau au-delà n'est gardé que par l'hystérésis).
	# Un chunk présent au mauvais pas de LOD est re-demandé, pas déchargé.
	var wanted : Array = []
	var inner := view_radius * view_radius
	for o in _scan_offsets:
		if o.length_squared() > inner:
			break
		var pos : Vector2i = center + o
		var want := _desired_step(o)
		if not chunks.has(pos) or _steps.get(pos, 0) != want:
			wanted.append([pos, want])

	# remplace la file du thread : l'ordre redevient « proche d'abord » et les
	# positions sorties du disque ne seront jamais générées
	_mutex.lock()
	_work = wanted
	_mutex.unlock()
	for i in wanted.size():
		_sem.post()

# Récupère les chunks générés par le thread et les instancie (borné par
# chunks_per_frame pour lisser les frames, le reste attend la suivante).
func _collect_results() -> void:
	var results : Array = []
	_mutex.lock()
	while results.size() < chunks_per_frame and not _done.is_empty():
		results.append(_done.pop_front())
	_mutex.unlock()

	var keep := (view_radius + 1) * (view_radius + 1)
	for r in results:
		var pos : Vector2i = r[0]
		var r_step : int = r[1]
		if (pos - last_center).length_squared() > keep:
			continue  # sorti du disque pendant la génération
		var want := _desired_step(pos - last_center)
		if chunks.has(pos):
			if _steps.get(pos, 0) == r_step or r_step != want:
				continue  # doublon, ou changement de LOD devenu périmé
			chunks[pos].queue_free()  # remplacement de LOD : l'ancien couvrait jusqu'ici
		elif r_step != want:
			# résultat d'un LOD périmé mais mieux qu'un trou : on l'affiche et
			# on redemande tout de suite le bon pas
			_mutex.lock()
			_work.push_front([pos, want])
			_mutex.unlock()
			_sem.post()
		var chunk = CHUNCK_SCENE.instantiate()
		chunk.chunk_position = Vector3i(pos.x, 0, pos.y)
		chunk.position = Vector3(pos.x * Chunk.width, 0, pos.y * Chunk.depth) * Chunk.cube_size
		add_child(chunk)
		if r[3] is Dictionary:
			chunk.apply_generated_packed(r[2], r[3])
		else:
			chunk.apply_generated(r[2], r[3])
		chunks[pos] = chunk
		_steps[pos] = r_step
		_chunks_dirty = true

# Vise la frontière moins une marge de 1,5 chunk (caméra excentrée dans son
# chunk + coin le plus proche du chunk manquant), et s'y rend à vitesse
# bornée : fermeture rapide (cacher la frontière qui se rapproche), ouverture
# douce (pas d'à-coup quand un trou se comble).
func _update_fog(delta: float) -> void:
	if _chunks_dirty:
		_chunks_dirty = false
		_frontier = _nearest_missing()
	var span := Chunk.width * Chunk.cube_size
	var target : float = maxf((_frontier - 1.5) * span, span * 0.25)
	var end : float = _env.fog_depth_end
	var speed := fog_expand_speed if target > end else fog_contract_speed
	end = move_toward(end, target, speed * delta)
	_env.fog_depth_end = end
	_env.fog_depth_begin = end * 0.5

# Pas de LOD voulu pour un chunk à l'offset o du centre.
func _desired_step(o : Vector2i) -> int:
	var d2 := o.length_squared()
	if d2 <= lod1_radius * lod1_radius:
		return 1
	if d2 <= lod2_radius * lod2_radius:
		return 2
	return 4

# Distance (en chunks) entre le centre et le chunk absent le plus proche.
# Le balayage suit _scan_offsets (proches d'abord) ; l'anneau au-delà de
# view_radius n'étant jamais généré, il borne toujours le résultat.
func _nearest_missing() -> float:
	for o in _scan_offsets:
		if not chunks.has(last_center + o):
			return Vector2(o).length()
	return float(view_radius) + 1.0

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

		var pos : Vector2i = item[0]
		var lod : int = item[1]
		var data := ChunkData.new()
		data.build(_noise, Vector3i(pos.x, 0, pos.y), _with_trees, lod)
		var result = ChunkMesher.build_packed(data) if _pulling else ChunkMesher.build(data)

		_mutex.lock()
		_done.append([pos, lod, data, result])
		_mutex.unlock()

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
				# chemin classique + le matériau par chunk du vertex pulling
				# (y compris ceux créés après l'appui, via apply_generated_packed)
				Chunk.show_borders = not Chunk.show_borders
				if Chunk.block_material != null:
					Chunk.block_material.set_shader_parameter("show_chunk_borders", Chunk.show_borders)
				for c in chunks.values():
					if c.material_override is ShaderMaterial:
						c.material_override.set_shader_parameter("show_chunk_borders", Chunk.show_borders)
