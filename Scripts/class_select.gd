class_name ClassSelect
extends CanvasLayer

# Écran de choix de classe affiché au lancement, avant la création du joueur.
# Les stats/couleurs viennent de Player.CLASSES (une seule source de vérité) ;
# seuls les textes descriptifs sont définis ici.

signal class_chosen(class_id: String)

const CARDS := [
	{"id": "warrior",
		"desc": "Combat rapproché à l'épée. Très robuste.",
		"special": "Spécial : Tourbillon — frappe tous les ennemis autour de toi."},
	{"id": "ranger",
		"desc": "Arc : attaques à distance rapides et précises.",
		"special": "Spécial : Salve — décoche 5 flèches en éventail."},
	{"id": "mage",
		"desc": "Boules de feu puissantes, mais lent et fragile.",
		"special": "Spécial : Nova — explosion de feu autour de toi."},
	{"id": "rogue",
		"desc": "Dagues très rapides, déplacement agile.",
		"special": "Spécial : Ruée — fonce en avant en blessant tout sur ton passage."},
]

func _ready() -> void:
	layer = 20
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_build()

func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.05, 0.07, 0.12, 0.85)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.add_child(center)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 24)
	center.add_child(box)

	var title := Label.new()
	title.text = "Choisis ta classe"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 40)
	box.add_child(title)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	box.add_child(row)

	for card in CARDS:
		row.add_child(_make_card(card))

func _make_card(card: Dictionary) -> Control:
	var id: String = card["id"]
	var cls: Dictionary = Player.CLASSES[id]

	var panel := PanelContainer.new()
	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(210, 0)
	v.add_theme_constant_override("separation", 10)
	panel.add_child(v)

	var swatch_wrap := CenterContainer.new()
	var swatch := ColorRect.new()
	swatch.color = cls["color"]
	swatch.custom_minimum_size = Vector2(56, 56)
	swatch_wrap.add_child(swatch)
	v.add_child(swatch_wrap)

	var name_lbl := Label.new()
	name_lbl.text = cls["name"]
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 24)
	v.add_child(name_lbl)

	var stats := Label.new()
	stats.text = "PV %d   Dégâts %d" % [cls["health"], cls["damage"]]
	stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(stats)

	var desc := Label.new()
	desc.text = card["desc"] + "\n\n" + card["special"]
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(190, 120)
	v.add_child(desc)

	var btn := Button.new()
	btn.text = "Choisir"
	btn.pressed.connect(func(): _choose(id))
	v.add_child(btn)

	return panel

func _choose(id: String) -> void:
	class_chosen.emit(id)
	queue_free()
