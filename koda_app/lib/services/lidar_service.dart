import 'dart:async';
import 'dart:math' as math;

// ─── LiDAR Data Models ────────────────────────────────────────────────────────

/// A single distance measurement: angle in radians, distance in mm.
class LidarPoint {
  final double angleDeg;   // 0–360°, clockwise from forward
  final double distanceMm; // 0 = invalid/no return

  const LidarPoint({required this.angleDeg, required this.distanceMm});

  /// Convert to Cartesian (mm, robot frame: x=forward, y=left)
  double get x => distanceMm * math.cos(angleDeg * math.pi / 180.0);
  double get y => distanceMm * math.sin(angleDeg * math.pi / 180.0);

  bool get isValid => distanceMm > 50 && distanceMm < 8000;
}

/// One full 360° revolution of LiDAR scan data.
class LidarScan {
  final List<LidarPoint> points;
  final DateTime timestamp;

  const LidarScan({required this.points, required this.timestamp});

  int get pointCount => points.length;
  List<LidarPoint> get validPoints => points.where((p) => p.isValid).toList();

  /// Nearest valid obstacle, in mm. Returns null if no valid points.
  double? get nearestDistanceMm {
    final valid = validPoints;
    if (valid.isEmpty) return null;
    return valid.map((p) => p.distanceMm).reduce(math.min);
  }

  /// Angle (degrees) of nearest obstacle. Returns null if no valid points.
  double? get nearestAngleDeg {
    final valid = validPoints;
    if (valid.isEmpty) return null;
    return valid.reduce((a, b) => a.distanceMm < b.distanceMm ? a : b).angleDeg;
  }
}

// ─── LiDAR Service ────────────────────────────────────────────────────────────

/// Receives raw BLE bytes from the ESP32 LiDAR characteristic,
/// parses the packet protocol, and emits [LidarScan] per revolution.
///
/// Protocol (LD-series compatible, 0xAA 0x55 framing):
///   [0xAA][0x55][speed:1B][start_angle_lo:1B][start_angle_hi:1B]
///   [n_points:1B][dist0_lo:1B][dist0_hi:1B]...[distN_lo:1B][distN_hi:1B]
///   [end_angle_lo:1B][end_angle_hi:1B][checksum:2B]
///
/// If protocol does not match, raw bytes are available via [rawBytesStream]
/// for manual inspection / protocol identification.
class LidarService {
  static const int _maxBufSize  = 4096;

  final _buffer = <int>[];
  final _scanAccum = <LidarPoint>[];

  final _scanController    = StreamController<LidarScan>.broadcast();
  final _rawController     = StreamController<List<int>>.broadcast();
  final _logController     = StreamController<String>.broadcast();
  Timer? _sweepTimer;

  Stream<LidarScan>  get scanStream    => _scanController.stream;
  Stream<List<int>>  get rawBytesStream => _rawController.stream;
  Stream<String>     get logStream     => _logController.stream;

  bool _receiving = false;
  int  _totalPackets = 0;
  int  _errorPackets = 0;

  bool get isReceiving => _receiving;
  int  get totalPackets => _totalPackets;

  /// Called by BleService when new bytes arrive on the LiDAR characteristic.
  void onBleBytes(List<int> bytes) {
    _receiving = true;
    _rawController.add(bytes);

    _buffer.addAll(bytes);
    if (_buffer.length > _maxBufSize) {
      _buffer.removeRange(0, _buffer.length - _maxBufSize);
    }

    _parseBuffer();
  }

  void _parseBuffer() {
    bool pointsAdded = false;

    // ESP32 sends 4-byte pairs: [angle_L, angle_H, dist_L, dist_H]
    while (_buffer.length >= 4) {
      final angleLo = _buffer[0];
      final angleHi = _buffer[1];
      final distLo  = _buffer[2];
      final distHi  = _buffer[3];

      _buffer.removeRange(0, 4);

      final angle = (angleLo | (angleHi << 8)).toDouble();
      final dist  = (distLo | (distHi << 8)).toDouble();

      if (dist > 0) {
        // Hardware offset: LiDAR dead center front is mechanically at 40°
        double correctedAngle = angle - 40.0;
        if (correctedAngle < 0) correctedAngle += 360.0;

        _scanAccum.add(LidarPoint(angleDeg: correctedAngle, distanceMm: dist));
        pointsAdded = true;
      }
    }

    if (pointsAdded) {
      // The ESP32 sends a complete 360 sweep every 350ms in a burst of BLE packets.
      // Wait a short time to accumulate the full burst before emitting the SLAM scan.
      _sweepTimer?.cancel();
      _sweepTimer = Timer(const Duration(milliseconds: 150), () {
        if (_scanAccum.isNotEmpty) {
          _emitScan();
          _totalPackets++;
        }
      });
    }
  }

  void _emitScan() {
    if (_scanAccum.isEmpty) return;
    final scan = LidarScan(
      points: List.from(_scanAccum),
      timestamp: DateTime.now(),
    );
    _scanAccum.clear();
    _scanController.add(scan);
    _log('Scan emitted: ${scan.pointCount} pts');
  }

  void reset() {
    _sweepTimer?.cancel();
    _buffer.clear();
    _scanAccum.clear();
    _receiving = false;
    _totalPackets = 0;
    _errorPackets = 0;
  }

  void _log(String msg) => _logController.add('[LIDAR] $msg');

  void dispose() {
    _sweepTimer?.cancel();
    _scanController.close();
    _rawController.close();
    _logController.close();
  }
}
