class_name MainMenu
extends CanvasLayer

# Menu principal façon Cube World : on choisit (ou crée) un PERSONNAGE, puis un
# MONDE, puis on joue. Personnages (progression comprise : niveau, XP, équipement,
# sac) et mondes (nom + graine) sont persistés dans user://profiles.cfg — les
# fonctions statiques de persistance sont aussi utilisées par world.gd pour
# sauvegarder la progression en cours de partie.
# Créé par world.gd au lancement ; émet start_game puis world.gd le libère.

signal start_game(character: Dictionary, world_entry: Dictionary)

const SAVE_PATH := "user://profiles.cfg"

var options: OptionsMenu = null # posé par world.gd (bouton Options de l'accueil)

var _frame: PanelContainer      # conteneur de la page courante (reconstruite à chaque navigation)
var _selected_char := {}
var _name_edit: LineEdit
var _world_name_edit: LineEdit
var _seed_edit: LineEdit

# ---------- Persistance (statique : world.gd s'en sert aussi) ----------

static func _load_cf() -> ConfigFile:
	var cf := ConfigFile.new()
	cf.load(SAVE_PATH) # absent au premier lancement : liste vide, pas une erreur
	return cf

static func _next_id(cf: ConfigFile) -> int:
	var n: int = cf.get_value("meta", "next_id", 1)
	cf.set_value("meta", "next_id", n + 1)
	return n

static func list_characters() -> Array:
	return _list_entries("char_")

static func list_worlds() -> Array:
	return _list_entries("world_")

static func _list_entries(prefix: String) -> Array:
	var cf := _load_cf()
	var out: Array = []
	for section in cf.get_sections():
		if section.begins_with(prefix):
			var d := {"key": section}
			for k in cf.get_section_keys(section):
				d[k] = cf.get_value(section, k)
			out.append(d)
	return out

static func create_character(char_name: String, class_id: String) -> Dictionary:
	var cf := _load_cf()
	var key := "char_%d" % _next_id(cf)
	var ch := {"key": key, "name": char_name, "class_id": class_id,
		"level": 1, "xp": 0, "xp_to_next": 100,
		"equipment": {"weapon": null, "armor": null, "amulet": null}, "inventory": []}
	_write_entry(cf, key, ch)
	cf.save(SAVE_PATH)
	return ch

static func create_world(world_name: String, seed_value: int) -> Dictionary:
	var cf := _load_cf()
	var key := "world_%d" % _next_id(cf)
	var w := {"key": key, "name": world_name, "seed": seed_value}
	_write_entry(cf, key, w)
	cf.save(SAVE_PATH)
	return w

# Réécrit l'entrée complète (clé = section) : sert aussi de sauvegarde de progression.
static func save_character(ch: Dictionary) -> void:
	if not ch.has("key"):
		return
	var cf := _load_cf()
	_write_entry(cf, ch["key"], ch)
	cf.save(SAVE_PATH)

static func _write_entry(cf: ConfigFile, key: String, data: Dictionary) -> void:
	for k in data:
		if k != "key":
			cf.set_value(key, k, data[k])

static func delete_entry(key: String) -> void:
	var cf := _load_cf()
	if cf.has_section(key):
		cf.erase_section(key)
	cf.save(SAVE_PATH)

# ---------- Interface ----------

func _ready() -> void:
	# SOUS le menu Options (layer 10) : le bouton « Options » l'ouvre par-dessus.
	# (Avant, le menu était au layer 20 : les options s'ouvraient DERRIÈRE,
	# invisibles, et la pause gelait les boutons — tout le menu semblait mort.)
	layer = 5
	# Insensible à la pause : les boutons répondent toujours au retour des options.
	process_mode = Node.PROCESS_MODE_ALWAYS
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_build_root()
	_show_page("home")

