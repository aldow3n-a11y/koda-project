import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'lidar_service.dart';
import 'icp_matcher.dart';

// ─── Occupancy Grid ───────────────────────────────────────────────────────────

const int kGridSize   = 300;
const int kCellSizeMm = 50;
const int kOriginCell = kGridSize ~/ 2;

/// Values: -1 = unknown, 0 = free, 100 = occupied.
class OccupancyGrid {
  final List<List<int>> cells;
  int revision = 0;

  OccupancyGrid()
      : cells = List.generate(kGridSize, (_) => List.filled(kGridSize, -1));

  void reset() {
    for (var row in cells) {
      for (int i = 0; i < row.length; i++) row[i] = -1;
    }
    revision++;
  }

  int _toCell(double mm, int origin) =>
      (origin + mm / kCellSizeMm).round().clamp(0, kGridSize - 1);

  void traceRay(double robotXmm, double robotYmm,
                double endXmm,   double endYmm,
                {bool endIsObstacle = true}) {
    final x0 = _toCell(robotXmm, kOriginCell);
    final y0 = _toCell(robotYmm, kOriginCell);
    final x1 = _toCell(endXmm,   kOriginCell);
    final y1 = _toCell(endYmm,   kOriginCell);

    _bresenham(x0, y0, x1, y1, (cx, cy) {
      if (cx == x1 && cy == y1) {
        if (endIsObstacle) {
          final v = cells[cy][cx];
          cells[cy][cx] = v == -1 ? 25 : (v + 25).clamp(0, 250);
        }
      } else {
        final v = cells[cy][cx];
        if (v == -1) {
          cells[cy][cx] = 0;
        } else if (v > 0) {
          cells[cy][cx] = (v - 25).clamp(0, 250);
        }
      }
    });
    revision++;
  }

  void _bresenham(int x0, int y0, int x1, int y1, void Function(int, int) cb) {
    int dx = (x1 - x0).abs(), dy = (y1 - y0).abs();
    int sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1;
    int err = dx - dy, x = x0, y = y0;
    while (true) {
      cb(x, y);
      if (x == x1 && y == y1) break;
      final e2 = 2 * err;
      if (e2 > -dy) { err -= dy; x += sx; }
      if (e2 <  dx) { err += dx; y += sy; }
    }
  }

  /// Serialize to flat byte list for persistence (300×300 = 90 000 bytes)
  Uint8List toBytes() {
    final buf = Uint8List(kGridSize * kGridSize);
    int i = 0;
    for (int y = 0; y < kGridSize; y++) {
      for (int x = 0; x < kGridSize; x++) {
        // -1 stored as 255, 0–100 stored as-is
        buf[i++] = cells[y][x] == -1 ? 255 : cells[y][x];
      }
    }
    return buf;
  }

  void fromBytes(Uint8List buf) {
    int i = 0;
    for (int y = 0; y < kGridSize; y++) {
      for (int x = 0; x < kGridSize; x++) {
        final v = buf[i++];
        cells[y][x] = v == 255 ? -1 : v;
      }
    }
    revision++;
  }

  int get occupiedCount =>
      cells.expand((r) => r).where((v) => v >= 50).length;
}

// ─── Robot Pose ───────────────────────────────────────────────────────────────

class RobotPose {
  double xMm;
  double yMm;
  double heading; // radians, 0 = forward

  RobotPose({this.xMm = 0, this.yMm = 0, this.heading = 0});
  RobotPose copy() => RobotPose(xMm: xMm, yMm: yMm, heading: heading);
}

// ─── SLAM Mode ────────────────────────────────────────────────────────────────

enum SlamMode {
  idle,        // No map, no scan integration
  bootstrap,   // Robot still — accumulating anchor geometry (10s)
  mapping,     // Robot moving — ICP + ray casting
  navigation,  // Saved map loaded — localize against it
}

// ─── SLAM Service ─────────────────────────────────────────────────────────────

