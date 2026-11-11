class_name DaydreamParser
extends RefCounted
## Разбор 20-байтового BLE-пакета контроллера Daydream.
##
## Сервис:         0000fe55-0000-1000-8000-00805f9b34fb
## Характеристика: 00000001-1000-1000-8000-00805f9b34fb (notify)
##
## Поля упакованы побитно, порядок big-endian. Ориентация передаётся как
## вектор «ось * угол» (длина вектора = угол поворота в радианах).

const PACKET_SIZE := 20

const ORI_SCALE := 2.0 * PI / 4095.0
const ACC_SCALE := 8.0 * 9.8 / 4095.0
const GYRO_SCALE := (2048.0 / 180.0 * PI) / 4095.0

const BTN_CLICK := 0x01
const BTN_HOME := 0x02
const BTN_APP := 0x04
const BTN_VOL_MINUS := 0x08
const BTN_VOL_PLUS := 0x10


## 13-битное знаковое число в дополнительном коде.
static func _s13(v: int) -> int:
	return v - 0x2000 if (v & 0x1000) != 0 else v


## Возвращает пустой Dictionary, если пакет некорректный.
static func parse(d: PackedByteArray) -> Dictionary:
	if d.size() < PACKET_SIZE:
		return {}

	var x_ori := _s13(((d[1] & 0x03) << 11) | (d[2] << 3) | ((d[3] & 0xE0) >> 5))
	var y_ori := _s13(((d[3] & 0x1F) << 8) | d[4])
	var z_ori := _s13((d[5] << 5) | ((d[6] & 0xF8) >> 3))

	var x_acc := _s13(((d[6] & 0x07) << 10) | (d[7] << 2) | ((d[8] & 0xC0) >> 6))
	var y_acc := _s13(((d[8] & 0x3F) << 7) | ((d[9] & 0xFE) >> 1))
	var z_acc := _s13(((d[9] & 0x01) << 12) | (d[10] << 4) | ((d[11] & 0xF0) >> 4))

	var x_gyro := _s13(((d[11] & 0x0F) << 9) | (d[12] << 1) | ((d[13] & 0x80) >> 7))
	var y_gyro := _s13(((d[13] & 0x7F) << 6) | ((d[14] & 0xFC) >> 2))
	var z_gyro := _s13(((d[14] & 0x03) << 11) | (d[15] << 3) | ((d[16] & 0xE0) >> 5))

	var x_touch := ((d[16] & 0x1F) << 3) | ((d[17] & 0xE0) >> 5)
	var y_touch := ((d[17] & 0x1F) << 3) | ((d[18] & 0xE0) >> 5)

	var buttons := d[18]

	var ori_vec := Vector3(x_ori, y_ori, z_ori) * ORI_SCALE
	var angle := ori_vec.length()
	var quat := Quaternion.IDENTITY
	if angle > 0.0001:
		quat = Quaternion(ori_vec / angle, angle)

	return {
		"timestamp": ((d[0] << 1) | (d[1] >> 7)),
		"seq": (d[1] & 0x7C) >> 2,
		"orientation": quat,
		"accel": Vector3(x_acc, y_acc, z_acc) * ACC_SCALE,
		"gyro": Vector3(x_gyro, y_gyro, z_gyro) * GYRO_SCALE,
		"touch": Vector2(x_touch, y_touch) / 255.0,
		"touching": x_touch != 0 or y_touch != 0,
		"click": (buttons & BTN_CLICK) != 0,
		"home": (buttons & BTN_HOME) != 0,
		"app": (buttons & BTN_APP) != 0,
		"vol_minus": (buttons & BTN_VOL_MINUS) != 0,
		"vol_plus": (buttons & BTN_VOL_PLUS) != 0,
	}
