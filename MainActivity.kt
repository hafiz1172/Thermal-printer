package com.example.print_bridge

import android.Manifest
import android.app.PendingIntent
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Bundle
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

class MainActivity : FlutterActivity() {
    private val channelName = "com.example.print_bridge/printer"
    private val actionUsbPermission = "com.example.print_bridge.USB_PERMISSION"
    private var methodChannel: MethodChannel? = null
    private var pendingIncomingText: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingIncomingText = extractTextFromIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val text = extractTextFromIntent(intent)
        if (!text.isNullOrEmpty()) {
            methodChannel?.invokeMethod("onReceiveText", text)
        }
    }

    private fun extractTextFromIntent(intent: Intent?): String? {
        if (intent == null) return null
        if (intent.action == Intent.ACTION_SEND && intent.type == "text/plain") {
            return intent.getStringExtra(Intent.EXTRA_TEXT)
        }
        if (intent.action == Intent.ACTION_VIEW) {
            return intent.data?.getQueryParameter("text")
        }
        return null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)

        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialText" -> {
                    val text = pendingIncomingText
                    pendingIncomingText = null
                    result.success(text)
                }

                "getUsbDevices" -> {
                    val usbManager = getSystemService(Context.USB_SERVICE) as UsbManager
                    val list = usbManager.deviceList.values.map { device ->
                        mapOf(
                            "deviceName" to device.deviceName,
                            "productName" to (device.productName ?: "USB Thermal Printer (${device.vendorId})"),
                            "vendorId" to device.vendorId.toString(),
                            "productId" to device.productId.toString()
                        )
                    }
                    result.success(list)
                }

                "printUsb" -> {
                    val deviceName = call.argument("deviceName") as? String
                    val bytes = call.argument("bytes") as? ByteArray
                    if (deviceName == null || bytes == null) {
                        result.error("INVALID_ARGS", "USB device ya data missing hai", null)
                        return@setMethodCallHandler
                    }
                    printViaUsb(deviceName, bytes, result)
                }

                "getBluetoothDevices" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                        ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT)
                        != PackageManager.PERMISSION_GRANTED
                    ) {
                        ActivityCompat.requestPermissions(
                            this,
                            arrayOf(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_SCAN),
                            101
                        )
                        result.success(ArrayList<Any>())
                        return@setMethodCallHandler
                    }

                    val btManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
                    val adapter = btManager.adapter
                    val devices = adapter?.bondedDevices?.map { device ->
                        mapOf(
                            "name" to (device.name ?: "Bluetooth Printer"),
                            "address" to device.address
                        )
                    } ?: ArrayList<Any>()
                    result.success(devices)
                }

                "printBluetooth" -> {
                    val address = call.argument("address") as? String
                    val bytes = call.argument("bytes") as? ByteArray
                    if (address == null || bytes == null) {
                        result.error("INVALID_ARGS", "Bluetooth address ya data missing hai", null)
                        return@setMethodCallHandler
                    }
                    printViaBluetooth(address, bytes, result)
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun printViaUsb(deviceName: String, bytes: ByteArray, result: MethodChannel.Result) {
        val usbManager = getSystemService(Context.USB_SERVICE) as UsbManager
        val device: UsbDevice? = usbManager.deviceList[deviceName]
        if (device == null) {
            result.error("NOT_FOUND", "USB printer connected nahi hai", null)
            return
        }

        if (!usbManager.hasPermission(device)) {
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
            val permissionIntent = PendingIntent.getBroadcast(this, 0, Intent(actionUsbPermission), flags)
            usbManager.requestPermission(device, permissionIntent)
            result.error("PERMISSION_NEEDED", "Screen par USB permission Allow karein aur dobara Print dabayein", null)
            return
        }

        Thread {
            try {
                var targetInterface: UsbInterface? = null
                var outEndpoint: UsbEndpoint? = null

                for (i in 0 until device.interfaceCount) {
                    val intf = device.getInterface(i)
                    for (j in 0 until intf.endpointCount) {
                        val ep = intf.getEndpoint(j)
                        if (ep.type == UsbConstants.USB_ENDPOINT_XFER_BULK &&
                            ep.direction == UsbConstants.USB_DIR_OUT
                        ) {
                            targetInterface = intf
                            outEndpoint = ep
                            break
                        }
                    }
                    if (outEndpoint != null) break
                }

                if (targetInterface == null || outEndpoint == null) {
                    runOnUiThread {
                        result.error("NO_ENDPOINT", "Printer ka data endpoint nahi mila", null)
                    }
                    return@Thread
                }

                val connection = usbManager.openDevice(device)
                if (connection == null) {
                    runOnUiThread {
                        result.error("OPEN_FAILED", "USB connection open nahi ho saka", null)
                    }
                    return@Thread
                }

                connection.claimInterface(targetInterface, true)
                val chunkSize = 4096
                var offset = 0
                while (offset < bytes.size) {
                    val length = minOf(chunkSize, bytes.size - offset)
                    val chunk = bytes.copyOfRange(offset, offset + length)
                    connection.bulkTransfer(outEndpoint, chunk, chunk.size, 5000)
                    offset += length
                }
                connection.releaseInterface(targetInterface)
                connection.close()

                runOnUiThread { result.success(true) }
            } catch (e: Exception) {
                runOnUiThread { result.error("USB_ERROR", e.message, null) }
            }
        }.start()
    }

    private fun printViaBluetooth(address: String, bytes: ByteArray, result: MethodChannel.Result) {
        Thread {
            try {
                val btManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
                val adapter = btManager.adapter
                val device = adapter.getRemoteDevice(address)
                val uuid = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
                val socket = device.createRfcommSocketToServiceRecord(uuid)
                adapter.cancelDiscovery()
                socket.connect()
                val outStream = socket.outputStream
                outStream.write(bytes)
                outStream.flush()
                Thread.sleep(250)
                outStream.close()
                socket.close()
                runOnUiThread { result.success(true) }
            } catch (e: Exception) {
                runOnUiThread { result.error("BT_ERROR", e.message, null) }
            }
        }.start()
    }
}
