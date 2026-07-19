class_name InventoryUI
extends CanvasLayer

# Panneau d'inventaire + équipement, ouvert/fermé avec la touche I.
# N'interrompt pas le jeu : la souris est simplement libérée le temps de
# manipuler les objets (le clic n'attaque pas quand la souris est visible).

const SLOT_ORDER := ["weapon", "armor", "amulet"]

var player: Player # à définir AVANT add_child

var is_open := false
var _panel: PanelContainer
var _equip_box: VBoxContainer
var _items_box: VBoxContainer

func _ready() -> void:
	layer = 5
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	player.inventory_changed.connect(_refresh)
	_panel.visible = false

func _build() -> void:
	# Conteneur plein écran + size flags : le panneau reste collé au bord droit
	# et centré verticalement QUELLE QUE SOIT sa taille (elle change quand des
	# objets s'ajoutent — un ancrage figé calculé à la création déborderait).
	var root := MarginContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE # ne bloque pas les clics du jeu
	root.add_theme_constant_override("margin_left", 16)
	root.add_theme_constant_override("margin_top", 16)
	root.add_theme_constant_override("margin_right", 16)
	root.add_theme_constant_override("margin_bottom", 16)
	add_child(root)

	_panel = PanelContainer.new()
	_panel.size_flags_horizontal = Control.SIZE_SHRINK_END
	_panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	root.add_child(_panel)

	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(380, 0)
	v.add_theme_constant_override("separation", 10)
	_panel.add_child(v)

	var title := Label.new()
	title.text = "Équipement"
	title.add_theme_font_size_override("font_size", 22)
	v.add_child(title)

	_equip_box = VBoxContainer.new()
	v.add_child(_equip_box)

	v.add_child(HSeparator.new())

	var title2 := Label.new()
	title2.text = "Inventaire  (I pour fermer)"
	title2.add_theme_font_size_override("font_size", 22)
	v.add_child(title2)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(380, 300)
	v.add_child(scroll)

	_items_box = VBoxContainer.new()
	_items_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_items_box)

	_refresh()

# Reconstruit tout le contenu (simple et suffisant à cette échelle).
func _refresh() -> void:
	for child in _equip_box.get_children():
		child.queue_free()
	for child in _items_box.get_children():
		child.queue_free()

	for slot in SLOT_ORDER:
		_equip_box.add_child(_make_slot_row(slot))

	if player.inventory.is_empty():
		var empty := Label.new()
		empty.text = "Vide — les ennemis lâchent parfois de l'équipement."
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
		_items_box.add_child(empty)
	for i in player.inventory.size():
		_items_box.add_child(_make_item_row(i))

func _make_slot_row(slot: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var slot_lbl := Label.new()
	slot_lbl.text = Items.SLOT_NAMES[slot]
	slot_lbl.custom_minimum_size = Vector2(80, 0)
	row.add_child(slot_lbl)

	var item = player.equipment[slot]
	var name_lbl := Label.new()
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if item != null:
		name_lbl.text = item["name"]
		name_lbl.add_theme_color_override("font_color", Items.RARITY_COLORS[item["rarity"]])
		name_lbl.tooltip_text = Items.describe(item)
	else:
		name_lbl.text = "—"
		name_lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	row.add_child(name_lbl)

	if item != null:
		var btn := Button.new()
		btn.text = "Retirer"
		btn.pressed.connect(func(): player.unequip(slot))
		row.add_child(btn)
	return row

func _make_item_row(index: int) -> Control:
	var item: Dictionary = player.inventory[index]
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var name_lbl := Label.new()
	name_lbl.text = item["name"]
	name_lbl.add_theme_color_override("font_color", Items.RARITY_COLORS[item["rarity"]])
	text.add_child(name_lbl)
	var desc := Label.new()
	desc.text = Items.describe(item)
	desc.add_theme_color_override("font_color", Color(0.72, 0.72, 0.78))
	desc.add_theme_font_size_override("font_size", 13)
	text.add_child(desc)
	row.add_child(text)

	var equip_btn := Button.new()
	equip_btn.text = "Équiper"
	equip_btn.pressed.connect(func(): player.equip_from_inventory(index))
	row.add_child(equip_btn)

	var drop_btn := Button.new()
	drop_btn.text = "✕"
	drop_btn.tooltip_text = "Détruire l'objet"
	drop_btn.pressed.connect(func(): player.discard_item(index))
	row.add_child(drop_btn)
	return row

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("inventory") and not get_tree().paused:
		toggle()
		get_viewport().set_input_as_handled()

func toggle() -> void:
	is_open = not is_open
	_panel.visible = is_open
	if is_open:
		_refresh()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _process(_delta: float) -> void:
	# Si le menu Options (Échap) s'ouvre par-dessus, on referme l'inventaire ;
	# c'est lui qui gérera la souris à sa fermeture.
	if is_open and get_tree().paused:
		is_open = false
		_panel.visible = false
