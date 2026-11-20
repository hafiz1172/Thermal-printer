import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const PrintBridgeApp());
}

class PrintBridgeApp extends StatelessWidget {
  const PrintBridgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Print Bridge',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.teal,
        useMaterial3: true,
      ),
      home: const PrinterHomeScreen(),
    );
  }
}

class PrinterHomeScreen extends StatefulWidget {
  const PrinterHomeScreen({super.key});

  @override
  State<PrinterHomeScreen> createState() => _PrinterHomeScreenState();
}

class _PrinterHomeScreenState extends State<PrinterHomeScreen> {
  static const MethodChannel _channel =
      MethodChannel('com.example.print_bridge/printer');

  final TextEditingController _ipController =
      TextEditingController(text: '192.168.1.100');
  final TextEditingController _portController =
      TextEditingController(text: '9100');
  final TextEditingController _textController = TextEditingController();

  String _connectionType = 'wifi';
  String _cutMode = 'full';
  int _feedLines = 4;
  bool _autoPrintOnReceive = true;
  bool _isPrinting = false;

  List _usbDevices = [];
  String? _selectedUsbDevice;

  List _btDevices = [];
  String? _selectedBtAddress;

  String _statusMessage = 'Ready to print';

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _setupIncomingListener();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _connectionType = prefs.getString('connectionType') ?? 'wifi';
      _ipController.text = prefs.getString('wifiIp') ?? '192.168.1.100';
      _portController.text = prefs.getString('wifiPort') ?? '9100';
      _cutMode = prefs.getString('cutMode') ?? 'full';
      _feedLines = prefs.getInt('feedLines') ?? 4;
      _autoPrintOnReceive = prefs.getBool('autoPrintOnReceive') ?? true;
      _selectedUsbDevice = prefs.getString('selectedUsbDevice');
      _selectedBtAddress = prefs.getString('selectedBtAddress');
    });

    if (_connectionType == 'usb') await _refreshUsbDevices();
    if (_connectionType == 'bluetooth') await _refreshBtDevices();

    final initialText = await _channel.invokeMethod('getInitialText');
    if (initialText is String && initialText.isNotEmpty) {
      _handleIncomingText(initialText);
    }
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('connectionType', _connectionType);
    await prefs.setString('wifiIp', _ipController.text.trim());
    await prefs.setString('wifiPort', _portController.text.trim());
    await prefs.setString('cutMode', _cutMode);
    await prefs.setInt('feedLines', _feedLines);
    await prefs.setBool('autoPrintOnReceive', _autoPrintOnReceive);
    if (_selectedUsbDevice != null) {
      await prefs.setString('selectedUsbDevice', _selectedUsbDevice!);
    }
    if (_selectedBtAddress != null) {
      await prefs.setString('selectedBtAddress', _selectedBtAddress!);
    }
  }

  void _setupIncomingListener() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onReceiveText') {
        final text = call.arguments;
        if (text is String && text.isNotEmpty) {
          _handleIncomingText(text);
        }
      }
    });
  }

  void _handleIncomingText(String text) {
    setState(() {
      _textController.text = text;
      _statusMessage = 'Text received from external app';
    });
    if (_autoPrintOnReceive) {
      _printText(text);
    }
  }

  Future<void> _refreshUsbDevices() async {
    try {
      final res = await _channel.invokeMethod('getUsbDevices');
      if (res is List) {
        setState(() {
          _usbDevices = res;
          if (_usbDevices.isNotEmpty &&
              !_usbDevices.any(
                  (d) => d['deviceName'].toString() == _selectedUsbDevice)) {
            _selectedUsbDevice = _usbDevices.first['deviceName'].toString();
          }
        });
      }
    } catch (e) {
      _showSnack('USB scan error: $e');
    }
  }

  Future<void> _refreshBtDevices() async {
    try {
      final res = await _channel.invokeMethod('getBluetoothDevices');
      if (res is List) {
        setState(() {
          _btDevices = res;
          if (_btDevices.isNotEmpty &&
              !_btDevices
                  .any((d) => d['address'].toString() == _selectedBtAddress)) {
            _selectedBtAddress = _btDevices.first['address'].toString();
          }
        });
      }
    } catch (e) {
      _showSnack('Bluetooth scan error: $e');
    }
  }

  Uint8List _buildEscPosPayload(String text) {
    final bytes = BytesBuilder();

    // 1. Initialize Printer (ESC @)
    bytes.add([0x1B, 0x40]);

    // 2. Receipt Text
    bytes.add(utf8.encode(text));
    if (!text.endsWith('\n')) {
      bytes.addByte(0x0A);
    }

    // 3. Feed empty lines before cut
    for (int i = 0; i < _feedLines; i++) {
      bytes.addByte(0x0A);
    }

    // 4. Auto Page Cut Command (GS V)
    if (_cutMode == 'full') {
      bytes.add([0x1D, 0x56, 0x00]);
    } else if (_cutMode == 'partial') {
      bytes.add([0x1D, 0x56, 0x01]);
    }

    return bytes.toBytes();
  }

  Future<void> _printText(String rawText) async {
    if (rawText.trim().isEmpty) {
      _showSnack('Print karne ke liye pehle text likhein ya bhejein.');
      return;
    }

    await _saveSettings();
    setState(() {
      _isPrinting = true;
      _statusMessage = 'Printing...';
    });

    final payload = _buildEscPosPayload(rawText);

    try {
      if (_connectionType == 'wifi') {
        final ip = _ipController.text.trim();
        final port = int.tryParse(_portController.text.trim()) ?? 9100;
        final socket = await Socket.connect(
          ip,
          port,
          timeout: const Duration(seconds: 5),
        );
        socket.add(payload);
        await socket.flush();
        await socket.close();
      } else if (_connectionType == 'usb') {
        if (_selectedUsbDevice == null) {
          throw Exception('Koi USB printer select nahi hai');
        }
        await _channel.invokeMethod('printUsb', {
          'deviceName': _selectedUsbDevice,
          'bytes': payload,
        });
      } else if (_connectionType == 'bluetooth') {
        if (_selectedBtAddress == null) {
          throw Exception('Koi Bluetooth printer select nahi hai');
        }
        await _channel.invokeMethod('printBluetooth', {
          'address': _selectedBtAddress,
          'bytes': payload,
        });
      }

      setState(() {
        _statusMessage = 'Printed & Cut (${_cutMode.toUpperCase()})!';
      });
      _showSnack('Print kamyab raha!');
    } on PlatformException catch (e) {
      setState(() => _statusMessage = 'Error: ${e.message}');
      _showSnack(e.message ?? 'Printer error');
    } catch (e) {
      setState(() => _statusMessage = 'Error: $e');
      _showSnack('Print failed: $e');
    } finally {
      setState(() => _isPrinting = false);
    }
  }

  void _printTestReceipt() {
    const testText = '================================\n'
        '       PRINT BRIDGE TEST        \n'
        '================================\n'
        'Connection : OK\n'
        'Auto-Cut   : Active\n'
        '--------------------------------\n'
        'Agar yeh page cut ho gaya hai,\n'
        'to settings bilkul theek hain.\n'
        '================================';
    _printText(testText);
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final usbItems = [
      for (final d in _usbDevices)
        DropdownMenuItem(
          value: d['deviceName'].toString(),
          child: Text((d['productName'] ?? 'USB Device').toString()),
        ),
    ];

    final validUsbValue = _usbDevices.any(
            (d) => d['deviceName'].toString() == _selectedUsbDevice)
        ? _selectedUsbDevice
        : null;

    final btItems = [
      for (final d in _btDevices)
        DropdownMenuItem(
          value: d['address'].toString(),
          child: Text((d['name'] ?? 'BT Printer').toString()),
        ),
    ];

    final validBtValue = _btDevices
            .any((d) => d['address'].toString() == _selectedBtAddress)
        ? _selectedBtAddress
        : null;

    const cutItems = [
      DropdownMenuItem(value: 'full', child: Text('Full Cut (GS V 0)')),
      DropdownMenuItem(value: 'partial', child: Text('Partial Cut (GS V 1)')),
      DropdownMenuItem(value: 'none', child: Text('Off (Do Not Cut)')),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Thermal Print Bridge'),
        actions: [
          TextButton.icon(
            onPressed: _isPrinting ? null : _printTestReceipt,
            icon: const Icon(Icons.receipt_long),
            label: const Text('Test Print'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '1. Printer Connection',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    const SizedBox(height: 10),
                    SegmentedButton(
                      segments: const [
                        ButtonSegment(
                            value: 'wifi',
                            label: Text('Wi-Fi'),
                            icon: Icon(Icons.wifi)),
                        ButtonSegment(
                            value: 'usb',
                            label: Text('USB OTG'),
                            icon: Icon(Icons.usb)),
                        ButtonSegment(
                            value: 'bluetooth',
                            label: Text('Bluetooth'),
                            icon: Icon(Icons.bluetooth)),
                      ],
                      selected: {_connectionType},
                      onSelectionChanged: (val) async {
                        setState(() => _connectionType = val.first);
                        await _saveSettings();
                        if (_connectionType == 'usb') _refreshUsbDevices();
                        if (_connectionType == 'bluetooth') {
                          _refreshBtDevices();
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    if (_connectionType == 'wifi') ...[
                      Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: TextField(
                              controller: _ipController,
                              decoration: const InputDecoration(
                                labelText: 'Printer IP Address',
                                hintText: '192.168.1.100',
                                border: OutlineInputBorder(),
                              ),
                              keyboardType: TextInputType.number,
                              onChanged: (_) => _saveSettings(),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 1,
                            child: TextField(
                              controller: _portController,
                              decoration: const InputDecoration(
                                labelText: 'Port',
                                border: OutlineInputBorder(),
                              ),
                              keyboardType: TextInputType.number,
                              onChanged: (_) => _saveSettings(),
                            ),
                          ),
                        ],
                      ),
                    ] else if (_connectionType == 'usb') ...[
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField(
                              value: validUsbValue,
                              decoration: const InputDecoration(
                                labelText: 'Select USB Printer',
                                border: OutlineInputBorder(),
                              ),
                              items: usbItems,
                              onChanged: (val) {
                                setState(
                                    () => _selectedUsbDevice = val as String?);
                                _saveSettings();
                              },
                            ),
                          ),
                          IconButton(
                            onPressed: _refreshUsbDevices,
                            icon: const Icon(Icons.refresh),
                            tooltip: 'Scan USB',
                          ),
                        ],
                      ),
                    ] else if (_connectionType == 'bluetooth') ...[
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField(
                              value: validBtValue,
                              decoration: const InputDecoration(
                                labelText: 'Select Paired Printer',
                                border: OutlineInputBorder(),
                              ),
                              items: btItems,
                              onChanged: (val) {
                                setState(
                                    () => _selectedBtAddress = val as String?);
                                _saveSettings();
                              },
                            ),
                          ),
                          IconButton(
                            onPressed: _refreshBtDevices,
                            icon: const Icon(Icons.refresh),
                            tooltip: 'Scan Bluetooth',
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '2. Page Cut & Bridge Settings',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField(
                      value: _cutMode,
                      decoration: const InputDecoration(
                        labelText: 'Paper Cut Mode',
                        border: OutlineInputBorder(),
                      ),
                      items: cutItems,
                      onChanged: (val) {
                        if (val != null) {
                          setState(() => _cutMode = val.toString());
                          _saveSettings();
                        }
                      },
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Feed Lines Before Cut: $_feedLines'),
                        Slider(
                          value: _feedLines.toDouble(),
                          min: 0,
                          max: 8,
                          divisions: 8,
                          label: '$_feedLines',
                          onChanged: (val) {
                            setState(() => _feedLines = val.toInt());
                            _saveSettings();
                          },
                        ),
                      ],
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Auto-Print Incoming Text'),
                      subtitle: const Text(
                          'Doosri app se text aate hi foran print + cut karein'),
                      value: _autoPrintOnReceive,
                      onChanged: (val) {
                        setState(() => _autoPrintOnReceive = val);
                        _saveSettings();
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          '3. Receipt Text',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                        TextButton(
                          onPressed: () => _textController.clear(),
                          child: const Text('Clear'),
                        ),
                      ],
                    ),
                    TextField(
                      controller: _textController,
                      maxLines: 6,
                      style: const TextStyle(fontFamily: 'monospace'),
                      decoration: const InputDecoration(
                        hintText:
                            'Yahan text paste karein ya doosri app se bhejein...',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _isPrinting
                          ? null
                          : () => _printText(_textController.text),
                      icon: const Icon(Icons.print),
                      label: Text(_isPrinting
                          ? 'Printing...'
                          : 'Print & Cut Receipt'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Status: $_statusMessage',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Colors.grey.shade700, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
