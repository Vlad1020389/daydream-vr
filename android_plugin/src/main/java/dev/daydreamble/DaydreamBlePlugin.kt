package dev.daydreamble

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot
import java.util.UUID
import java.util.concurrent.ConcurrentLinkedQueue

class DaydreamBlePlugin(godot: Godot) : GodotPlugin(godot) {

    companion object {
        private const val TAG = "DaydreamBlePro"
        private const val REQ_PERMISSIONS = 4012

        val SERVICE_UUID: UUID = UUID.fromString("0000fe55-0000-1000-8000-00805f9b34fb")
        val DATA_CHAR_UUID: UUID = UUID.fromString("00000001-1000-1000-8000-00805f9b34fb")
        val CONTROL_CHAR_UUID: UUID = UUID.fromString("00000002-1000-1000-8000-00805f9b34fb")
        val BATTERY_CHAR_UUID: UUID = UUID.fromString("00000003-1000-1000-8000-00805f9b34fb")
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    private var bluetoothManager: BluetoothManager? = null
    private var bluetoothAdapter: BluetoothAdapter? = null
    private var scanner: BluetoothLeScanner? = null
    private var gatt: BluetoothGatt? = null

    @Volatile private var scanning = false
    @Volatile private var connecting = false
    @Volatile private var connected = false
    @Volatile private var lastPacket = ByteArray(0)
    @Volatile private var statusText = "Ожидание запуска..."
    @Volatile private var batteryLevel = -1

    private val mainHandler = Handler(Looper.getMainLooper())
    private val gattQueue = ConcurrentLinkedQueue<Runnable>()
    @Volatile private var isExecutingGattOp = false

    private val scanRestartRunnable = Runnable {
        if (!connected && !connecting) {
            Log.i(TAG, "Перезапуск цикла BLE-сканирования...")
            stop_scan()
            mainHandler.postDelayed({ start_scan() }, 300)
        }
    }

    override fun getPluginName(): String = "DaydreamBle"

    override fun getPluginSignals(): Set<SignalInfo> = setOf(
        SignalInfo("status_changed", String::class.java),
        SignalInfo("connection_changed", Boolean::class.javaObjectType),
        SignalInfo("packet_received", ByteArray::class.java)
    )

    override fun onMainCreate(activity: Activity?): android.view.View? {
        initBluetooth(activity)
        return null
    }

    private fun initBluetooth(act: Activity?) {
        if (act == null) return
        if (bluetoothManager == null) {
            bluetoothManager = act.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        }
        bluetoothAdapter = bluetoothManager?.adapter
        scanner = bluetoothAdapter?.bluetoothLeScanner
    }

    private fun setStatus(text: String) {
        statusText = text
        Log.i(TAG, text)
        mainHandler.post {
            emitSignal("status_changed", text)
        }
    }

    private fun setConnected(value: Boolean) {
        if (connected == value) return
        connected = value
        mainHandler.post {
            emitSignal("connection_changed", value)
        }
    }

    private fun hasPermissions(): Boolean {
        val act = activity ?: return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            act.checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED &&
            act.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
        } else {
            act.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun requestPermissionsIfNeeded() {
        val act = activity ?: return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val perms = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT,
                Manifest.permission.ACCESS_FINE_LOCATION
            )
        } else {
            arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION
            )
        }
        act.requestPermissions(perms, REQ_PERMISSIONS)
    }

    @UsedByGodot
    fun is_connected(): Boolean = connected

    @UsedByGodot
    fun is_scanning(): Boolean = scanning

    @UsedByGodot
    fun get_status(): String = statusText

    @UsedByGodot
    fun get_last_packet(): ByteArray = lastPacket

    @UsedByGodot
    fun get_battery(): Int = batteryLevel

    @SuppressLint("MissingPermission")
    @UsedByGodot
    fun start_scan() {
        val act = activity ?: return
        initBluetooth(act)

        if (bluetoothAdapter == null) {
            setStatus("Ошибка: Bluetooth не найден")
            return
        }

        if (!hasPermissions()) {
            setStatus("Разрешите доступ к Bluetooth и Геолокации!")
            requestPermissionsIfNeeded()
            mainHandler.postDelayed({ start_scan() }, 2000)
            return
        }

        if (bluetoothAdapter?.isEnabled != true) {
            setStatus("Включите Bluetooth в шторке телефона!")
            mainHandler.postDelayed({ start_scan() }, 2500)
            return
        }

        if (connected) {
            setStatus("Пульт Daydream подключен!")
            return
        }

        if (connecting) return

        try {
            val connectedDevices = bluetoothManager?.getConnectedDevices(BluetoothProfile.GATT) ?: emptyList()
            for (dev in connectedDevices) {
                if (isLikelyDaydream(dev.name, null)) {
                    setStatus("Найден активный пульт: ${dev.name ?: dev.address}")
                    connectToDevice(dev)
                    return
                }
            }

            val bondedDevices = bluetoothAdapter?.bondedDevices ?: emptySet()
            for (dev in bondedDevices) {
                if (isLikelyDaydream(dev.name, null)) {
                    setStatus("Подключение к известному пульту: ${dev.name ?: dev.address}")
                    connectToDevice(dev)
                    return
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Ошибка проверки кэша устройств: ${e.message}")
        }

        if (scanning) return

        scanner = bluetoothAdapter?.bluetoothLeScanner
        if (scanner == null) {
            setStatus("Ошибка: BLE-сканер занят или недоступен")
            return
        }

        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        try {
            scanner?.startScan(null, settings, scanCallback)
            scanning = true
            setStatus("Поиск пульта... Нажмите любую кнопку на пульте")
            mainHandler.removeCallbacks(scanRestartRunnable)
            mainHandler.postDelayed(scanRestartRunnable, 12000)
        } catch (e: Exception) {
            scanning = false
            setStatus("Сбой запуска поиска: ${e.message}")
        }
    }

    @SuppressLint("MissingPermission")
    @UsedByGodot
    fun stop_scan() {
        mainHandler.removeCallbacks(scanRestartRunnable)
        if (!scanning) return
        try {
            scanner?.stopScan(scanCallback)
        } catch (_: Exception) {}
        scanning = false
    }

    @SuppressLint("MissingPermission")
    @UsedByGodot
    fun disconnect() {
        stop_scan()
        connecting = false
        gattQueue.clear()
        isExecutingGattOp = false
        try {
            gatt?.disconnect()
            gatt?.close()
        } catch (_: Exception) {}
        gatt = null
        setConnected(false)
        setStatus("Отключено")
    }

    private fun isLikelyDaydream(name: String?, record: ScanRecord?): Boolean {
        val devName = name ?: ""
        val recName = record?.deviceName ?: ""
        val combined = "$devName $recName".lowercase()

        if (combined.contains("daydream") || combined.contains("g010") || combined.contains("g011")) {
            return true
        }

        val uuids = record?.serviceUuids ?: emptyList()
        for (parcelUuid in uuids) {
            val u = parcelUuid.uuid.toString().lowercase()
            if (parcelUuid.uuid == SERVICE_UUID || u.startsWith("0000fe55") || u.contains("fe55")) {
                return true
            }
        }

        val serviceData = record?.serviceData
        if (serviceData != null) {
            for (key in serviceData.keys) {
                val u = key.uuid.toString().lowercase()
                if (u.startsWith("0000fe55") || u.contains("fe55")) {
                    return true
                }
            }
        }
        return false
    }

    private val scanCallback = object : ScanCallback() {
        @SuppressLint("MissingPermission")
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            if (connected || connecting) return
            val device = result.device ?: return
            val devName = try { device.name } catch (_: Exception) { null }

            if (isLikelyDaydream(devName, result.scanRecord)) {
                val label = result.scanRecord?.deviceName ?: devName ?: device.address
                setStatus("Найден пульт ($label)! Соединение...")
                stop_scan()
                connectToDevice(device)
            }
        }

        override fun onScanFailed(errorCode: Int) {
            scanning = false
            setStatus("Ошибка BLE ($errorCode). Включите GPS/Местоположение!")
            mainHandler.postDelayed({ start_scan() }, 3000)
        }
    }

    @SuppressLint("MissingPermission")
    private fun connectToDevice(device: BluetoothDevice) {
        if (connecting || connected) return
        connecting = true
        gattQueue.clear()
        isExecutingGattOp = false

        try {
            gatt?.close()
        } catch (_: Exception) {}

        mainHandler.post {
            gatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                device.connectGatt(activity, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
            } else {
                device.connectGatt(activity, false, gattCallback)
            }
        }
    }

    private fun enqueueGattOp(op: Runnable) {
        gattQueue.add(op)
        processNextGattOp()
    }

    private fun processNextGattOp() {
        if (isExecutingGattOp) return
        val next = gattQueue.poll() ?: return
        isExecutingGattOp = true
        mainHandler.post(next)
    }

    private fun completeGattOp() {
        isExecutingGattOp = false
        processNextGattOp()
    }

    private val gattCallback = object : BluetoothGattCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                connecting = false
                setStatus("Подключено! Настройка датчиков...")
                mainHandler.postDelayed({
                    try {
                        g.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH)
                        g.discoverServices()
                    } catch (e: Exception) {
                        setStatus("Ошибка опроса сервисов: ${e.message}")
                    }
                }, 300)
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                connecting = false
                setConnected(false)
                gattQueue.clear()
                isExecutingGattOp = false
                setStatus("Связь потеряна. Переподключение...")
                try { g.close() } catch (_: Exception) {}
                gatt = null
                mainHandler.postDelayed({ start_scan() }, 1200)
            }
        }

        @SuppressLint("MissingPermission")
        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                setStatus("Ошибка сервисов ($status). Повтор...")
                disconnect()
                mainHandler.postDelayed({ start_scan() }, 1000)
                return
            }

            val service = g.getService(SERVICE_UUID)
            if (service == null) {
                setStatus("Это не пульт Daydream (нет сервиса FE55)")
                disconnect()
                return
            }

            val dataChar = service.getCharacteristic(DATA_CHAR_UUID)
            if (dataChar == null) {
                setStatus("Не найдена характеристика данных пульта")
                disconnect()
                return
            }

            enqueueGattOp(Runnable {
                g.setCharacteristicNotification(dataChar, true)
                val descriptor = dataChar.getDescriptor(CCCD_UUID)
                if (descriptor != null) {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        g.writeDescriptor(descriptor, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                    } else {
                        @Suppress("DEPRECATION")
                        descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                        @Suppress("DEPRECATION")
                        g.writeDescriptor(descriptor)
                    }
                } else {
                    completeGattOp()
                }
            })

            val controlChar = service.getCharacteristic(CONTROL_CHAR_UUID)
            if (controlChar != null) {
                enqueueGattOp(Runnable {
                    val wakeCmd = byteArrayOf(0x01)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        g.writeCharacteristic(controlChar, wakeCmd, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
                    } else {
                        @Suppress("DEPRECATION")
                        controlChar.value = wakeCmd
                        @Suppress("DEPRECATION")
                        g.writeCharacteristic(controlChar)
                    }
                })
            }

            val batteryChar = service.getCharacteristic(BATTERY_CHAR_UUID)
            if (batteryChar != null) {
                enqueueGattOp(Runnable {
                    g.readCharacteristic(batteryChar)
                })
            }

            setConnected(true)
            setStatus("Контроллер Daydream готов к игре!")
        }

        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            completeGattOp()
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            completeGattOp()
        }

        @Deprecated("Deprecated in Java")
        override fun onCharacteristicRead(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            if (characteristic.uuid == BATTERY_CHAR_UUID && status == BluetoothGatt.GATT_SUCCESS) {
                @Suppress("DEPRECATION")
                val v = characteristic.value
                if (v != null && v.isNotEmpty()) {
                    batteryLevel = v[0].toInt() and 0xFF
                    setStatus("Daydream подключен! Заряд: $batteryLevel%")
                }
            }
            completeGattOp()
        }

        override fun onCharacteristicRead(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int
        ) {
            if (characteristic.uuid == BATTERY_CHAR_UUID && status == BluetoothGatt.GATT_SUCCESS && value.isNotEmpty()) {
                batteryLevel = value[0].toInt() and 0xFF
                setStatus("Daydream подключен! Заряд: $batteryLevel%")
            }
            completeGattOp()
        }

        @Deprecated("Deprecated in Java")
        override fun onCharacteristicChanged(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (characteristic.uuid == DATA_CHAR_UUID) {
                @Suppress("DEPRECATION")
                val data = characteristic.value ?: return
                lastPacket = data
                emitSignal("packet_received", data)
            }
        }

        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray
        ) {
            if (characteristic.uuid == DATA_CHAR_UUID) {
                lastPacket = value
                emitSignal("packet_received", value)
            }
        }
    }
}
