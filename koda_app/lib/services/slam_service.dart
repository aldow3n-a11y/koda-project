import 'dart:math' as math;
import 'lidar_service.dart';
import 'icp_matcher.dart';

// ─── Occupancy Grid ───────────────────────────────────────────────────────────

const int kGridSize     = 300;   // cells per side
const int kCellSizeMm   = 50;    // 50 mm = 5 cm per cell → 15 m × 15 m map
const int kOriginCell   = kGridSize ~/ 2; // robot starts at center

/// Values: -1 = unknown, 0 = free, 100 = occupied.
class OccupancyGrid {
  final List<List<int>> cells;
  int revision = 0;

  OccupancyGrid()
      : cells = List.generate(
          kGridSize,
          (_) => List.filled(kGridSize, -1),
        );

  void reset() {
    for (var row in cells) {
      for (int i = 0; i < row.length; i++) row[i] = -1;
    }
    revision++;
  }

  // World mm → grid cell index
  int _toCell(double mm, int origin) =>
      (origin + mm / kCellSizeMm).round().clamp(0, kGridSize - 1);

  /// Mark a ray from robot (originX, originY in mm) to endpoint free,
  /// and mark the endpoint occupied.
  void traceRay(double robotXmm, double robotYmm,
                double endXmm,   double endYmm,
                {bool endIsObstacle = true}) {
    final x0 = _toCell(robotXmm, kOriginCell);
    final y0 = _toCell(robotYmm, kOriginCell);
    final x1 = _toCell(endXmm,   kOriginCell);
    final y1 = _toCell(endYmm,   kOriginCell);

    // Bresenham line — add confidence model for probabilistic occupancy
    _bresenham(x0, y0, x1, y1, (cx, cy) {
      if (cx == x1 && cy == y1) {
        if (endIsObstacle) {
          cells[cy][cx] = 100; // Hard reset to max confidence for actual hits
        }
      } else {
        int v = cells[cy][cx];
        if (v == -1) {
          cells[cy][cx] = 0; // First time seeing as free
        } else if (v > 0) {
          // Fast fade (-25) for passing rays. 
          // Clears out dynamic 'ghost' obstacles in ~1 second (4 passes).
          cells[cy][cx] = (v - 25).clamp(0, 100);
        }
      }
    });

    revision++;
  }

  void _bresenham(int x0, int y0, int x1, int y1, void Function(int, int) cb) {
    int dx = (x1 - x0).abs();
    int dy = (y1 - y0).abs();
    int sx = x0 < x1 ? 1 : -1;
    int sy = y0 < y1 ? 1 : -1;
    int err = dx - dy;

    int x = x0, y = y0;
    while (true) {
      cb(x, y);
      if (x == x1 && y == y1) break;
      final e2 = 2 * err;
      if (e2 > -dy) { err -= dy; x += sx; }
      if (e2 <  dx) { err += dx; y += sy; }
    }
  }
}

// ─── Robot Pose ───────────────────────────────────────────────────────────────

class RobotPose {
  double xMm;     // positive = forward
  double yMm;     // positive = left
  double heading; // radians, 0 = forward

  RobotPose({this.xMm = 0, this.yMm = 0, this.heading = 0});

  RobotPose copy() => RobotPose(xMm: xMm, yMm: yMm, heading: heading);
}

// ─── SLAM Service ─────────────────────────────────────────────────────────────

/// Lightweight occupancy-grid SLAM:
///  • Dead-reckoning pose estimation from motor commands
///  • Bresenham ray casting on each LiDAR scan
///  • No loop closure (Phase 1)
class SlamService {
  static const double _wheelbaseMm      = 130.0;
  static const double _lidarHeightMm    = 135.0; // for Phase 2 texture use

  // Speed calibration: PWM 0–100 → approximate mm/s
  // At 60% speed the robot does ~200 mm/s (rough estimate, tunable)
  static const double _mmPerSecAt100pct = 330.0;

  final OccupancyGrid grid = OccupancyGrid();
  RobotPose pose = RobotPose();

  // Last raw scan (for rendering rays in painter and ICP)
  LidarScan? latestScan;
  RobotPose? _lastScanPose;

