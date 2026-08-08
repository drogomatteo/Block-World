extends CanvasLayer
# Minimap temps réel des biomes (F5 pour afficher/masquer) : carte de
# SIZE×SIZE pixels centrée sur la caméra, SCALE blocs par pixel, en haut à
# droite. Chaque pixel = couleur du biome EXACT (BiomeMap.biome_exact, Worley
# pur — jamais le cache de TerrainHeight, qui appartient au thread de
# génération). Le calcul est étalé sur plusieurs frames (ROWS_PER_FRAME
# lignes par frame) : la texture est mise à jour à chaque balayage complet,
# recentrée sur la caméra au début du suivant.

const SIZE := 128
const SCALE := 32.0         # blocs par pixel -> la carte couvre 4096 blocs
							# (rayon de rendu 3200 inclus, ~2 cellules de biome)
const ROWS_PER_FRAME := 2
const VIEW := 256.0         # taille affichée à l'écran, en pixels

# Couleurs par biome (montagnes en GRIS pierre, cf. strates)
const COLORS := [
	Color(0.52, 0.53, 0.57),  # montagnes
	Color(0.30, 0.72, 0.25),  # plaines
	Color(0.93, 0.95, 0.98),  # plaines enneigées
	Color(0.18, 0.42, 0.85),  # océan
	Color(0.86, 0.73, 0.42),  # désert
]

@onready var _main = get_parent()
var _img : Image
var _tex : ImageTexture
var _row := 0
var _origin := Vector2.ZERO  # coin monde (x/z min) du balayage en cours

func _ready() -> void:
	_img = Image.create(SIZE, SIZE, false, Image.FORMAT_RGB8)
	_tex = ImageTexture.create_from_image(_img)
	var rect := TextureRect.new()
	rect.texture = _tex
	rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	rect.anchor_left = 1.0
	rect.anchor_right = 1.0
	rect.offset_left = -VIEW - 16.0
	rect.offset_right = -16.0
	rect.offset_top = 16.0
	rect.offset_bottom = VIEW + 16.0
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(rect)
	# marqueur caméra : la carte est centrée sur elle
	var dot := ColorRect.new()
	dot.color = Color(1.0, 0.25, 0.2)
	dot.size = Vector2(6, 6)
	dot.position = Vector2(VIEW, VIEW) * 0.5 - Vector2(3, 3)
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.add_child(dot)

func _process(_delta : float) -> void:
	if not visible:
		return
	var seed_w : int = _main._noise.seed
	if _row == 0:
		var c : Vector3 = _main.camera.position
		_origin = Vector2(c.x, c.z) - Vector2(SIZE, SIZE) * (SCALE * 0.5)
	for _i in range(ROWS_PER_FRAME):
		if _row >= SIZE:
			break
		var z := _origin.y + (_row + 0.5) * SCALE
		for px in range(SIZE):
			var b : int = BiomeMap.biome_exact(seed_w, _origin.x + (px + 0.5) * SCALE, z)
			_img.set_pixel(px, _row, COLORS[b])
		_row += 1
	if _row >= SIZE:
		_tex.update(_img)
		_row = 0

func _input(event : InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_F5:
		visible = not visible
