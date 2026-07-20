class_name InventoryUI
extends CanvasLayer

# Panneau d'inventaire + équipement, ouvert/fermé avec la touche I.
# N'interrompt pas le jeu : la souris est simplement libérée le temps de
# manipuler les objets (le clic n'attaque pas quand la souris est visible).
# Le squelette (panneau, titres, zone de défilement) vit dans
# Scènes/UI/inventory_ui.tscn ; les lignes d'objets/équipement, dépendantes de
# l'état du joueur, sont (re)construites ici à chaque _refresh. Règle de mise
# en page : le panneau est positionné par les size flags de la scène
# (SHRINK_END / SHRINK_CENTER), jamais par des ancres figées — sa taille
# change avec le contenu.

const SLOT_ORDER := ["weapon", "armor", "amulet"]

var player: Player # à définir AVANT add_child

var is_open := false
var _panel: PanelContainer
var _equip_box: VBoxContainer
var _items_box: VBoxContainer

func _ready() -> void:
	# layer 5 et process_mode ALWAYS : réglés dans la scène.
	_panel = %Panel
	_equip_box = %EquipBox
	_items_box = %ItemsBox
	player.inventory_changed.connect(_refresh)
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
	if event.is_action_pressed("Invetory") and not get_tree().paused:
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