  // Monotonically-increasing counter — listeners use this to know grid changed
  int get revision => grid.revision;

  double get lidarHeightMm => _lidarHeightMm;

  // ── Pose update from motor command ─────────────────────────────────────────

  void updatePoseFromCommand({
    required String cmd,    // 'forward' | 'backward' | 'turnCw' | 'turnCcw' | 'stop'
    required int    speedPct,
    required int    durationMs,
  }) {
    if (durationMs <= 0 || speedPct <= 0) return;

    final dt   = durationMs / 1000.0; // seconds
    final spd  = _mmPerSecAt100pct * speedPct / 100.0;

    switch (cmd) {
      case 'forward':
        pose.xMm += spd * dt * math.cos(pose.heading);
        pose.yMm += spd * dt * math.sin(pose.heading);
      case 'backward':
        pose.xMm -= spd * dt * math.cos(pose.heading);
        pose.yMm -= spd * dt * math.sin(pose.heading);
      case 'turnCw':
        // Angular velocity: arc length = speed, arc = wheelbase * angle
        final omega = spd / (_wheelbaseMm / 2.0); // rad/s
        pose.heading -= omega * dt;
      case 'turnCcw':
        final omega = spd / (_wheelbaseMm / 2.0);
        pose.heading += omega * dt;
      default:
        break;
    }
    // Normalize heading to [-π, π]
    pose.heading = (pose.heading + math.pi) % (2 * math.pi) - math.pi;
  }

  void adjustHeading(double deltaRad) {
    pose.heading += deltaRad;
    pose.heading = (pose.heading + math.pi) % (2 * math.pi) - math.pi;
  }

  void integrateScan(LidarScan scan) {
    if (latestScan != null && _lastScanPose != null) {
      // Calculate how much odometry says we moved since the last scan
      final dWorldX = pose.xMm - _lastScanPose!.xMm;
      final dWorldY = pose.yMm - _lastScanPose!.yMm;
      final dWorldH = pose.heading - _lastScanPose!.heading;

      final lh = _lastScanPose!.heading;
      final odomLocalX = dWorldX * math.cos(-lh) - dWorldY * math.sin(-lh);
      final odomLocalY = dWorldX * math.sin(-lh) + dWorldY * math.cos(-lh);

      // Use odometry as the initial guess to jumpstart ICP
      final icp = IcpMatcher.match(
        source: scan,
        target: latestScan!,
        initialDx: odomLocalX,
        initialDy: odomLocalY,
        initialDTheta: dWorldH,
      );

      if (icp.success) {
        // Replace current pose using the exact verified ICP alignment
        final wDx = icp.dxMm * math.cos(lh) - icp.dyMm * math.sin(lh);
        final wDy = icp.dxMm * math.sin(lh) + icp.dyMm * math.cos(lh);

        pose.xMm = _lastScanPose!.xMm + wDx;
        pose.yMm = _lastScanPose!.yMm + wDy;
        pose.heading = _lastScanPose!.heading + icp.dThetaRad;
        pose.heading = (pose.heading + math.pi) % (2 * math.pi) - math.pi;
      }
    }

    _lastScanPose = pose.copy();
    latestScan = scan;
    
    final rx = pose.xMm;
    final ry = pose.yMm;
    final h  = pose.heading;

    for (final pt in scan.validPoints) {
      // Convert LiDAR-frame polar → robot frame Cartesian
      // LiDAR angle 0° = forward, clockwise positive
      final laRad = pt.angleDeg * math.pi / 180.0;

      // Point in robot frame (x=forward, y=left)
      final ptXrobot = pt.distanceMm * math.cos(-laRad); // mirror angle: CW → CCW math
      final ptYrobot = pt.distanceMm * math.sin(-laRad);

      // Rotate to world frame using robot heading
      final ptXworld = rx + ptXrobot * math.cos(h) - ptYrobot * math.sin(h);
      final ptYworld = ry + ptXrobot * math.sin(h) + ptYrobot * math.cos(h);

      grid.traceRay(rx, ry, ptXworld, ptYworld);
    }
  }

  void resetMap() {
    grid.reset();
    pose = RobotPose();
  }
}
