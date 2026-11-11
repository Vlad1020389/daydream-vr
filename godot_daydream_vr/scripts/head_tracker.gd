extends Node
## Отслеживание головы по датчикам телефона (гироскоп + акселерометр).
## Интеграция гироскопа и комплементарная коррекция наклона по гравитации.
## Рысканье (yaw) со временем дрейфует — лечится перецентровкой (recenter()).
## На ПК (без датчиков) голова крутится мышью при зажатой правой кнопке.

var orientation := Quaternion.IDENTITY  # откалиброванная ориентация головы

const TILT_GAIN := 0.03
const MOUSE_SENS := 0.004

## Если картинка «ездит» в обратную сторону при повороте головы — поменяйте знак.
const GYRO_SIGN := Vector3(1, 1, 1)

var _q := Quaternion.IDENTITY
var _offset := Quaternion.IDENTITY
var _accel_sign := 1.0
var _accel_sign_checked := false
var _initialized := false
var _mouse_yaw := 0.0
var _mouse_pitch := 0.0
var _has_sensors := false


func _ready() -> void:
	_has_sensors = OS.has_feature("mobile")


func _process(delta: float) -> void:
	if not _has_sensors:
		_q = Quaternion.from_euler(Vector3(_mouse_pitch, _mouse_yaw, 0.0))
		orientation = _offset * _q
		return

	var accel := Input.get_accelerometer()
	if not _accel_sign_checked and accel.length() > 8.0:
		# Телефон в очках лежит «вертикально»: ось Y экрана смотрит вверх,
		# значит в покое ускорение по Y должно быть положительным.
		if absf(accel.y) > 6.0:
			_accel_sign = 1.0 if accel.y > 0.0 else -1.0
			_accel_sign_checked = true
	accel *= _accel_sign

	if not _initialized:
		if accel.length() > 8.0:
			_q = Quaternion(accel.normalized(), Vector3.UP)
			_initialized = true
			recenter()
		return

	# 1) Интегрируем угловую скорость (в системе координат телефона).
	var w := Input.get_gyroscope() * GYRO_SIGN
	var speed := w.length()
	if speed > 0.0001:
		_q = (_q * Quaternion(w / speed, speed * delta)).normalized()

	# 2) Подтягиваем наклон к измеренной гравитации.
	var g := accel.length()
	if g > 8.0 and g < 11.5:
		var measured_up := accel / g
		var predicted_up := _q.inverse() * Vector3.UP
		var axis := measured_up.cross(predicted_up)
		var s := axis.length()
		if s > 0.0001:
			var angle := asin(clampf(s, 0.0, 1.0))
			_q = (_q * Quaternion(axis / s, angle * TILT_GAIN)).normalized()

	orientation = _offset * _q


func recenter() -> void:
	var f := _q * Vector3(0, 0, -1)
	var yaw := atan2(-f.x, -f.z)
	_offset = Quaternion(Vector3.UP, -yaw)
	orientation = _offset * _q


func _unhandled_input(event: InputEvent) -> void:
	if _has_sensors:
		return
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_mouse_yaw -= event.relative.x * MOUSE_SENS
		_mouse_pitch = clampf(_mouse_pitch - event.relative.y * MOUSE_SENS, -1.4, 1.4)
