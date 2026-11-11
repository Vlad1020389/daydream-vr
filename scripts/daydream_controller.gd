extends Node
## Автозагрузка «Daydream»: связывает Android-плагин DaydreamBle (BLE) с игрой.
##
## Плагин сканирует эфир, подключается к контроллеру и присылает каждый
## 20-байтовый пакет как hex-строку (сигнал controller_packet). Здесь пакет
## разбирается DaydreamParser-ом, ориентация калибруется (долгое нажатие Home).

signal status_changed(text: String)
signal controller_connected
signal controller_disconnected
signal fired
signal released
signal app_pressed
signal recentered

const PLUGIN_NAME := "DaydreamBle"
const RECENTER_HOLD_MSEC := 600
const RESCAN_INTERVAL_SEC := 6.0
const STALE_MSEC := 800

var plugin: Object = null
var status := "Ожидание"
var connected := false
var packets_total := 0

## Откалиброванная ориентация контроллера (в системе координат VR-«комнаты»).
var orientation := Quaternion.IDENTITY
var touch := Vector2.ZERO
var touching := false
var click_down := false
var last_state: Dictionary = {}

var _raw := Quaternion.IDENTITY
var _offset := Quaternion.IDENTITY
var _last_msec := -100000
var _prev_click := false
var _prev_app := false
var _home_since := -1
var _rescan_timer := 0.0


func _ready() -> void:
	if Engine.has_singleton(PLUGIN_NAME):
		plugin = Engine.get_singleton(PLUGIN_NAME)
		plugin.connect("controller_packet", _on_packet_hex)
		plugin.connect("controller_status", _on_plugin_status)
		plugin.connect("controller_state", _on_plugin_state)
		_set_status("Плагин найден, запрашиваю разрешения Bluetooth…")
		plugin.requestPermissionsAndScan()
	else:
		_set_status("Плагин DaydreamBle не найден (запуск не на Android?)")


func _process(delta: float) -> void:
	# Если пакеты перестали приходить, считаем контроллер отключённым.
	if connected and Time.get_ticks_msec() - _last_msec > STALE_MSEC:
		_set_connected(false)

	if plugin != null and not connected:
		_rescan_timer += delta
		if _rescan_timer >= RESCAN_INTERVAL_SEC:
			_rescan_timer = 0.0
			plugin.startScan()

	# Долгое нажатие Home = перецентровка.
	if _home_since >= 0 and Time.get_ticks_msec() - _home_since >= RECENTER_HOLD_MSEC:
		_home_since = -1
		recenter()


func is_active() -> bool:
	return connected


## Направление «луча» контроллера в системе координат комнаты.
func pointer_direction() -> Vector3:
	return orientation * Vector3(0, 0, -1)


func recenter() -> void:
	var f := _raw * Vector3(0, 0, -1)
	var yaw := atan2(-f.x, -f.z)
	_offset = Quaternion(Vector3.UP, -yaw)
	orientation = _offset * _raw
	recentered.emit()


## Можно подать пакет вручную (для тестов без железа).
func feed_packet(bytes: PackedByteArray) -> void:
	var s := DaydreamParser.parse(bytes)
	if s.is_empty():
		return
	packets_total += 1
	_last_msec = Time.get_ticks_msec()
	if not connected:
		_set_connected(true)
		recenter_on_first = true
	last_state = s
	_raw = s["orientation"]
	if recenter_on_first:
		recenter_on_first = false
		recenter()
	orientation = _offset * _raw
	touch = s["touch"]
	touching = s["touching"]

	var click: bool = s["click"]
	if click and not _prev_click:
		fired.emit()
	elif not click and _prev_click:
		released.emit()
	_prev_click = click
	click_down = click

	var app: bool = s["app"]
	if app and not _prev_app:
		app_pressed.emit()
	_prev_app = app

	if s["home"]:
		if _home_since < 0:
			_home_since = Time.get_ticks_msec()
	else:
		_home_since = -1


var recenter_on_first := true


func _on_packet_hex(hex: String) -> void:
	feed_packet(hex.hex_decode())


func _on_plugin_status(text: String) -> void:
	_set_status(text)


func _on_plugin_state(gatt_connected: bool) -> void:
	# Само соединение GATT ещё не значит, что идут данные; ждём первый пакет.
	if not gatt_connected:
		_set_connected(false)


func _set_connected(value: bool) -> void:
	if connected == value:
		return
	connected = value
	if value:
		_set_status("Контроллер подключён")
		controller_connected.emit()
	else:
		click_down = false
		_prev_click = false
		_set_status("Контроллер отключён")
		controller_disconnected.emit()


func _set_status(text: String) -> void:
	status = text
	status_changed.emit(text)
