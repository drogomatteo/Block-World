extends Control

func _draw() -> void:
	#Cercle
	draw_circle(Vector2.ZERO, 4, Color.DIM_GRAY)
	draw_circle(Vector2.ZERO, 3, Color.WHITE)
	
	#Ligne droite
	draw_line(Vector2(16,0), Vector2(24,0), Color.WHITE, 2)
	#Ligne gauche
	draw_line(Vector2(-16,0), Vector2(-24,0), Color.WHITE, 2)
	#Ligne du haut
	draw_line(Vector2(0,-16), Vector2(0,-24), Color.WHITE, 2)
	#Ligne du bas
	draw_line(Vector2(0,16), Vector2(0,24), Color.WHITE, 2)
