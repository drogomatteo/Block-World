class_name SkyPreset
extends Resource
# Préréglage du ciel — équivalent des presets .ron de bevy_sky_gradient
# (valeurs par défaut = sky_presets/default.ron du plugin). Le dégradé
# vertical a 4 stops ; chaque stop a une couleur par moment de la journée,
# que sky_cycle.gd étale sur la timeline du cycle et interpole en continu.

# Positions verticales des 4 stops (0 = nadir, 0.5 = horizon, 1 = zénith)
@export var stop_positions := Vector4(0.38, 0.47, 0.61, 1.0)

@export_group("Stop 0 — sous l'horizon")
@export var stop0_sunrise := Color8(255, 70, 70)
@export var stop0_day_low := Color8(157, 157, 248)
@export var stop0_day_high := Color8(48, 48, 255)
@export var stop0_sunset := Color8(255, 70, 70)
@export var stop0_night_low := Color8(0, 3, 40)
@export var stop0_night_high := Color8(0, 0, 45)

@export_group("Stop 1 — horizon")
@export var stop1_sunrise := Color8(243, 84, 47)
@export var stop1_day_low := Color8(205, 242, 255)
@export var stop1_day_high := Color8(0, 226, 255)
@export var stop1_sunset := Color8(243, 84, 47)
@export var stop1_night_low := Color8(47, 0, 93)
@export var stop1_night_high := Color8(0, 32, 93)

@export_group("Stop 2 — au-dessus de l'horizon")
@export var stop2_sunrise := Color8(255, 242, 72)
@export var stop2_day_low := Color8(182, 200, 254)
@export var stop2_day_high := Color8(0, 170, 255)
@export var stop2_sunset := Color8(255, 242, 72)
@export var stop2_night_low := Color8(0, 38, 97)
@export var stop2_night_high := Color8(0, 0, 112)

@export_group("Stop 3 — zénith")
@export var stop3_sunrise := Color8(73, 177, 250)
@export var stop3_day_low := Color8(224, 224, 255)
@export var stop3_day_high := Color8(66, 195, 255)
@export var stop3_sunset := Color8(73, 177, 250)
@export var stop3_night_low := Color8(74, 0, 89)
@export var stop3_night_high := Color8(0, 0, 43)

@export_group("Soleil")
@export var sun_color := Color(1.0, 1.0, 0.5)
@export var sun_strength := 1.5
@export var sun_sharpness := 364.0

@export_group("Étoiles")
@export var stars_rotation_speed := 0.01
@export var stars_sample_scale := 9.0
@export var stars_threshold := 0.9
@export var stars_threshold_blink := 0.01
@export var stars_blink_speed := 10.0
@export var stars_mask_scale := 1.0
@export var stars_mask_threshold := 0.4
@export var stars_blink_variance_scale := 0.03

@export_group("Aurore")
@export var aurora_bottom_color := Color(0.0, 1.0, 0.2)
@export var aurora_top_color := Color(0.0, 1.0, 0.8)
@export var aurora_alpha := 0.7
@export var aurora_density := 0.05
@export var aurora_sharpness := 1.56
@export var aurora_samples := 60
@export var aurora_start_height := 3.1
@export var aurora_end_height := 4.8
@export var aurora_flow_scale := 0.002
@export var aurora_flow_strength := 4.3
@export var aurora_flow_speed := 0.005
@export var aurora_flow_x_speed := -0.6
@export var aurora_wiggle_scale := 0.03
@export var aurora_wiggle_strength := 1.05
@export var aurora_wiggle_speed := 0.1
# les composantes > 1 sont volontaires (couleurs HDR, comme dans le plugin)
@export var aurora_sparkle_primary := Color(0.0, 2.3, 0.0)
@export var aurora_sparkle_secondary := Color(6.3, 0.2, 4.0)
@export var aurora_sparkle_scale := 0.004
@export var aurora_sparkle_speed := 0.02
@export var aurora_sparkle_threshold := 0.3
@export var aurora_sparkle_max_height := 0.3
@export var aurora_opacity_per_sample := 0.18


# Couleurs du stop dans l'ordre de la timeline du cycle :
# [aube, jour bas, jour haut (midi), crépuscule, début/fin de nuit, nuit profonde]
func stop_timeline_colors(stop: int) -> Array:
	match stop:
		0: return [stop0_sunrise, stop0_day_low, stop0_day_high, stop0_sunset, stop0_night_low, stop0_night_high]
		1: return [stop1_sunrise, stop1_day_low, stop1_day_high, stop1_sunset, stop1_night_low, stop1_night_high]
		2: return [stop2_sunrise, stop2_day_low, stop2_day_high, stop2_sunset, stop2_night_low, stop2_night_high]
		_: return [stop3_sunrise, stop3_day_low, stop3_day_high, stop3_sunset, stop3_night_low, stop3_night_high]


# Uniforms du sky.gdshader qui ne changent pas au fil de la journée.
func static_shader_params() -> Dictionary:
	return {
		"stop_positions": stop_positions,
		"sun_color": sun_color,
		"sun_strength": sun_strength,
		"sun_sharpness": sun_sharpness,
		"stars_rotation_speed": stars_rotation_speed,
		"stars_sample_scale": stars_sample_scale,
		"stars_threshold": stars_threshold,
		"stars_threshold_blink": stars_threshold_blink,
		"stars_blink_speed": stars_blink_speed,
		"stars_mask_scale": stars_mask_scale,
		"stars_mask_threshold": stars_mask_threshold,
		"stars_blink_variance_scale": stars_blink_variance_scale,
		"aurora_bottom_color": aurora_bottom_color,
		"aurora_top_color": aurora_top_color,
		"aurora_alpha": aurora_alpha,
		"aurora_density": aurora_density,
		"aurora_sharpness": aurora_sharpness,
		"aurora_samples": aurora_samples,
		"aurora_start_height": aurora_start_height,
		"aurora_end_height": aurora_end_height,
		"aurora_flow_scale": aurora_flow_scale,
		"aurora_flow_strength": aurora_flow_strength,
		"aurora_flow_speed": aurora_flow_speed,
		"aurora_flow_x_speed": aurora_flow_x_speed,
		"aurora_wiggle_scale": aurora_wiggle_scale,
		"aurora_wiggle_strength": aurora_wiggle_strength,
		"aurora_wiggle_speed": aurora_wiggle_speed,
		"aurora_sparkle_primary": aurora_sparkle_primary,
		"aurora_sparkle_secondary": aurora_sparkle_secondary,
		"aurora_sparkle_scale": aurora_sparkle_scale,
		"aurora_sparkle_speed": aurora_sparkle_speed,
		"aurora_sparkle_threshold": aurora_sparkle_threshold,
		"aurora_sparkle_max_height": aurora_sparkle_max_height,
		"aurora_opacity_per_sample": aurora_opacity_per_sample,
	}