class SlamService {
  double wheelbaseMm = 130.0;
  double mmPerSecAt100pct = 330.0;
  double turnCalibrationFactor = 1.0;
  bool useImuHeading = false;

  static const int    _bootstrapSec     = 10;
  static const double _bootstrapMaxMoveMm  = 5.0;   // max allowed translation
  static const double _bootstrapMaxRotRad  = 0.035; // max allowed rotation (~2°)
  static const int    _minBootstrapCells   = 20;    // min occupied cells to accept anchor

  final OccupancyGrid grid = OccupancyGrid();
  RobotPose pose = RobotPose();

  SlamMode _mode = SlamMode.idle;
  SlamMode get mode => _mode;

  // Bootstrap state
  int _bootstrapSecsLeft = _bootstrapSec;
  int get bootstrapSecsLeft => _bootstrapSecsLeft;
  Timer? _bootstrapTimer;
  LidarScan? _bootstrapLastScan;

  // ICP state
  LidarScan? latestScan;
  RobotPose? _lastScanPose;

  int get revision => grid.revision;

  // Callback — UI listens to mode + countdown changes
  void Function(SlamMode mode, int secsLeft)? onStateChange;

  // ── Decay timer ────────────────────────────────────────────────────────────
  Timer? _decayTimer;

  /// Call whenever `lidarDecaySec` setting changes. `delaySec` == 0 disables.
  void setDecay(int delaySec) {
    _decayTimer?.cancel();
    _decayTimer = null;
    if (delaySec > 0) {
      _decayTimer = Timer.periodic(
        Duration(seconds: delaySec),
        (_) => _runDecay(),
      );
    }
  }

  void _runDecay() {
    bool changed = false;
    for (int y = 0; y < kGridSize; y++) {
      for (int x = 0; x < kGridSize; x++) {
        final v = grid.cells[y][x];
        if (v > 0) {
          grid.cells[y][x] = (v - 10).clamp(0, 100);
          changed = true;
        }
      }
    }
    if (changed) grid.revision++;
  }

  // ── Bootstrap ──────────────────────────────────────────────────────────────

  /// Call this when user taps RESET or on cold boot with no saved map.
  void startBootstrap() {
    _mode = SlamMode.bootstrap;
    _bootstrapSecsLeft = _bootstrapSec;
    _bootstrapLastScan = null;
    latestScan = null;
    _lastScanPose = null;
    grid.reset();
    pose = RobotPose();
    _bootstrapTimer?.cancel();
    _bootstrapTimer = Timer.periodic(const Duration(seconds: 1), _onBootstrapTick);
    onStateChange?.call(_mode, _bootstrapSecsLeft);
  }

  void _onBootstrapTick(Timer t) {
    _bootstrapSecsLeft--;
    if (_bootstrapSecsLeft <= 0) {
      t.cancel();
      _finishBootstrap();
    }
    onStateChange?.call(_mode, _bootstrapSecsLeft);
  }

  void _resetBootstrap() {
    _bootstrapSecsLeft = _bootstrapSec;
    _bootstrapLastScan = null;
    grid.reset();
    onStateChange?.call(_mode, _bootstrapSecsLeft);
  }

  void _finishBootstrap() {
    if (grid.occupiedCount < _minBootstrapCells) {
      // Not enough geometry — restart
      _resetBootstrap();
      _bootstrapTimer = Timer.periodic(
          const Duration(seconds: 1), _onBootstrapTick);
      return;
    }
    _mode = SlamMode.mapping;
    _lastScanPose = pose.copy();
    onStateChange?.call(_mode, 0);
  }

  // ── Scan integration ───────────────────────────────────────────────────────

  void integrateScan(LidarScan scan) {
    switch (_mode) {
      case SlamMode.bootstrap:
        _integrateBootstrap(scan);
      case SlamMode.mapping:
      case SlamMode.navigation:
        _integrateMapping(scan);
      case SlamMode.idle:
        break;
    }
  }

