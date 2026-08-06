extends CanvasLayer
# Terminal en jeu : T pour ouvrir, Échap pour fermer, Entrée pour soumettre,
# flèches haut/bas pour l'historique. La commande saisie est émise via le
# signal `command` ; l'appelant (main.gd) répond avec println(). Quand le
# terminal est ouvert la souris est libérée, donc la caméra libre s'ignore
# d'elle-même (elle ne bouge qu'en mode capturé).

signal command(text : String)

var _log : RichTextLabel
var _line : LineEdit
var _history : PackedStringArray = []
var _hist_pos : int = -1

func _ready() -> void:
	layer = 10
	visible = false

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	panel.custom_minimum_size = Vector2(0, 260)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.07, 0.10, 0.82)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)

	var vbox := VBoxContainer.new()
	panel.add_child(vbox)

	_log = RichTextLabel.new()
	_log.scroll_following = true
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.focus_mode = Control.FOCUS_NONE
	vbox.add_child(_log)

	_line = LineEdit.new()
	_line.placeholder_text = "commande (« help » pour la liste)"
	_line.text_submitted.connect(_on_submit)
	_line.gui_input.connect(_on_line_input)
	vbox.add_child(_line)

	println("Terminal — « help » pour la liste des commandes.")

func _input(event : InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if not visible and event.keycode == KEY_T:
			open()
		elif visible and event.keycode == KEY_ESCAPE:
			close()

func open() -> void:
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# focus différé : la frappe de T qui ouvre ne doit pas s'insérer
	_line.call_deferred("grab_focus")
	_line.call_deferred("clear")

func close() -> void:
	visible = false
	_line.release_focus()

func println(text : String) -> void:
	_log.add_text(text + "\n")

func _on_submit(text : String) -> void:
	text = text.strip_edges()
	if text.is_empty():
		return
	println("> " + text)
	_history.append(text)
	_hist_pos = -1
	_line.clear()
	command.emit(text)

# Historique : flèche haut = plus ancien, bas = plus récent puis champ vide.
func _on_line_input(event : InputEvent) -> void:
	if not (event is InputEventKey and event.pressed):
		return
	if event.keycode == KEY_UP and not _history.is_empty():
		_hist_pos = mini(_hist_pos + 1, _history.size() - 1)
		_line.text = _history[_history.size() - 1 - _hist_pos]
		_line.caret_column = _line.text.length()
		_line.accept_event()
	elif event.keycode == KEY_DOWN and _hist_pos >= 0:
		_hist_pos -= 1
		_line.text = "" if _hist_pos < 0 else _history[_history.size() - 1 - _hist_pos]
		_line.caret_column = _line.text.length()
		_line.accept_event()
