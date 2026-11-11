extends Node3D
## VR-тир: сбивайте шары лучом контроллера Daydream (или взглядом, если
## контроллера нет). Курок/клик по тачпаду — выстрел, долгое Home — центровка,
## кнопка App — перезапуск раунда.

class Target:
	var node: MeshInstance3D
	var radius: float
	var born: float


const ROUND_TIME := 60.0
const MAX_TARGETS := 6
const SPAWN_EVERY := 1.0
const TARGET_LIFETIME := 5.0
const EYE_HEIGHT := 1.6
const HAND_POS := Vector3(0.28, 1.15, -0.35)
const LASER_MAX := 12.0

var rig: VRRig
var hand: Node3D
var hand_body: MeshInstance3D
var touch_dot: MeshInstance3D
var laser: MeshInstance3D
var reticle: MeshInstance3D
var score_label: Label3D
var status_label: Label3D
var center_label: Label3D

var targets: Array[Target] = []
var score := 0
var shots := 0
var hits := 0
var time_left := ROUND_TIME
var running := true

var _rng := RandomNumberGenerator.new()
var _clock := 0.0
var _spawn_timer := 0.5
var _status_show_left := 10.0
var _aim_origin := Vector3.ZERO
var _aim_dir := Vector3(0, 0, -1)
var _aim_hit_target: Target = null
var _aim_distance := LASER_MAX

var _mat_laser_idle := _make_mat(Color(1.0, 0.2, 0.2), false, true)
var _mat_laser_hit := _make_mat(Color(0.2, 1.0, 0.3), false, true)


func _ready() -> void:
	_rng.randomize()
	_build_environment()
	_build_rig()
	_build_hand()
	_build_hud()

	Daydream.fired.connect(_on_fire)
	Daydream.app_pressed.connect(restart)
	Daydream.recentered.connect(rig.recenter)
	Daydream.status_changed.connect(func(_t: String) -> void: _status_show_left = 6.0)


# ---------------------------------------------------------------- построение

func _make_mat(color: Color, emissive := false, unshaded := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	if emissive:
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = 1.5
	if unshaded:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m


func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.05, 0.08, 0.2)
	sky_mat.sky_horizon_color = Color(0.25, 0.3, 0.5)
	sky_mat.ground_horizon_color = Color(0.25, 0.3, 0.5)
	sky_mat.ground_bottom_color = Color(0.05, 0.06, 0.1)
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.8
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.light_energy = 0.9
	add_child(sun)

	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(80, 80)
	floor_mesh.mesh = plane
	floor_mesh.material_override = _make_mat(Color(0.1, 0.12, 0.16))
	add_child(floor_mesh)

	# Кольца на полу и колонны — ориентиры глубины.
	for radius in [3.0, 6.0, 9.0, 12.0]:
		var ring := MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = radius - 0.05
		torus.outer_radius = radius + 0.05
		ring.mesh = torus
		ring.scale = Vector3(1, 0.1, 1)
		ring.position.y = 0.01
		ring.material_override = _make_mat(Color(0.1, 0.8, 1.0), true)
		add_child(ring)

	for i in 16:
		var a := TAU * i / 16.0
		var pillar := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.25
		cyl.bottom_radius = 0.25
		cyl.height = 6.0
		pillar.mesh = cyl
		pillar.position = Vector3(sin(a) * 15.0, 3.0, -cos(a) * 15.0)
		pillar.material_override = _make_mat(Color.from_hsv(float(i) / 16.0, 0.6, 0.7), true)
		add_child(pillar)


func _build_rig() -> void:
	rig = VRRig.new()
	rig.name = "VRRig"
	rig.position = Vector3(0, EYE_HEIGHT, 0)
	add_child(rig)