func _build_root() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.08, 0.13)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	# Bandeau décoratif : dégradé horizon, clin d'œil au monde de cubes.
	var band := ColorRect.new()
	band.color = Color(0.13, 0.22, 0.36)
	band.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	band.custom_minimum_size = Vector2(0, 180)
	band.offset_top = -180
	bg.add_child(band)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.add_child(center)

	_frame = PanelContainer.new()
	_frame.custom_minimum_size = Vector2(620, 0)
	center.add_child(_frame)

func _show_page(page: String) -> void:
	for c in _frame.get_children():
		c.queue_free()
	match page:
		"home":
			_frame.add_child(_build_home())
		"chars":
			_frame.add_child(_build_chars())
		"newchar":
			_frame.add_child(_build_newchar())
		"worlds":
			_frame.add_child(_build_worlds())
		"newworld":
			_frame.add_child(_build_newworld())

func _page_box(title_text: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	var margin := MarginContainer.new() # respiration dans le panneau
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 18)
	var title := Label.new()
	title.text = title_text
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	box.add_child(title)
	margin.add_child(box)
	# On renvoie le VBox mais c'est le MarginContainer qui est ajouté au cadre.
	box.set_meta("wrap", margin)
	return box

func _wrap(box: VBoxContainer) -> Control:
	return box.get_meta("wrap")

func _nav_button(box: VBoxContainer, text: String, cb: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.pressed.connect(cb)
	box.add_child(btn)
	return btn

func _back_button(box: VBoxContainer, target: String) -> void:
	box.add_child(HSeparator.new())
	_nav_button(box, "← Retour", func(): _show_page(target))

# Bouton de suppression en deux temps : ✕ puis « Sûr ? ».
func _delete_button(key: String, refresh_page: String) -> Button:
	var del := Button.new()
	del.text = "✕"
	del.tooltip_text = "Supprimer"
	del.pressed.connect(func():
		if del.text == "✕":
			del.text = "Sûr ?"
		else:
			MainMenu.delete_entry(key)
			_show_page(refresh_page))
	return del

# ---------- Pages ----------

func _build_home() -> Control:
	var box := _page_box("")
	box.get_child(0).queue_free() # pas de petit titre : le gros logo suffit

	var logo := Label.new()
	logo.text = "BLOCK WORLD"
	logo.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	logo.add_theme_font_size_override("font_size", 58)
	logo.add_theme_color_override("font_color", Color(0.55, 0.78, 1.0))
	box.add_child(logo)

	var sub := Label.new()
	sub.text = "Un monde de cubes à explorer"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_color_override("font_color", Color(0.6, 0.62, 0.7))
	box.add_child(sub)

	box.add_child(HSeparator.new())
	_nav_button(box, "Jouer", func(): _show_page("chars"))
	_nav_button(box, "Options", func():
		if options != null:
			options._set_open(true))
	_nav_button(box, "Quitter", func(): get_tree().quit())
	return _wrap(box)

func _build_chars() -> Control:
	var box := _page_box("Choisis ton personnage")
	var chars := MainMenu.list_characters()
	if chars.is_empty():
		var empty := Label.new()
		empty.text = "Aucun personnage pour l'instant — crée le premier !"
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.add_theme_color_override("font_color", Color(0.6, 0.62, 0.7))
		box.add_child(empty)
	for ch in chars:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var cls: Dictionary = Player.CLASSES.get(ch.get("class_id", "warrior"), Player.CLASSES["warrior"])
		var swatch := ColorRect.new()
		swatch.color = cls["color"]
		swatch.custom_minimum_size = Vector2(26, 26)
		row.add_child(swatch)
		var pick := Button.new()
		pick.text = "%s — %s niv. %d" % [ch.get("name", "?"), cls["name"], ch.get("level", 1)]
		pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pick.pressed.connect(func():
			_selected_char = ch
			_show_page("worlds"))
		row.add_child(pick)
		row.add_child(_delete_button(ch["key"], "chars"))
		box.add_child(row)
	box.add_child(HSeparator.new())
	_nav_button(box, "+ Nouveau personnage", func(): _show_page("newchar"))
	_back_button(box, "home")
	return _wrap(box)

func _build_newchar() -> Control:
	var box := _page_box("Nouveau personnage")

	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "Nom de l'aventurier"
	_name_edit.max_length = 24
	box.add_child(_name_edit)

	# Cartes de classes : couleurs/stats depuis Player.CLASSES, textes
	# descriptifs depuis ClassSelect.CARDS (mêmes sources que l'ancien écran).
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	for card in ClassSelect.CARDS:
		row.add_child(_class_card(card))
	box.add_child(row)

	_back_button(box, "chars")
	return _wrap(box)

func _class_card(card: Dictionary) -> Control:
	var id: String = card["id"]
	var cls: Dictionary = Player.CLASSES[id]
	var panel := PanelContainer.new()
	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(150, 0)
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)

	var swatch_wrap := CenterContainer.new()
	var swatch := ColorRect.new()
	swatch.color = cls["color"]
	swatch.custom_minimum_size = Vector2(40, 40)
	swatch_wrap.add_child(swatch)
	v.add_child(swatch_wrap)

	var name_lbl := Label.new()
	name_lbl.text = cls["name"]
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 20)
	v.add_child(name_lbl)

	var stats := Label.new()
	stats.text = "PV %d · Dég. %d" % [cls["health"], cls["damage"]]
	stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(stats)

	var desc := Label.new()
	desc.text = card["desc"]
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(140, 70)
	desc.add_theme_font_size_override("font_size", 13)
	desc.add_theme_color_override("font_color", Color(0.72, 0.74, 0.8))
	v.add_child(desc)

	var btn := Button.new()
	btn.text = "Choisir"
	btn.pressed.connect(func():
		var char_name := _name_edit.text.strip_edges()
		if char_name.is_empty():
			char_name = "Aventurier"
		_selected_char = MainMenu.create_character(char_name, id)
		_show_page("worlds"))
	v.add_child(btn)
	return panel

