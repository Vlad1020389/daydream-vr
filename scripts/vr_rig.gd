class_name VRRig
extends Node3D
## «Голова» игрока для мобильного VR (Cardboard-подобного).
## Два SubViewport (левый и правый глаз) выводятся в две половины экрана
## с бочкообразной коррекцией под линзы. Ориентация берётся из HeadTracker.

@export var ipd := 0.064
@export var fov := 85.0
@export var render_scale := 0.8
@export var stereo_enabled := true
@export var lens_k1 := 0.20
@export var lens_k2 := 0.08

## Всё, что должно висеть «на лице» (HUD), добавляется сюда.
var hud_anchor: Node3D
var head_tracker: Node
var head_xf := Transform3D.IDENTITY

var _views: Array = []
var _ui_root: Control


func _ready() -> void:
	head_tracker = preload("res://scripts/head_tracker.gd").new()
	add_child(head_tracker)

	hud_anchor = Node3D.new()
	hud_anchor.name = "HudAnchor"
	add_child(hud_anchor)

	var layer := CanvasLayer.new()
	add_child(layer)
	_ui_root = Control.new()
	_ui_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_ui_root)

	var lens := preload("res://shaders/lens.gdshader")
	for i in 2:
		var vp := SubViewport.new()
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		vp.handle_input_locally = false
		add_child(vp)

		var cam := Camera3D.new()
		cam.fov = fov
		cam.keep_aspect = Camera3D.KEEP_HEIGHT
		cam.near = 0.05
		cam.far = 200.0
		vp.add_child(cam)

		var rect := TextureRect.new()
		rect.texture = vp.get_texture()
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_SCALE
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var mat := ShaderMaterial.new()
		mat.shader = lens
		rect.material = mat
		_ui_root.add_child(rect)

		_views.append({"vp": vp, "cam": cam, "rect": rect, "mat": mat})

	get_viewport().size_changed.connect(_layout)
	_layout()


func _layout() -> void:
	var screen := get_viewport().get_visible_rect().size
	for i in 2:
		var v: Dictionary = _views[i]
		var rect: TextureRect = v["rect"]
		var vp: SubViewport = v["vp"]
		var mat: ShaderMaterial = v["mat"]
		if stereo_enabled:
			var half := Vector2(screen.x * 0.5, screen.y)
			rect.visible = true
			rect.position = Vector2(half.x * i, 0.0)
			rect.size = half
			vp.size = Vector2i((half * render_scale).round())
			vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
			mat.set_shader_parameter("k1", lens_k1)
			mat.set_shader_parameter("k2", lens_k2)
		else:
			# Обычный (моно) режим — для отладки без очков.
			rect.visible = i == 0
			rect.position = Vector2.ZERO
			rect.size = screen
			vp.size = Vector2i((screen * render_scale).round())
			vp.render_target_update_mode = (
				SubViewport.UPDATE_ALWAYS if i == 0 else SubViewport.UPDATE_DISABLED
			)
			mat.set_shader_parameter("k1", 0.0)
			mat.set_shader_parameter("k2", 0.0)


func set_stereo(on: bool) -> void:
	stereo_enabled = on
	_layout()


func recenter() -> void:
	head_tracker.recenter()


func head_forward() -> Vector3:
	return head_xf.basis * Vector3(0, 0, -1)


func _process(_delta: float) -> void:
	var q: Quaternion = head_tracker.orientation
	head_xf = Transform3D(Basis(q), global_position)
	hud_anchor.global_transform = head_xf

	for i in 2:
		var cam: Camera3D = _views[i]["cam"]
		var eye := 0.0
		if stereo_enabled:
			eye = (float(i) - 0.5) * ipd
		cam.global_transform = head_xf * Transform3D(Basis(), Vector3(eye, 0.0, 0.0))


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_V:
		set_stereo(not stereo_enabled)
