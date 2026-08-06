class_name SkyCycle
extends Node
# Cycle jour/nuit — port des drivers de bevy_sky_gradient (cycle.rs,
# gradient.rs, sun.rs). Avance l'heure, interpole les 4 stops du dégradé du
# ciel sur la timeline aube -> jour -> crépuscule -> nuit, fait tourner le
# soleil (DirectionalLight3D, dont le sky.gdshader tire la position du
# disque), pilote la visibilité nocturne (étoiles + aurores) et garde en
# phase la couleur du brouillard (frontière de génération invisible) et la
# lumière du terrain (global sky_terrain_light : les chunks sont unshaded).
#
# F4 : accélère le temps (x20) pour observer le cycle.

const SkyPresetScript = preload("res://Scripts/sky_preset.gd")

@export var preset : Resource  # SkyPreset ; null = preset par défaut du plugin
@export var sun : DirectionalLight3D
@export var world_environment : WorldEnvironment

@export_group("Durées (secondes)")
@export var day_time_sec := 120.0
@export var night_time_sec := 90.0
@export var sunrise_time_sec := 12.0  # pris sur le jour
@export var sunset_time_sec := 12.0   # pris sur la nuit

@export_group("Réglages")
@export var auto_tick := true
@export var time_scale := 1.0
@export var fast_forward_scale := 20.0  # bascule F4
# Heure de départ, en fraction du cycle : 0 = aube, 0.25 = midi,
# 0.5 = crépuscule, 0.75 = minuit (aurores).
@export_range(0.0, 1.0) var start_percent := 0.15
# night_time_distance (0 -> 1 au coeur de la nuit) remappé en visibilité des
# étoiles/aurores — mêmes bornes que le plugin (0.0, 0.1).
@export var night_visibility_range := Vector2(0.0, 0.1)
@export var sun_max_energy := 1.3

@export_group("Lumière du terrain")
# Les chunks étant unshaded, la nuit est appliquée en multipliant leur albédo
# par le global sky_terrain_light (voir chunk_common.gdshaderinc).
@export var terrain_day := Color(1.0, 1.0, 1.0)
@export var terrain_night := Color(0.13, 0.16, 0.28)
@export var terrain_horizon := Color(1.0, 0.82, 0.62)  # teinte chaude aube/crépuscule

@export_group("Activations")
@export var sun_disc_enabled := true
@export var stars_enabled := true
@export var aurora_enabled := true

var time := 0.0

var _mat : ShaderMaterial
var _timelines : Array = []   # 4 timelines [[offset, Color], ...] sur 0..1
var _stop_colors : Array = [Color.WHITE, Color.WHITE, Color.WHITE, Color.WHITE]
var _fast := false

func _ready() -> void:
	if preset == null:
		preset = SkyPresetScript.new()
	_mat = world_environment.environment.sky.sky_material
	for i in 4:
		_timelines.append(_build_timeline(preset.stop_timeline_colors(i)))
	var params : Dictionary = preset.static_shader_params()
	for key in params:
		_mat.set_shader_parameter(key, params[key])
	_mat.set_shader_parameter("sun_enabled", sun_disc_enabled)
	_mat.set_shader_parameter("stars_enabled", stars_enabled)
	_mat.set_shader_parameter("aurora_enabled", aurora_enabled)
	time = _time_from_percent(start_percent)
	_apply_time()

func _process(delta: float) -> void:
	if auto_tick:
		var scale := time_scale * (fast_forward_scale if _fast else 1.0)
		time = fposmod(time + delta * scale, day_time_sec + night_time_sec)
	_apply_time()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_F4:
		_fast = not _fast

