package dev.daydreamble

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot
import java.util.UUID

/**
 * Мост BLE между контроллером Google Daydream и Godot.
 *
 * Сигналы для GDScript:
 *   controller_packet(hex: String)  — 20 байт пакета в hex-виде
 *   controller_status(text: String) — человекочитаемый статус
 *   controller_state(connected: bool) — состояние GATT-соединения
 */
@SuppressLint("MissingPermission")
class DaydreamBlePlugin(godot: Godot) : GodotPlugin(godot) {

    companion object {
        private val SERVICE_UUID: UUID = UUID.fromString("0000fe55-0000-1000-8000-00805f9b34fb")
        private val DATA_CHAR_UUID: UUID = UUID.fromString("00000001-1000-1000-8000-00805f9b34fb")
        private val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        private const val REQ_PERMISSIONS = 7042
        private const val SCAN_TIMEOUT_MS = 15_000L
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var adapter: BluetoothAdapter? = null
    private var gatt: BluetoothGatt? = null
    private var scanning = false
    private var connecting = false

    override fun getPluginName(): String = "DaydreamBle"

    override fun getPluginSignals(): MutableSet<SignalInfo> = mutableSetOf(
        SignalInfo("controller_packet", String::class.java),
        SignalInfo("controller_status", String::class.java),
        SignalInfo("controller_state", Boolean::class.javaObjectType),
    )

    // ------------------------------------------------------------ API для Godot

    @UsedByGodot
    fun requestPermissionsAndScan() {
        val act = activity ?: return
        val missing = requiredPermissions().filter {
            act.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) {
            startScan()
        } else {
            status("Запрашиваю разрешения Bluetooth…")
            act.requestPermissions(missing.toTypedArray(), REQ_PERMISSIONS)
        }
    }

    @UsedByGodot
    fun startScan() {
        if (scanning || connecting || gatt != null) return
        val act = activity ?: return
        if (requiredPermissions().any { act.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }) {
            status("Нет разрешений Bluetooth")
            return
        }
        val mgr = act.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        adapter = mgr?.adapter
        val ad = adapter
        if (ad == null || !ad.isEnabled) {
            status("Bluetooth выключен — включите его")
            return
        }
        val scanner = ad.bluetoothLeScanner
        if (scanner == null) {
            status("BLE-сканер недоступен")
            return
        }
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        scanning = true
        status("Ищу контроллер Daydream… (нажмите Home на контроллере)")
        scanner.startScan(null, settings, scanCallback)
        mainHandler.postDelayed({ if (scanning) stopScan("Контроллер не найден") }, SCAN_TIMEOUT_MS)
    }

    @UsedByGodot
    fun stopScan() = stopScan(null)

    @UsedByGodot
    fun disconnectController() {
        gatt?.disconnect()
    }

    // ---------------------------------------------------------------- внутреннее

    private fun requiredPermissions(): List<String> =
        if (Build.VERSION.SDK_INT >= 31) {
            listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private fun status(text: String) = emitSignal("controller_status", text)

    private fun stopScan(message: String?) {
        if (scanning) {
            try {
                adapter?.bluetoothLeScanner?.stopScan(scanCallback)
            } catch (_: Exception) {
            }
            scanning = false
        }
        if (message != null) status(message)
    }

    override fun onMainRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray,
    ) {
        super.onMainRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ_PERMISSIONS) return
        if (grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }) {
            startScan()
        } else {
            status("Разрешения Bluetooth не выданы")
        }
    }

    private fun looksLikeDaydream(result: ScanResult): Boolean {
        val name = result.device.name ?: result.scanRecord?.deviceName ?: ""
        if (name.contains("daydream", ignoreCase = true)) return true
        val uuids = result.scanRecord?.serviceUuids
        return uuids?.any { it.uuid == SERVICE_UUID } == true
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            if (!scanning || connecting || !looksLikeDaydream(result)) return
            stopScan(null)
            connecting = true
            status("Найден контроллер, подключаюсь…")
            val act = activity ?: return
            gatt = result.device.connectGatt(act, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
        }

        override fun onScanFailed(errorCode: Int) {
            scanning = false
            status("Ошибка сканирования BLE: $errorCode")
        }
    }

    private fun cleanup() {
        try {
            gatt?.close()
        } catch (_: Exception) {
        }
        gatt = null
        connecting = false
        emitSignal("controller_state", false)
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, st: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                status("Соединение установлено, ищу сервисы…")
                mainHandler.post { g.discoverServices() }
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                status("Контроллер отключился")
                cleanup()
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, st: Int) {
            val service = g.getService(SERVICE_UUID)
            val ch = service?.getCharacteristic(DATA_CHAR_UUID)
            if (ch == null) {
                status("Не найден сервис данных Daydream (FE55)")
                g.disconnect()
                return
            }
            g.setCharacteristicNotification(ch, true)
            val cccd = ch.getDescriptor(CCCD_UUID)
            if (cccd == null) {
                status("Нет дескриптора уведомлений")
                g.disconnect()
                return
            }
            if (Build.VERSION.SDK_INT >= 33) {
                g.writeDescriptor(cccd, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
            } else {
                @Suppress("DEPRECATION")
                cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                @Suppress("DEPRECATION")
                g.writeDescriptor(cccd)
            }
        }

        override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, st: Int) {
            if (st == BluetoothGatt.GATT_SUCCESS) {
                status("Уведомления включены, жду данные…")
                emitSignal("controller_state", true)
            } else {
                status("Не удалось включить уведомления: $st")
            }
        }

        // API 33+
        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            ch: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            handlePacket(ch, value)
        }

        // API < 33
        @Deprecated("Deprecated in Java")
        override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic) {
            @Suppress("DEPRECATION")
            handlePacket(ch, ch.value ?: return)
        }
    }

    private fun handlePacket(ch: BluetoothGattCharacteristic, value: ByteArray) {
        if (ch.uuid != DATA_CHAR_UUID || value.size < 20) return
        val sb = StringBuilder(value.size * 2)
        for (b in value) sb.append(String.format("%02x", b))
        emitSignal("controller_packet", sb.toString())
    }

    override fun onMainDestroy() {
        stopScan(null)
        gatt?.disconnect()
        cleanup()
        super.onMainDestroy()
    }
}