  void _integrateBootstrap(LidarScan scan) {
    // Check robot is genuinely still by ICP against previous bootstrap scan
    if (_bootstrapLastScan != null) {
      final icp = IcpMatcher.match(
        source: scan,
        target: _bootstrapLastScan!,
        initialDx: 0, initialDy: 0, initialDTheta: 0,
      );
      if (icp.success) {
        final moved = math.sqrt(icp.dxMm * icp.dxMm + icp.dyMm * icp.dyMm);
        if (moved > _bootstrapMaxMoveMm ||
            icp.dThetaRad.abs() > _bootstrapMaxRotRad) {
          // Robot moved — restart bootstrap
          _resetBootstrap();
          _bootstrapTimer?.cancel();
          _bootstrapTimer = Timer.periodic(
              const Duration(seconds: 1), _onBootstrapTick);
        }
      }
    }
    _bootstrapLastScan = scan;

    // Always cast rays during bootstrap to build anchor geometry
    _castRays(scan, pose);
    latestScan = scan;
  }

  void _integrateMapping(LidarScan scan) {
    if (latestScan != null && _lastScanPose != null) {
      final dWorldX = pose.xMm - _lastScanPose!.xMm;
      final dWorldY = pose.yMm - _lastScanPose!.yMm;
      final dWorldH = pose.heading - _lastScanPose!.heading;

      final movedMm    = math.sqrt(dWorldX * dWorldX + dWorldY * dWorldY);
      final rotatedRad = dWorldH.abs();

      if (movedMm > 20.0 || rotatedRad > 0.05) {
        final icp = IcpMatcher.matchToGrid(
          source: scan,
          initialX: pose.xMm,
          initialY: pose.yMm,
          initialHeading: pose.heading,
          grid: grid,
        );

        if (icp.success) {
          pose.xMm += icp.dxMm;
          pose.yMm += icp.dyMm;
          pose.heading += icp.dThetaRad;
          pose.heading = (pose.heading + math.pi) % (2 * math.pi) - math.pi;
        } else {
          // Fallback to frame-to-frame ICP if grid matching fails (e.g. sparse map)
          final lh          = _lastScanPose!.heading;
          final odomLocalX  = dWorldX * math.cos(-lh) - dWorldY * math.sin(-lh);
          final odomLocalY  = dWorldX * math.sin(-lh) + dWorldY * math.cos(-lh);

          final fallbackIcp = IcpMatcher.match(
            source: scan,
            target: latestScan!,
            initialDx: odomLocalX,
            initialDy: odomLocalY,
            initialDTheta: dWorldH,
          );

          if (fallbackIcp.success) {
            final wDx = fallbackIcp.dxMm * math.cos(lh) - fallbackIcp.dyMm * math.sin(lh);
            final wDy = fallbackIcp.dxMm * math.sin(lh) + fallbackIcp.dyMm * math.cos(lh);
            pose.xMm    = _lastScanPose!.xMm + wDx;
            pose.yMm    = _lastScanPose!.yMm + wDy;
            pose.heading = _lastScanPose!.heading + fallbackIcp.dThetaRad;
            pose.heading = (pose.heading + math.pi) % (2 * math.pi) - math.pi;
          }
        }
      }
    }

    _lastScanPose = pose.copy();
    latestScan    = scan;
    _castRays(scan, pose);
  }

  void _castRays(LidarScan scan, RobotPose p) {
    final rx = p.xMm, ry = p.yMm, h = p.heading;
    for (final pt in scan.validPoints) {
      final laRad    = pt.angleDeg * math.pi / 180.0;
      final ptXrobot = pt.distanceMm * math.cos(-laRad);
      final ptYrobot = pt.distanceMm * math.sin(-laRad);
      final ptXworld = rx + ptXrobot * math.cos(h) - ptYrobot * math.sin(h);
      final ptYworld = ry + ptXrobot * math.sin(h) + ptYrobot * math.cos(h);
      grid.traceRay(rx, ry, ptXworld, ptYworld);
    }
  }

  // ── Pose update from motor command ─────────────────────────────────────────