# Timeline d'un stop (gradient.rs) : l'aube et le crépuscule sont ancrés aux
# transitions jour/nuit, les couleurs « hautes » culminent à midi / minuit.
func _build_timeline(colors: Array) -> Array:
	var sunrise_end := sunrise_time_sec / day_time_sec * 0.5
	var sunset_start := 0.5 - sunset_time_sec / day_time_sec * 0.5
	var sunset_end := 0.5 + sunset_time_sec / night_time_sec * 0.5
	var sunrise_start := 1.0 - sunrise_time_sec / night_time_sec * 0.5
	return [
		[0.0, colors[0]],                                  # aube
		[sunrise_end, colors[1]],                          # jour bas
		[(sunrise_end + sunset_start) * 0.5, colors[2]],   # midi
		[sunset_start, colors[1]],                         # jour bas
		[0.5, colors[3]],                                  # crépuscule
		[sunset_end, colors[4]],                           # début de nuit
		[(sunset_end + sunrise_start) * 0.5, colors[5]],   # minuit
		[sunrise_start, colors[4]],                        # fin de nuit
		[1.0, colors[0]],                                  # aube
	]

func _sample_timeline(timeline: Array, t: float) -> Color:
	if t <= timeline[0][0]:
		return timeline[0][1]
	for i in range(1, timeline.size()):
		if t <= timeline[i][0]:
			var span : float = maxf(timeline[i][0] - timeline[i - 1][0], 0.000001)
			var f : float = clampf((t - timeline[i - 1][0]) / span, 0.0, 1.0)
			return (timeline[i - 1][1] as Color).lerp(timeline[i][1], f)
	return timeline[-1][1]

# fraction du cycle (0 aube, 0.5 crépuscule) -> secondes
func _time_from_percent(p: float) -> float:
	p = clampf(p, 0.0, 1.0)
	if p <= 0.5:
		return p * 2.0 * day_time_sec
	return day_time_sec + (p - 0.5) * 2.0 * night_time_sec

func _apply_time() -> void:
	var day_p := clampf(time / day_time_sec, 0.0, 1.0)
	var night_p := maxf((time - day_time_sec) / night_time_sec, 0.0)
	var percent := (day_p + night_p) * 0.5

	# couleurs du dégradé
	for i in 4:
		_stop_colors[i] = _sample_timeline(_timelines[i], percent)
		_mat.set_shader_parameter("stop%d_color" % i, _stop_colors[i])

	# visibilité des étoiles / aurores (night_time_distance de cycle.rs)
	var night_dist := 1.0 - absf(night_p - 0.5) * 2.0 if night_p > 0.0 else 0.0
	var night_vis := smoothstep(night_visibility_range.x, night_visibility_range.y, night_dist)
	_mat.set_shader_parameter("night_visibility", night_vis)

	# soleil : demi-tour au-dessus de l'horizon le jour, en dessous la nuit
	var theta := day_p * PI + night_p * PI
	if sun != null:
		sun.rotation = Vector3(theta + PI, 0.0, 0.0)
		sun.light_energy = pow(maxf(sin(theta), 0.0), 2.0) * sun_max_energy

	# brouillard raccordé à la couleur de l'horizon (les chunks lointains ne
	# doivent pas se découper sur le ciel, quelle que soit l'heure)
	world_environment.environment.fog_light_color = _gradient_at(0.5)

	# lumière du terrain : jour/nuit + bande chaude quand le soleil rase
	var elev := sin(theta)
	var day_f := smoothstep(-0.08, 0.25, elev)
	var terrain := terrain_night.lerp(terrain_day, day_f)
	var warm := (1.0 - smoothstep(0.0, 0.35, absf(elev))) * day_f
	terrain *= Color.WHITE.lerp(terrain_horizon, warm)
	RenderingServer.global_shader_parameter_set(
		"sky_terrain_light", Vector3(terrain.r, terrain.g, terrain.b))

# Couleur du ciel à la hauteur t (0.5 = horizon) — même interpolation par
# morceaux que sky_gradient() dans sky.gdshader.
func _gradient_at(t: float) -> Color:
	var pos : Vector4 = preset.stop_positions
	var col : Color = _stop_colors[0]
	for i in 3:
		var span : float = maxf(pos[i + 1] - pos[i], 0.0001)
		col = col.lerp(_stop_colors[i + 1], clampf((t - pos[i]) / span, 0.0, 1.0))
	return col
