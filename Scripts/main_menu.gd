class_name MainMenu
extends CanvasLayer

# Menu principal façon Cube World : on choisit (ou crée) un PERSONNAGE, puis un
# MONDE, puis on joue. Personnages (progression comprise : niveau, XP, équipement,
# sac) et mondes (nom + graine) sont persistés dans user://profiles.cfg — les
# fonctions statiques de persistance sont aussi utilisées par world.gd pour
# sauvegarder la progression en cours de partie.
# LOGIQUE UNIQUEMENT : les pages (fond, boutons, champs de texte) vivent dans
# Scènes/UI/main_menu.tscn — toutes présentes, une seule visible. Ici :
# navigation, remplissage des listes (personnages/mondes sauvegardés, cartes
# de classes) et actions. Instancié par world.gd ; émet start_game.

signal start_game(character: Dictionary, world_entry: Dictionary)

const SAVE_PATH := "user://profiles.cfg"

var options: OptionsMenu = null # posé par world.gd (bouton Options de l'accueil)

var _pages := {}                # nom de page -> nœud de la scène
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
	# layer 5 (SOUS les Options, layer 10, que le bouton « Options » ouvre
	# par-dessus) et process_mode ALWAYS (boutons insensibles à la pause) sont
	# réglés dans la scène.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_pages = {"home": %HomePage, "chars": %CharsPage, "newchar": %NewCharPage,
		"worlds": %WorldsPage, "newworld": %NewWorldPage}
	_name_edit = %NameEdit
	_world_name_edit = %WorldNameEdit
	_seed_edit = %SeedEdit

	# Cartes de classes : couleurs/stats depuis Player.CLASSES, textes
	# descriptifs depuis ClassSelect.CARDS — données de jeu, donc remplies ici
	# plutôt que dupliquées dans la scène.
	for card in ClassSelect.CARDS:
		%CardRow.add_child(_class_card(card))

	_show_page("home")

# Toutes les pages existent dans la scène : naviguer = montrer l'une, cacher
# les autres. Les pages à listes se re-remplissent à chaque affichage.
func _show_page(page: String) -> void:
	for key in _pages:
		_pages[key].visible = (key == page)
	match page:
		"chars":
			_refresh_chars()
		"worlds":
			_refresh_worlds()

# Vide une liste dynamique (détache tout de suite : pas de doublons le temps
# que queue_free s'exécute en fin de frame).
func _clear_list(box: Node) -> void:
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()

func _empty_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_color", Color(0.6, 0.62, 0.7))
	return l

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

# ---------- Listes dynamiques (remplies depuis user://profiles.cfg) ----------

func _refresh_chars() -> void:
	_clear_list(%CharList)
	var chars := MainMenu.list_characters()
	if chars.is_empty():
		%CharList.add_child(_empty_label("Aucun personnage pour l'instant — crée le premier !"))
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
		%CharList.add_child(row)

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

func _refresh_worlds() -> void:
	%WorldsTitle.text = "Choisis un monde — %s" % _selected_char.get("name", "?")
	_clear_list(%WorldList)
	var worlds := MainMenu.list_worlds()
	if worlds.is_empty():
		%WorldList.add_child(_empty_label("Aucun monde pour l'instant — génère le premier !"))
	for w in worlds:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var pick := Button.new()
		pick.text = "%s   (graine %d)" % [w.get("name", "?"), int(w.get("seed", 0))]
		pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pick.pressed.connect(func(): start_game.emit(_selected_char, w))
		row.add_child(pick)
		row.add_child(_delete_button(w["key"], "worlds"))
		%WorldList.add_child(row)

func _create_world_and_play() -> void:
	var world_name := _world_name_edit.text.strip_edges()
	if world_name.is_empty():
		world_name = "Nouveau monde"
	var w := MainMenu.create_world(world_name, _parse_seed(_seed_edit.text))
	start_game.emit(_selected_char, w)

# Graine : vide = aléatoire ; nombre = pris tel quel ; texte = hashé (déterministe).
func _parse_seed(text: String) -> int:
	text = text.strip_edges()
	if text.is_empty():
		randomize()
		return randi()
	if text.is_valid_int():
		return text.to_int()
	return text.hash()


func _on_play_btn_pressed() -> void:
	_show_page("chars")


func _on_options_btn_pressed() -> void:
	if options != null:
			options._set_open(true)


func _on_quit_btn_pressed() -> void:
	get_tree().quit()


func _on_new_char_btn_pressed() -> void:
	_show_page("newchar")


func _on_chars_back_btn_pressed() -> void:
	_show_page("home")


func _on_new_char_back_btn_pressed() -> void:
	_show_page("chars")


func _on_new_world_btn_pressed() -> void:
	_show_page("newworld")


func _on_worlds_back_btn_pressed() -> void:
	_show_page("chars")


func _on_new_world_back_btn_pressed() -> void:
	_show_page("worlds")


func _on_create_world_btn_pressed() -> void:
	_create_world_and_play()
