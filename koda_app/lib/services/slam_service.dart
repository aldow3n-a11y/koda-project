import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/material.dart' show Offset;
import 'lidar_service.dart';
import 'icp_matcher.dart';
import 'path_planner.dart';
import 'lidar_straightener.dart';

// ─── Occupancy Grid ───────────────────────────────────────────────────────────

const int kGridSize   = 300;
const int kCellSizeMm = 50;
const int kOriginCell = kGridSize ~/ 2;

/// Values: -1 = unknown, 0 = free, 100 = occupied.
class OccupancyGrid {
  final List<List<int>> cells;
  final List<List<int>> costmapCells;
  int revision = 0;

  OccupancyGrid()
      : cells = List.generate(kGridSize, (_) => List.filled(kGridSize, -1)),
        costmapCells = List.generate(kGridSize, (_) => List.filled(kGridSize, 0));

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

  /// Connects two points in the grid and marks them as a solid obstacle wall.
  void markWall(double x0mm, double y0mm, double x1mm, double y1mm) {
    final x0 = _toCell(x0mm, kOriginCell);
    final y0 = _toCell(y0mm, kOriginCell);
    final x1 = _toCell(x1mm, kOriginCell);
    final y1 = _toCell(y1mm, kOriginCell);

    _bresenham(x0, y0, x1, y1, (cx, cy) {
      final v = cells[cy][cx];
      cells[cy][cx] = v == -1 ? 50 : (v + 50).clamp(0, 250);
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

  /// Inflates occupied cells to create a safety margin for path planning.
  /// [inflationRadius] is in grid cells (e.g., 3 cells * 50mm = 150mm radius).
  void updateCostmap({int inflationRadius = 3}) {
    for (int y = 0; y < kGridSize; y++) {
      for (int x = 0; x < kGridSize; x++) {
        costmapCells[y][x] = 0;
      }
    }

    for (int y = 0; y < kGridSize; y++) {
      for (int x = 0; x < kGridSize; x++) {
        if (cells[y][x] >= 50) { // Obstacle
          for (int dy = -inflationRadius; dy <= inflationRadius; dy++) {
            for (int dx = -inflationRadius; dx <= inflationRadius; dx++) {
              final ny = y + dy;
              final nx = x + dx;
              if (ny >= 0 && ny < kGridSize && nx >= 0 && nx < kGridSize) {
                final distSq = dx * dx + dy * dy;
                if (distSq <= inflationRadius * inflationRadius) {
                  final dist = math.sqrt(distSq);
                  // 254 is lethal, decays linearly
                  final cost = 254 - ((dist / inflationRadius) * 200).round();
                  if (cost > costmapCells[ny][nx]) {
                    costmapCells[ny][nx] = cost.clamp(0, 254);
                  }
                }
              }
            }
          }
        }
      }
    }
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

  // Planned path
  List<Offset> currentPath = [];

  int get revision => grid.revision;

  // Callback — UI listens to mode + countdown changes
  void Function(SlamMode mode, int secsLeft)? onStateChange;

  // Callback — Issue motor commands for local path execution
  void Function(String cmd, int speedPct, int durationMs)? onMotorCommand;

  // Callback — Fired when the robot is kidnapped (picked up) for the app to trigger relocalization
  void Function()? onKidnapped;

  // Callback — Fired when the robot is physically stuck (wheels spinning but no movement)
  void Function(String reason)? onStuck;

  // Stuck detection state
  int _stuckCount = 0;
  static const int _requiredStuckFrames = 5;
  DateTime _lastMoveTime = DateTime.now();
  DateTime _lastMatchTime = DateTime.now();
  Completer<bool>? _navCompleter;

  // Relocalization state
  bool isLost = false;

  // ── Timers ─────────────────────────────────────────────────────────────────
  Timer? _decayTimer;
  Timer? _costmapTimer;
  Timer? _driveTimer;
  Timer? _autoSaveTimer;

  SlamService() {
    _costmapTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      grid.updateCostmap();
      grid.revision++; // Force UI redraw for the costmap
    });

    // Local Planner Loop (10Hz)
    _driveTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      _runLocalPlanner();
    });

    // Auto-save map every 30 seconds
    _autoSaveTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mode == SlamMode.mapping || mode == SlamMode.navigation) {
        saveMap();
      }
    });
  }

  void _runLocalPlanner() {
    if (currentPath.isEmpty || (mode != SlamMode.mapping && mode != SlamMode.navigation)) return;

    // 1. Get current target waypoint
    // If we are very close to the first point, pop it.
    final robotPos = Offset(pose.xMm, pose.yMm);
    while (currentPath.isNotEmpty) {
      final target = currentPath.first;
      final distSq = (target.dx - robotPos.dx) * (target.dx - robotPos.dx) + 
                     (target.dy - robotPos.dy) * (target.dy - robotPos.dy);
      // Reached waypoint if within 60mm
      if (distSq < 3600) {
        currentPath.removeAt(0);
      } else {
        break;
      }
    }

    if (currentPath.isEmpty) {
      grid.revision++; // Path finished
      if (_navCompleter != null && !_navCompleter!.isCompleted) {
        _navCompleter!.complete(true);
        _navCompleter = null;
      }
      return;
    }

    final target = currentPath.first;
    
    // 2. Calculate Heading Error
    final dx = target.dx - robotPos.dx;
    final dy = target.dy - robotPos.dy;
    final targetHeading = math.atan2(dy, dx);
    
    // Normalize error to [-pi, pi]
    double headingError = targetHeading - pose.heading;
    while (headingError > math.pi) headingError -= 2 * math.pi;
    while (headingError < -math.pi) headingError += 2 * math.pi;

    // 3. Issue Command (Basic Pure Pursuit)
    // Send short 100ms commands since the loop runs at 10Hz
    if (headingError.abs() > 0.35) { // ~20 degrees
      if (headingError > 0) {
        onMotorCommand?.call('turnCcw', 60, 100);
      } else {
        onMotorCommand?.call('turnCw', 60, 100);
      }
    } else {
      // Roughly facing target, drive forward
      onMotorCommand?.call('forward', 60, 100);
    }
  }

  /// Call whenever `lidarDecaySec` setting changes. `delaySec` == 0 disables.
  void setDecay(int delaySec) {
    _decayTimer?.cancel();
    _decayTimer = null;
    if (delaySec > 0) {
      final double decrement = 250.0 / delaySec;
      _decayTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _runDecay(decrement),
      );
    }
  }

  void _runDecay(double decrement) {
    if (_mode != SlamMode.mapping) return;
    bool changed = false;
    for (int y = 0; y < kGridSize; y++) {
      for (int x = 0; x < kGridSize; x++) {
        final v = grid.cells[y][x];
        if (v > 0) {
          final nv = (v - decrement).clamp(0, 250).round();
          if (nv != v) {
            grid.cells[y][x] = nv;
            changed = true;
          }
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
    final straightenedScan = LidarStraightener.straightenScan(scan);
    switch (_mode) {
      case SlamMode.bootstrap:
        _integrateBootstrap(straightenedScan);
      case SlamMode.mapping:
      case SlamMode.navigation:
        _integrateMapping(straightenedScan);
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
    final now = DateTime.now();
    final isMoving = now.difference(_lastMoveTime).inMilliseconds < 500;
    final throttleMs = isMoving ? 300 : 2000;
    if (now.difference(_lastMatchTime).inMilliseconds < throttleMs) {
      return;
    }
    _lastMatchTime = now;

    if (latestScan != null && _lastScanPose != null) {
      final dWorldX = pose.xMm - _lastScanPose!.xMm;
      final dWorldY = pose.yMm - _lastScanPose!.yMm;
      final dWorldH = pose.heading - _lastScanPose!.heading;

      final movedMm    = math.sqrt(dWorldX * dWorldX + dWorldY * dWorldY);
      final rotatedRad = dWorldH.abs();

      if (movedMm > 20.0 || rotatedRad > 0.05 || !isMoving) {
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
          
          final isCorrectionSignificant = icp.dThetaRad.abs() > 0.02 ||
              icp.dxMm.abs() > 20.0 ||
              icp.dyMm.abs() > 20.0;
          
          if (isCorrectionSignificant) {
            _lastMoveTime = now;
          }
          
          // Only apply ICP rotation if the robot has moved recently or the rotation correction is significant.
          // This prevents the map from constantly rotating when stationary.
          if (isMoving || icp.dThetaRad.abs() > 0.02) {
            pose.heading += icp.dThetaRad;
          } else {
            // Heavily dampen stationary rotation noise to stop continuous drifting
            pose.heading += icp.dThetaRad * 0.01;
          }
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
            
            final isCorrectionSignificant = fallbackIcp.dThetaRad.abs() > 0.02 ||
                fallbackIcp.dxMm.abs() > 20.0 ||
                fallbackIcp.dyMm.abs() > 20.0;
                
            if (isCorrectionSignificant) {
              _lastMoveTime = now;
            }

            // Only apply fallback rotation if the robot has moved recently or the rotation correction is significant.
            if (isMoving || fallbackIcp.dThetaRad.abs() > 0.02) {
              pose.heading = _lastScanPose!.heading + fallbackIcp.dThetaRad;
            } else {
              pose.heading = _lastScanPose!.heading + fallbackIcp.dThetaRad * 0.01;
            }
            pose.heading = (pose.heading + math.pi) % (2 * math.pi) - math.pi;
          }
        }

        // Calculate actual physical movement since last scan
        final actualMoved = math.sqrt(
          (pose.xMm - _lastScanPose!.xMm) * (pose.xMm - _lastScanPose!.xMm) +
          (pose.yMm - _lastScanPose!.yMm) * (pose.yMm - _lastScanPose!.yMm)
        );
        final actualRotated = (pose.heading - _lastScanPose!.heading).abs();

        // If actual movement is significantly less than expected movement
        final bool stuckTrans = movedMm > 25.0 && actualMoved < (movedMm * 0.25).clamp(5.0, 15.0);
        final bool stuckRot = rotatedRad > 0.06 && actualRotated < (rotatedRad * 0.25).clamp(0.01, 0.03);

        if (stuckTrans || stuckRot) {
          _stuckCount++;
          if (_stuckCount >= _requiredStuckFrames) {
            _stuckCount = 0;
            onStuck?.call('stuck');
            if (_navCompleter != null && !_navCompleter!.isCompleted) {
              _navCompleter!.complete(false);
              _navCompleter = null;
            }
          }
        } else {
          _stuckCount = 0;
        }
      } else {
        _stuckCount = 0;
      }
    }

    _lastScanPose = pose.copy();
    latestScan    = scan;
    if (_mode == SlamMode.mapping) {
      _castRays(scan, pose);
    }
  }

  void _castRays(LidarScan scan, RobotPose p) {
    final rx = p.xMm, ry = p.yMm, h = p.heading;
    
    double? lastX;
    double? lastY;

    for (int i = 0; i < scan.validPoints.length; i++) {
      final pt = scan.validPoints[i];
      final laRad    = pt.angleDeg * math.pi / 180.0;
      final ptXrobot = pt.distanceMm * math.cos(-laRad);
      final ptYrobot = pt.distanceMm * math.sin(-laRad);
      final ptXworld = rx + ptXrobot * math.cos(h) - ptYrobot * math.sin(h);
      final ptYworld = ry + ptXrobot * math.sin(h) + ptYrobot * math.cos(h);
      
      grid.traceRay(rx, ry, ptXworld, ptYworld);

      if (lastX != null && lastY != null) {
        final distSq = (ptXworld - lastX) * (ptXworld - lastX) + (ptYworld - lastY) * (ptYworld - lastY);
        // Connect points if they are less than 200mm apart to form solid walls
        if (distSq < 40000) {
          grid.markWall(lastX, lastY, ptXworld, ptYworld);
        }
      }
      lastX = ptXworld;
      lastY = ptYworld;
    }
    
    // Connect the last point to the first point if close
    if (scan.validPoints.length > 2 && lastX != null && lastY != null) {
      final pt = scan.validPoints.first;
      final laRad    = pt.angleDeg * math.pi / 180.0;
      final ptXrobot = pt.distanceMm * math.cos(-laRad);
      final ptYrobot = pt.distanceMm * math.sin(-laRad);
      final ptXworld = rx + ptXrobot * math.cos(h) - ptYrobot * math.sin(h);
      final ptYworld = ry + ptXrobot * math.sin(h) + ptYrobot * math.cos(h);
      
      final distSq = (ptXworld - lastX) * (ptXworld - lastX) + (ptYworld - lastY) * (ptYworld - lastY);
      if (distSq < 40000) {
        grid.markWall(lastX, lastY, ptXworld, ptYworld);
      }
    }
  }

  // ── Pose update from motor command ─────────────────────────────────────────

  void updatePoseFromCommand({
    required String cmd,
    required int    speedPct,
    required int    durationMs,
  }) {
    if (durationMs <= 0 || speedPct <= 0) return;
    
    if (cmd != 'stop') {
      _lastMoveTime = DateTime.now();
    }
    
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

  // ── Kidnap / Relocalization ─────────────────────────────────────────────────

  /// Called by ImuService when a lift event is detected.
  /// Freezes ICP history and marks robot as lost.
  void invalidatePose() {
    _lastScanPose = null;
    latestScan = null;
    cancelNavigation();
    isLost = true;
    onKidnapped?.call();
  }

  /// Resets the "lost" flag once visual relocalization is confirmed.
  /// The app/skill can call this after Gemini successfully identifies the location.
  void confirmRelocalized({double? xMm, double? yMm, double? headingRad}) {
    if (xMm != null) pose.xMm = xMm;
    if (yMm != null) pose.yMm = yMm;
    if (headingRad != null) pose.heading = headingRad;
    isLost = false;
    _lastScanPose = pose.copy();
  }

  // ── Human-readable pose for LLM prompt ───────────────────────────────────

  /// Returns pose as readable strings suitable for injecting into a system prompt.
  Map<String, String> get poseContext {
    final xCm  = (pose.xMm / 10).round();
    final yCm  = (pose.yMm / 10).round();
    final deg  = (pose.heading * 180 / math.pi).round();
    // Convert heading to compass direction
    String compass;
    if (deg >= -22 && deg <= 22)        compass = 'North';
    else if (deg > 22 && deg <= 67)     compass = 'North-East';
    else if (deg > 67 && deg <= 112)    compass = 'East';
    else if (deg > 112 && deg <= 157)   compass = 'South-East';
    else if (deg > 157 || deg < -157)   compass = 'South';
    else if (deg >= -157 && deg < -112) compass = 'South-West';
    else if (deg >= -112 && deg < -67)  compass = 'West';
    else                                compass = 'North-West';

    return {
      'x': '${xCm}cm',
      'y': '${yCm}cm',
      'heading': '$deg° ($compass)',
      'isLost': isLost ? 'YES — position is unknown, relocalization needed' : 'NO',
    };
  }

  // ── Path Planning ──────────────────────────────────────────────────────────

  bool planTo(double targetXmm, double targetYmm) {
    cancelNavigation();
    final goalMm = Offset(targetXmm, targetYmm);
    final startMm = Offset(pose.xMm, pose.yMm);
    currentPath = PathPlanner.planPath(grid, startMm, goalMm);
    grid.revision++; // trigger redraw
    return currentPath.isNotEmpty;
  }

  Future<bool> driveTo(double targetXmm, double targetYmm) {
    final ok = planTo(targetXmm, targetYmm);
    if (!ok) {
      return Future.value(false);
    }
    _navCompleter = Completer<bool>();
    return _navCompleter!.future;
  }

  void cancelNavigation() {
    if (currentPath.isNotEmpty) {
      currentPath = [];
      grid.revision++;
    }
    if (_navCompleter != null && !_navCompleter!.isCompleted) {
      _navCompleter!.complete(false);
    }
    _navCompleter = null;
  }

  void clearPath() {
    cancelNavigation();
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
    cancelNavigation();
    _mode = SlamMode.idle;
    onStateChange?.call(_mode, 0);
  }

  void dispose() {
    _bootstrapTimer?.cancel();
    _decayTimer?.cancel();
    _costmapTimer?.cancel();
    _driveTimer?.cancel();
    _autoSaveTimer?.cancel();
  }
}
