extends Control

# Réticule assorti au monde cubique : un petit carré creux et son « pixel »
# central, cernés de sombre pour rester lisibles sur ciel comme sur neige.

func _draw() -> void:
	# Carré creux : liseré sombre dessous, trait blanc par-dessus.
	draw_rect(Rect2(-6, -6, 12, 12), Color(0.1, 0.1, 0.1, 0.6), false, 4.0)
	draw_rect(Rect2(-6, -6, 12, 12), Color.WHITE, false, 2.0)
	# Pixel central.
	draw_rect(Rect2(-2, -2, 4, 4), Color(0.1, 0.1, 0.1, 0.6))
	draw_rect(Rect2(-1, -1, 2, 2), Color.WHITE)