func _build_worlds() -> Control:
	var box := _page_box("Choisis un monde — %s" % _selected_char.get("name", "?"))
	var worlds := MainMenu.list_worlds()
	if worlds.is_empty():
		var empty := Label.new()
		empty.text = "Aucun monde pour l'instant — génère le premier !"
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.add_theme_color_override("font_color", Color(0.6, 0.62, 0.7))
		box.add_child(empty)
	for w in worlds:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var pick := Button.new()
		pick.text = "%s   (graine %d)" % [w.get("name", "?"), int(w.get("seed", 0))]
		pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pick.pressed.connect(func(): start_game.emit(_selected_char, w))
		row.add_child(pick)
		row.add_child(_delete_button(w["key"], "worlds"))
		box.add_child(row)
	box.add_child(HSeparator.new())
	_nav_button(box, "+ Nouveau monde", func(): _show_page("newworld"))
	_back_button(box, "chars")
	return _wrap(box)

func _build_newworld() -> Control:
	var box := _page_box("Nouveau monde")

	_world_name_edit = LineEdit.new()
	_world_name_edit.placeholder_text = "Nom du monde"
	_world_name_edit.max_length = 24
	box.add_child(_world_name_edit)

	_seed_edit = LineEdit.new()
	_seed_edit.placeholder_text = "Graine (vide = aléatoire, texte accepté)"
	box.add_child(_seed_edit)

	_nav_button(box, "Créer et jouer", func():
		var world_name := _world_name_edit.text.strip_edges()
		if world_name.is_empty():
			world_name = "Nouveau monde"
		var w := MainMenu.create_world(world_name, _parse_seed(_seed_edit.text))
		start_game.emit(_selected_char, w))

	_back_button(box, "worlds")
	return _wrap(box)

# Graine : vide = aléatoire ; nombre = pris tel quel ; texte = hashé (déterministe).
func _parse_seed(text: String) -> int:
	text = text.strip_edges()
	if text.is_empty():
		randomize()
		return randi()
	if text.is_valid_int():
		return text.to_int()
	return text.hash()
