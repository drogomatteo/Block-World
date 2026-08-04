extends Node3D

const CHUNCK_SCENE = preload("res://Scènes/Cubes/Cubes.tscn")

# Streaming : les chunks dans un carré de view_radius autour de la caméra
# sont générés (les plus proches d'abord), ceux qui en sortent sont libérés.
# La génération (données RLE + maillage) tourne dans un thread de travail ;
# le thread principal ne fait qu'instancier les nœuds des maillages prêts,
# donc les fps ne dépendent plus du coût de génération.
@export var view_radius : int = 15
@export var chunks_per_frame : int = 4  # maximum de chunks instanciés par frame

@onready var camera : Camera3D = $Camera3D

var chunks : Dictionary = {}          # Vector2i(cx, cz) -> Chunk
var last_center := Vector2i(1 << 30, 0)

# Communication avec le thread de génération
var _thread : Thread
var _mutex := Mutex.new()
var _sem := Semaphore.new()
var _work : Array = []      # positions à générer, les plus proches d'abord
var _done : Array = []      # résultats prêts : [position, ChunkData, ArrayMesh]
var _quit := false
var _noise : FastNoiseLite
var _with_trees : bool = true

func _ready() -> void:
	RenderingServer.set_debug_generate_wireframes(true)
	# le bruit et les réglages de génération sont portés par la scène de chunk
	var template = CHUNCK_SCENE.instantiate()
	_noise = template.noise
	_with_trees = template.generate_trees
	template.free()
	_thread = Thread.new()
	_thread.start(_worker_loop)

func _exit_tree() -> void:
	_mutex.lock()
	_quit = true
	_mutex.unlock()
	_sem.post()
	_thread.wait_to_finish()

func _process(_delta: float) -> void:
	var center := Vector2i(
		floori(camera.position.x / (Chunk.width * Chunk.cube_size)),
		floori(camera.position.z / (Chunk.depth * Chunk.cube_size))
	)
	if center != last_center:
		last_center = center
		recenter(center)
	_collect_results()

# Marge de 1 chunk avant déchargement pour ne pas alterner charge / décharge
# quand la caméra oscille autour d'une frontière de chunk.
func recenter(center : Vector2i) -> void:
	for pos in chunks.keys():
		var d : Vector2i = (pos - center).abs()
		if maxi(d.x, d.y) > view_radius + 1:
			chunks[pos].queue_free()
			chunks.erase(pos)

	var wanted : Array = []
	for dx in range(-view_radius, view_radius + 1):
		for dz in range(-view_radius, view_radius + 1):
			var pos := center + Vector2i(dx, dz)
			if not chunks.has(pos):
				wanted.append(pos)
	wanted.sort_custom(func(a, b):
		return (a - center).length_squared() < (b - center).length_squared())

	# remplace la file du thread : l'ordre redevient « proche d'abord » et les
	# positions sorties du carré ne seront jamais générées
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

	for r in results:
		var pos : Vector2i = r[0]
		var d : Vector2i = (pos - last_center).abs()
		if chunks.has(pos) or maxi(d.x, d.y) > view_radius + 1:
			continue  # doublon, ou sorti du carré pendant la génération
		var chunk = CHUNCK_SCENE.instantiate()
		chunk.chunk_position = Vector3i(pos.x, 0, pos.y)
		chunk.position = Vector3(pos.x * Chunk.width, 0, pos.y * Chunk.depth) * Chunk.cube_size
		add_child(chunk)
		chunk.apply_generated(r[1], r[2])
		chunks[pos] = chunk

# Boucle du thread de génération : ne touche jamais l'arbre de scène. Le
# cache statique de TerrainHeight n'est utilisé que par ce thread.
func _worker_loop() -> void:
	while true:
		_sem.wait()
		_mutex.lock()
		if _quit:
			_mutex.unlock()
			return
		var pos = _work.pop_front() if not _work.is_empty() else null
		_mutex.unlock()
		if pos == null:
			continue

		var data := ChunkData.new()
		data.build(_noise, Vector3i(pos.x, 0, pos.y), _with_trees)
		var mesh := ChunkMesher.build(data)

		_mutex.lock()
		_done.append([pos, data, mesh])
		_mutex.unlock()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F1:
		var vp := get_viewport()
		if vp.debug_draw == Viewport.DEBUG_DRAW_WIREFRAME:
			vp.debug_draw = Viewport.DEBUG_DRAW_DISABLED
		else:
			vp.debug_draw = Viewport.DEBUG_DRAW_WIREFRAME
