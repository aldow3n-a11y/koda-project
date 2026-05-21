import 'dart:async';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../models/models.dart';
import 'lidar_service.dart';

// GATT UUIDs — must match ESP32 firmware
const kServiceUuid     = '12345678-1234-1234-1234-123456789012';
const kCmdCharUuid     = '12345678-1234-1234-1234-123456789013';
const kStatusCharUuid  = '12345678-1234-1234-1234-123456789014';
const kLidarCharUuid   = '12345678-1234-1234-1234-123456789015';
const kBodyCharUuid    = '12345678-1234-1234-1234-123456789016';

enum BleStatus { idle, scanning, connecting, connected, disconnected, error }

class BleService {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _cmdChar;
  BluetoothCharacteristic? _statusChar;
  BluetoothCharacteristic? _lidarChar;
  BluetoothCharacteristic? _bodyChar;
  StreamSubscription? _connectionSub;
  Timer? _watchdogTimer;

  // Injected LidarService — set by the provider after construction
  LidarService? lidarService;

  final _statusController     = StreamController<BleStatus>.broadcast();
  final _devicesController    = StreamController<List<KodaBtDevice>>.broadcast();
  final _logController        = StreamController<String>.broadcast();
  final _bodyStateController  = StreamController<KodaBodyState>.broadcast();

  Stream<BleStatus>       get statusStream  => _statusController.stream;
  Stream<List<KodaBtDevice>> get devicesStream => _devicesController.stream;
  Stream<String>          get logStream     => _logController.stream;
  Stream<KodaBodyState>   get bodyStateStream => _bodyStateController.stream;

  BleStatus _currentStatus = BleStatus.idle;
  final List<KodaBtDevice> _foundDevices = [];
  int _watchdogMs = 3000;

  void setWatchdog(int ms) => _watchdogMs = ms;

  void _log(String msg) {
    _logController.add('[BLE] $msg');
  }