func _build_hand() -> void:
	hand = Node3D.new()
	hand.name = "Hand"
	add_child(hand)

	hand_body = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.04, 0.012, 0.15)
	hand_body.mesh = box
	hand_body.material_override = _make_mat(Color(0.85, 0.85, 0.9))
	hand.add_child(hand_body)

	touch_dot = MeshInstance3D.new()
	var dot := SphereMesh.new()
	dot.radius = 0.006
	dot.height = 0.012
	touch_dot.mesh = dot
	touch_dot.material_override = _make_mat(Color(0.2, 0.6, 1.0), true, true)
	touch_dot.visible = false
	hand.add_child(touch_dot)

	laser = MeshInstance3D.new()
	var lbox := BoxMesh.new()
	lbox.size = Vector3(0.004, 0.004, 1.0)
	laser.mesh = lbox
	laser.material_override = _mat_laser_idle
	hand.add_child(laser)

	reticle = MeshInstance3D.new()
	var rs := SphereMesh.new()
	rs.radius = 0.5
	rs.height = 1.0
	reticle.mesh = rs
	var rm := _make_mat(Color(1.0, 1.0, 1.0), false, true)
	rm.no_depth_test = true
	reticle.material_override = rm
	add_child(reticle)


func _make_label(size_px: int, pixel_size: float, pos: Vector3) -> Label3D:
	var l := Label3D.new()
	l.font_size = size_px
	l.pixel_size = pixel_size
	l.outline_size = 12
	l.no_depth_test = true
	l.render_priority = 10
	l.outline_render_priority = 9
	l.position = pos
	rig.hud_anchor.add_child(l)
	return l


func _build_hud() -> void:
	score_label = _make_label(48, 0.004, Vector3(0, 0.62, -1.8))
	status_label = _make_label(32, 0.0035, Vector3(0, -0.72, -1.8))
	center_label = _make_label(56, 0.004, Vector3(0, 0.1, -2.0))
	center_label.visible = false


# --------------------------------------------------------------- игровой цикл

func _process(delta: float) -> void:
	_clock += delta
	_update_hand()
	_compute_aim()
	_update_aim_visuals()
	_update_status_label(delta)

	if running:
		time_left -= delta
		if time_left <= 0.0:
			_end_round()
		else:
			_spawn_timer -= delta
			if _spawn_timer <= 0.0 and targets.size() < MAX_TARGETS:
				_spawn_target()
				_spawn_timer = SPAWN_EVERY
			for t in targets.duplicate():
				if _clock - t.born > TARGET_LIFETIME:
					_remove_target(t)
	_update_score_label()


func _update_hand() -> void:
	var active: bool = Daydream.is_active()
	hand.visible = active
	if not active:
		return
	hand.global_transform = Transform3D(Basis(Daydream.orientation), HAND_POS)
	var s := Daydream.touch
	touch_dot.visible = Daydream.touching
	touch_dot.position = Vector3((s.x - 0.5) * 0.03, 0.008, -0.05 + (s.y - 0.5) * 0.05)
	(hand_body.material_override as StandardMaterial3D).albedo_color = (
		Color(1.0, 0.8, 0.2) if Daydream.click_down else Color(0.85, 0.85, 0.9)
	)


func _compute_aim() -> void:
	if Daydream.is_active():
		_aim_origin = HAND_POS
		_aim_dir = Daydream.pointer_direction().normalized()
	else:
		_aim_origin = rig.global_position
		_aim_dir = rig.head_forward().normalized()

	_aim_hit_target = null
	_aim_distance = LASER_MAX
	for t in targets:
		var d := _ray_sphere(_aim_origin, _aim_dir, t.node.global_position, t.radius)
		if d >= 0.0 and d < _aim_distance:
			_aim_distance = d
			_aim_hit_target = t


func _update_aim_visuals() -> void:
	var active: bool = Daydream.is_active()
	laser.visible = active
	if active:
		var tip := 0.075
		laser.position = Vector3(0, 0, -tip - _aim_distance * 0.5)
		laser.scale = Vector3(1, 1, _aim_distance)
		laser.material_override = _mat_laser_hit if _aim_hit_target != null else _mat_laser_idle
	var shown_dist := _aim_distance if _aim_hit_target != null else minf(_aim_distance, 8.0)
	reticle.global_position = _aim_origin + _aim_dir * shown_dist
	reticle.scale = Vector3.ONE * (0.012 * shown_dist)