  void updatePoseFromCommand({
    required String cmd,
    required int    speedPct,
    required int    durationMs,
  }) {
    if (durationMs <= 0 || speedPct <= 0) return;
    final dt  = durationMs / 1000.0;
    final spd = mmPerSecAt100pct * speedPct / 100.0;
    
    switch (cmd) {
      case 'forward':
        pose.xMm += spd * dt * math.cos(pose.heading);
        pose.yMm += spd * dt * math.sin(pose.heading);
      case 'backward':
        pose.xMm -= spd * dt * math.cos(pose.heading);
        pose.yMm -= spd * dt * math.sin(pose.heading);
      case 'turnCw':
        if (!useImuHeading) {
          pose.heading -= (spd / (wheelbaseMm / 2.0)) * dt * turnCalibrationFactor;
        }
      case 'turnCcw':
        if (!useImuHeading) {
          pose.heading += (spd / (wheelbaseMm / 2.0)) * dt * turnCalibrationFactor;
        }
      default:
        break;
    }
    pose.heading = (pose.heading + math.pi) % (2 * math.pi) - math.pi;
  }

  void adjustHeading(double deltaRad) {
    pose.heading += deltaRad;
    pose.heading = (pose.heading + math.pi) % (2 * math.pi) - math.pi;
  }

  // ── Map persistence ────────────────────────────────────────────────────────

  static Future<File> _mapFile(String name) async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/koda_map_$name.bin');
  }

  /// Save current grid to disk. Returns true on success.
  Future<bool> saveMap({String name = 'default'}) async {
    try {
      final file = await _mapFile(name);
      final rawBytes = grid.toBytes();
      final compressed = zlib.encode(rawBytes);
      
      final mapData = {
        'version': 2,
        'gridSize': kGridSize,
        'cellSizeMm': kCellSizeMm,
        'pose': {
          'xMm': pose.xMm,
          'yMm': pose.yMm,
          'heading': pose.heading,
        },
        'dataBase64': base64Encode(compressed),
      };

      await file.writeAsString(jsonEncode(mapData));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Load map from disk. Returns true if file existed and loaded.
  /// Switches to navigation mode on success.
  Future<bool> loadMap({String name = 'default'}) async {
    try {
      final file = await _mapFile(name);
      if (!await file.exists()) return false;
      
      final contentBytes = await file.readAsBytes();
      
      try {
        // Try parsing as V2 JSON
        final contentString = utf8.decode(contentBytes);
        final mapData = jsonDecode(contentString) as Map<String, dynamic>;
        
        if (mapData['version'] == 2) {
          final b64 = mapData['dataBase64'] as String;
          final compressed = base64Decode(b64);
          final rawBytes = zlib.decode(compressed) as Uint8List;
          
          grid.fromBytes(rawBytes);
          
          final poseData = mapData['pose'] as Map<String, dynamic>?;
          if (poseData != null) {
            pose.xMm = (poseData['xMm'] as num).toDouble();
            pose.yMm = (poseData['yMm'] as num).toDouble();
            pose.heading = (poseData['heading'] as num).toDouble();
          }
        } else {
          throw const FormatException('Unsupported map version');
        }
      } catch (_) {
        // Fallback to V1 Raw Binary
        grid.fromBytes(contentBytes);
      }

      _mode = SlamMode.navigation;
      _lastScanPose = pose.copy();
      onStateChange?.call(_mode, 0);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Check if a saved map exists on disk.
  static Future<bool> hasSavedMap({String name = 'default'}) async {
    try {
      final file = await _mapFile(name);
      return file.exists();
    } catch (_) {
      return false;
    }
  }

  // ── Reset ──────────────────────────────────────────────────────────────────

  void resetMap() {
    _bootstrapTimer?.cancel();
    _decayTimer?.cancel();
    _decayTimer = null;
    grid.reset();
    pose = RobotPose();
    latestScan    = null;
    _lastScanPose = null;
    _bootstrapLastScan = null;
    _mode = SlamMode.idle;
    onStateChange?.call(_mode, 0);
  }
}