  // ── Scan ──────────────────────────────────────────────────────────────────
  Future<void> startScan({Duration timeout = const Duration(seconds: 8)}) async {
    _foundDevices.clear();
    _devicesController.add([]);
    _emit(BleStatus.scanning);
    _log('Scanning for devices…');

    await FlutterBluePlus.startScan(timeout: timeout);

    FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        String name = r.device.platformName;
        if (name.isEmpty) {
          try {
            name = r.advertisementData.advName;
          } catch (_) {}
        }
        if (name.isEmpty) name = 'UNNAMED (${r.device.remoteId.str})';

        final already = _foundDevices.any((d) => d.id == r.device.remoteId.str);
        if (!already) {
          _foundDevices.add(KodaBtDevice(
            id: r.device.remoteId.str,
            name: name,
            rssi: r.rssi,
            type: name.contains('ESP') ? 'ESP32' : (name.contains('UNNAMED') ? 'Hidden' : 'Unknown'),
          ));
          _devicesController.add(List.from(_foundDevices));
          _log('Found: $name (${r.rssi} dBm)');
        }
      }
    });

    await Future.delayed(timeout);
    _emit(BleStatus.idle);
    _log('Scan complete. ${_foundDevices.length} device(s) found.');
  }

  void stopScan() {
    FlutterBluePlus.stopScan();
    _emit(BleStatus.idle);
  }

  // ── Connect ───────────────────────────────────────────────────────────────
  Future<bool> connect(KodaBtDevice device) async {
    _emit(BleStatus.connecting);
    _log('Connecting to ${device.name}…');

    try {
      final btDevice = BluetoothDevice.fromId(device.id);
      await btDevice.connect(timeout: const Duration(seconds: 10));

      _device = btDevice;
      _log('Connected. Discovering services…');

      final services = await btDevice.discoverServices();
      for (final s in services) {
        if (s.uuid.toString() == kServiceUuid) {
          for (final c in s.characteristics) {
            if (c.uuid.toString() == kCmdCharUuid)    _cmdChar    = c;
            if (c.uuid.toString() == kStatusCharUuid) _statusChar = c;
            if (c.uuid.toString() == kLidarCharUuid)  _lidarChar  = c;
            if (c.uuid.toString() == kBodyCharUuid)   _bodyChar   = c;
          }
        }
      }

      // Subscribe to status notifications
      if (_statusChar != null) {
        await _statusChar!.setNotifyValue(true);
        _statusChar!.onValueReceived.listen((data) {
          _log('ESP32 status: ${utf8.decode(data)}');
        });
      }

      // Subscribe to LiDAR scan notifications
      if (_lidarChar != null) {
        await _lidarChar!.setNotifyValue(true);
        _lidarChar!.onValueReceived.listen((data) {
          lidarService?.onBleBytes(data);
        });
        _log('LiDAR characteristic subscribed.');
      } else {
        _log('LiDAR characteristic not found — check ESP32 firmware.');
      }

      // Subscribe to body state notifications
      if (_bodyChar != null) {
        await _bodyChar!.setNotifyValue(true);
        _bodyChar!.onValueReceived.listen((data) {
          _parseBodyPacket(data);
        });
        _log('Body state characteristic subscribed.');
      } else {
        _log('Body state characteristic not found — check ESP32 firmware.');
      }

      // Watch for disconnection
      _connectionSub = btDevice.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _log('Disconnected from ${device.name}');
          _emit(BleStatus.disconnected);
          _cmdChar = null;
          _statusChar = null;
          _bodyChar = null;
        }
      });

      _startWatchdog();
      _emit(BleStatus.connected);
      _log('Ready. CMD characteristic: ${_cmdChar != null}');
      return true;
    } catch (e) {
      _log('Connection error: $e');
      _emit(BleStatus.error);
      return false;
    }
  }

  // ── Disconnect ────────────────────────────────────────────────────────────
  Future<void> disconnect() async {
    _watchdogTimer?.cancel();
    _connectionSub?.cancel();
    await sendStop(); // safety stop before disconnecting
    await _device?.disconnect();
    _device = null;
    _cmdChar = null;
    _statusChar = null;
    _bodyChar = null;
    _emit(BleStatus.disconnected);
    _log('Disconnected by user.');
  }

  // ── Send Commands ─────────────────────────────────────────────────────────
  Future<bool> sendCommand(MotorCommand cmd) async {
    return sendRaw(cmd.toJson());
  }

  Future<bool> sendCommandBatch(List<MotorCommand> cmds) async {
    return sendRaw({'cmds': cmds.map((c) => c.toJson()).toList()});
  }

  Future<bool> sendRaw(Map<String, dynamic> payload) async {
    if (_cmdChar == null) {
      _log('Cannot send — not connected');
      return false;
    }
    try {
      final bytes = utf8.encode(jsonEncode(payload));
      await _cmdChar!.write(bytes, withoutResponse: false);
      _resetWatchdog();
      return true;
    } catch (e) {
      _log('Send error: $e');
      return false;
    }
  }

  Future<bool> sendStop() async {
    return sendRaw({'cmds': [{'cmd': 'stop'}]});
  }

  // ── Watchdog ──────────────────────────────────────────────────────────────
  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(Duration(milliseconds: _watchdogMs), (_) {
      if (_currentStatus == BleStatus.connected) {
        sendRaw({'cmd': 'ping'}); // heartbeat keeps ESP32 watchdog alive
      }
    });
  }

  void _resetWatchdog() {
    _watchdogTimer?.cancel();
    _startWatchdog();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  void _emit(BleStatus s) {
    _currentStatus = s;
    _statusController.add(s);
  }

  bool get isConnected => _currentStatus == BleStatus.connected;

  void dispose() {
    _watchdogTimer?.cancel();
    _connectionSub?.cancel();
    _statusController.close();
    _devicesController.close();
    _logController.close();
    _bodyStateController.close();
  }

  void _parseBodyPacket(List<int> data) {
    if (data.length < 7) return;
    final mood = data[0];
    final arousal = data[1];
    final frontCm = data[2];
    final leftCm = data[3];
    final rightCm = data[4];
    final flags = data[5] | (data[6] << 8);

    final bodyState = KodaBodyState(
      mood: mood,
      arousal: arousal,
      frontCm: frontCm,
      leftCm: leftCm,
      rightCm: rightCm,
      flags: flags,
    );
    _bodyStateController.add(bodyState);
  }
}