func _ray_sphere(origin: Vector3, dir: Vector3, center: Vector3, radius: float) -> float:
	var oc := origin - center
	var b := oc.dot(dir)
	var c := oc.dot(oc) - radius * radius
	var disc := b * b - c
	if disc < 0.0:
		return -1.0
	var root := sqrt(disc)
	var t := -b - root
	if t < 0.0:
		t = -b + root
	return t


# -------------------------------------------------------------------- мишени

func _spawn_target() -> void:
	var angle := deg_to_rad(_rng.randf_range(-110.0, 110.0))
	var dist := _rng.randf_range(5.0, 9.0)
	var height := _rng.randf_range(0.6, 3.6)
	var t := Target.new()
	t.radius = _rng.randf_range(0.3, 0.5)
	t.born = _clock

	var m := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = t.radius
	sphere.height = t.radius * 2.0
	m.mesh = sphere
	m.material_override = _make_mat(Color.from_hsv(_rng.randf(), 0.85, 1.0), true)
	m.position = Vector3(sin(angle) * dist, height, -cos(angle) * dist)
	m.scale = Vector3.ONE * 0.01
	add_child(m)
	create_tween().tween_property(m, "scale", Vector3.ONE, 0.2)

	t.node = m
	targets.append(t)


func _remove_target(t: Target) -> void:
	targets.erase(t)
	var tw := create_tween()
	tw.tween_property(t.node, "scale", Vector3.ONE * 0.01, 0.15)
	tw.tween_callback(t.node.queue_free)


func _on_fire() -> void:
	if not running:
		restart()
		return
	shots += 1
	_compute_aim()
	if _aim_hit_target == null:
		return
	var t := _aim_hit_target
	var points := 10 + (5 if _clock - t.born < 2.0 else 0)
	score += points
	hits += 1
	_spawn_popup(t.node.global_position, "+%d" % points)
	_remove_target(t)


func _spawn_popup(pos: Vector3, text: String) -> void:
	var l := Label3D.new()
	l.text = text
	l.font_size = 64
	l.pixel_size = 0.006
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.modulate = Color(1, 1, 0.4)
	l.position = pos
	add_child(l)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(l, "position:y", pos.y + 0.8, 0.6)
	tw.tween_property(l, "modulate:a", 0.0, 0.6)
	tw.chain().tween_callback(l.queue_free)


func _end_round() -> void:
	running = false
	for t in targets.duplicate():
		_remove_target(t)
	var acc := 0.0
	if shots > 0:
		acc = 100.0 * hits / shots
	center_label.text = "Раунд окончен\nОчки: %d\nТочность: %.0f%%\n\nКурок — ещё раз" % [score, acc]
	center_label.visible = true


func restart() -> void:
	for t in targets.duplicate():
		_remove_target(t)
	score = 0
	shots = 0
	hits = 0
	time_left = ROUND_TIME
	_spawn_timer = 0.5
	running = true
	center_label.visible = false


# ----------------------------------------------------------------------- HUD

func _update_score_label() -> void:
	score_label.text = "Очки: %d     Время: %d" % [score, maxi(0, ceili(time_left))]


func _update_status_label(delta: float) -> void:
	_status_show_left = maxf(0.0, _status_show_left - delta)
	var active: bool = Daydream.is_active()
	var show_it := (not active) or _status_show_left > 0.0
	status_label.visible = show_it
	if not show_it:
		return
	var txt: String = "%s\nпакетов: %d" % [Daydream.status, Daydream.packets_total]
	if not active:
		txt += "\nБез контроллера: целься головой, тап по экрану — выстрел"
	else:
		txt += "\nHome (удерживать) — центровка, App — рестарт"
	status_label.text = txt


# ---------------------------------------------------------- запасной «выстрел»

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch and event.pressed:
		if not Daydream.is_active():
			_on_fire()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		# На телефоне касание уже обработано как ScreenTouch.
		if not OS.has_feature("mobile") and not Daydream.is_active():
			_on_fire()
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE:
			_on_fire()
		elif event.keycode == KEY_R:
			rig.recenter()
