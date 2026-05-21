import 'dart:math' as math;
import 'dart:ui';
import 'lidar_service.dart';

class IcpTransform {
  final double dxMm;
  final double dyMm;
  final double dThetaRad;
  final bool success;

  const IcpTransform(this.dxMm, this.dyMm, this.dThetaRad, this.success);
}

class IcpMatcher {
  static const int _maxIterations = 10;
  static const double _maxPointDistMm = 400.0;
  static const double _minErrorDelta = 1.0;

  /// Runs the full 2D Iterative Closest Point algorithm between two laser scans.
  static IcpTransform match({
    required LidarScan source,
    required LidarScan target,
    double initialDx = 0.0,
    double initialDy = 0.0,
    double initialDTheta = 0.0,
  }) {
    var sourcePts = _toCartesian(source);
    final targetPts = _toCartesian(target);

    if (sourcePts.length < 10 || targetPts.length < 10) {
      return const IcpTransform(0, 0, 0, false);
    }

    sourcePts = _transformPoints(sourcePts, initialDx, initialDy, initialDTheta);

    double totalDx = initialDx;
    double totalDy = initialDy;
    double totalDTheta = initialDTheta;

    double lastError = double.infinity;

    for (int iter = 0; iter < _maxIterations; iter++) {
      final matchedSource = <Offset>[];
      final matchedTarget = <Offset>[];
      double currentError = 0;

      // O(N^2) Brute Force Nearest Neighbor (Extremely fast in Dart for ~300 points)
      for (final s in sourcePts) {
        double minDistSq = double.infinity;
        Offset? bestT;

        for (final t in targetPts) {
          final dx = s.dx - t.dx;
          final dy = s.dy - t.dy;
          final distSq = dx * dx + dy * dy;
          if (distSq < minDistSq) {
            minDistSq = distSq;
            bestT = t;
          }
        }

        if (bestT != null && minDistSq < _maxPointDistMm * _maxPointDistMm) {
          matchedSource.add(s);
          matchedTarget.add(bestT);
          currentError += math.sqrt(minDistSq);
        }
      }

      if (matchedSource.length < 10) break;
      currentError /= matchedSource.length;

      if ((lastError - currentError).abs() < _minErrorDelta) break;
      lastError = currentError;

      double cxS = 0, cyS = 0, cxT = 0, cyT = 0;
      final len = matchedSource.length;
      for (int i = 0; i < len; i++) {
        cxS += matchedSource[i].dx;
        cyS += matchedSource[i].dy;
        cxT += matchedTarget[i].dx;
        cyT += matchedTarget[i].dy;
      }
      cxS /= len; cyS /= len;
      cxT /= len; cyT /= len;

      double sxx = 0, sxy = 0, syx = 0, syy = 0;
      for (int i = 0; i < len; i++) {
        final psX = matchedSource[i].dx - cxS;
        final psY = matchedSource[i].dy - cyS;
        final ptX = matchedTarget[i].dx - cxT;
        final ptY = matchedTarget[i].dy - cyT;

        sxx += psX * ptX;
        sxy += psX * ptY;
        syx += psY * ptX;
        syy += psY * ptY;
      }

      final dTheta = math.atan2(sxy - syx, sxx + syy);
      final dx = cxT - (cxS * math.cos(dTheta) - cyS * math.sin(dTheta));
      final dy = cyT - (cxS * math.sin(dTheta) + cyS * math.cos(dTheta));

      final newTotalDx = math.cos(dTheta) * totalDx - math.sin(dTheta) * totalDy + dx;
      final newTotalDy = math.sin(dTheta) * totalDx + math.cos(dTheta) * totalDy + dy;
      
      totalDx = newTotalDx;
      totalDy = newTotalDy;
      totalDTheta += dTheta;

      sourcePts = _transformPoints(sourcePts, dx, dy, dTheta);
    }

    return IcpTransform(totalDx, totalDy, totalDTheta, true);
  }

  /// Runs ICP to align a single laser scan against the OccupancyGrid map.
  /// Treats cells with value >= 50 as target obstacles.
  /// Returns the correction (dx, dy, dtheta) to apply to initialPose.
  static IcpTransform matchToGrid({
    required LidarScan source,
    required double initialX,
    required double initialY,
    required double initialHeading,
    required dynamic grid, // OccupancyGrid
  }) {
    var sourcePts = _toCartesian(source);
    if (sourcePts.length < 10) return const IcpTransform(0, 0, 0, false);

    // Initial guess is already applied in the transform loop, so we track deviations from the initial pose.
    double totalDx = 0.0;
    double totalDy = 0.0;
    double totalDTheta = 0.0;

    double lastError = double.infinity;
    const int searchRadiusCells = 8; // 8 * 50mm = 400mm search radius

    // Cache the cell access constants
    const int cellSize = 50; // kCellSizeMm
    const int origin = 150; // kOriginCell
    const int gridSize = 300; // kGridSize
    final cells = grid.cells as List<List<int>>;

    for (int iter = 0; iter < 10; iter++) { // maxIterations
      final matchedSource = <Offset>[];
      final matchedTarget = <Offset>[];
      double currentError = 0;

      final currentH = initialHeading + totalDTheta;
      final currentX = initialX + totalDx;
      final currentY = initialY + totalDy;

      final cosH = math.cos(currentH);
      final sinH = math.sin(currentH);

      for (final s in sourcePts) {
        // Transform local scan point to world coordinate given current pose estimate
        final wX = currentX + s.dx * cosH - s.dy * sinH;
        final wY = currentY + s.dx * sinH + s.dy * cosH;

        final cx = (origin + wX / cellSize).round().clamp(0, gridSize - 1);
        final cy = (origin + wY / cellSize).round().clamp(0, gridSize - 1);

        // Search local neighborhood in the grid for nearest occupied cell
        final minX = math.max(0, cx - searchRadiusCells);
        final maxX = math.min(gridSize - 1, cx + searchRadiusCells);
        final minY = math.max(0, cy - searchRadiusCells);
        final maxY = math.min(gridSize - 1, cy + searchRadiusCells);

        double minAnchorDistSq = double.infinity;
        int bestAnchorX = -1;
        int bestAnchorY = -1;
        
        double minOccDistSq = double.infinity;
        int bestOccX = -1;
        int bestOccY = -1;

        for (int y = minY; y <= maxY; y++) {
          for (int x = minX; x <= maxX; x++) {
            final v = cells[y][x];
            if (v >= 50) {
              final cellWorldX = (x - origin) * cellSize.toDouble();
              final cellWorldY = (y - origin) * cellSize.toDouble();
              final dx = cellWorldX - wX;
              final dy = cellWorldY - wY;
              final dSq = dx * dx + dy * dy;

              if (v >= 200) { // High confidence anchor
                if (dSq < minAnchorDistSq) {
                  minAnchorDistSq = dSq;
                  bestAnchorX = x;
                  bestAnchorY = y;
                }
              } else { // Normal occupancy
                if (dSq < minOccDistSq) {
                  minOccDistSq = dSq;
                  bestOccX = x;
                  bestOccY = y;
                }
              }
            }
          }
        }

        // Priority: Match to anchor if available, else match to occupancy
        bool hasMatch = false;
        double matchDistSq = double.infinity;
        int matchX = -1;
        int matchY = -1;

        if (bestAnchorX != -1) {
          hasMatch = true;
          matchDistSq = minAnchorDistSq;
          matchX = bestAnchorX;
          matchY = bestAnchorY;
        } else if (bestOccX != -1) {
          hasMatch = true;
          matchDistSq = minOccDistSq;
          matchX = bestOccX;
          matchY = bestOccY;
        }

        if (hasMatch && matchDistSq < _maxPointDistMm * _maxPointDistMm) {
          // Add raw local source point
          matchedSource.add(s);
          // Calculate where the target point is in the robot's local frame
          final tWorldX = (matchX - origin) * cellSize.toDouble();
          final tWorldY = (matchY - origin) * cellSize.toDouble();
          
          final dWorldX = tWorldX - initialX;
          final dWorldY = tWorldY - initialY;
          
          // Target point translated back to robot's local origin (using INITIAL heading for base frame)
          final initialCos = math.cos(-initialHeading);
          final initialSin = math.sin(-initialHeading);
          
          final tLocalX = dWorldX * initialCos - dWorldY * initialSin;
          final tLocalY = dWorldX * initialSin + dWorldY * initialCos;

          matchedTarget.add(Offset(tLocalX, tLocalY));
          currentError += math.sqrt(matchDistSq);
        }
      }

      if (matchedSource.length < 10) break;
      currentError /= matchedSource.length;

      if ((lastError - currentError).abs() < _minErrorDelta) break;
      lastError = currentError;

      // Calculate SVD/least-squares transform from matchedSource -> matchedTarget
      double cxS = 0, cyS = 0, cxT = 0, cyT = 0;
      final len = matchedSource.length;
      for (int i = 0; i < len; i++) {
        cxS += matchedSource[i].dx;
        cyS += matchedSource[i].dy;
        cxT += matchedTarget[i].dx;
        cyT += matchedTarget[i].dy;
      }
      cxS /= len; cyS /= len;
      cxT /= len; cyT /= len;

      double sxx = 0, sxy = 0, syx = 0, syy = 0;
      for (int i = 0; i < len; i++) {
        final psX = matchedSource[i].dx - cxS;
        final psY = matchedSource[i].dy - cyS;
        final ptX = matchedTarget[i].dx - cxT;
        final ptY = matchedTarget[i].dy - cyT;

        sxx += psX * ptX;
        sxy += psX * ptY;
        syx += psY * ptX;
        syy += psY * ptY;
      }

      final dTheta = math.atan2(sxy - syx, sxx + syy);
      final dxLocal = cxT - (cxS * math.cos(dTheta) - cyS * math.sin(dTheta));
      final dyLocal = cyT - (cxS * math.sin(dTheta) + cyS * math.cos(dTheta));

      // We apply this local correction to the overall transform estimate
      // Since matchedTarget is relative to initialPose, the resulting (dx, dy, dtheta) 
      // is the total cumulative correction to apply to initialPose.
      totalDx = dxLocal * math.cos(initialHeading) - dyLocal * math.sin(initialHeading);
      totalDy = dxLocal * math.sin(initialHeading) + dyLocal * math.cos(initialHeading);
      totalDTheta = dTheta;
    }

    return IcpTransform(totalDx, totalDy, totalDTheta, true);
  }

  static List<Offset> _toCartesian(LidarScan scan, {int step = 3}) {
    final pts = <Offset>[];
    final valid = scan.validPoints;
    for (int i = 0; i < valid.length; i += step) {
      final pt = valid[i];
      final rad = pt.angleDeg * math.pi / 180.0;
      pts.add(Offset(
        pt.distanceMm * math.cos(-rad),
        pt.distanceMm * math.sin(-rad),
      ));
    }
    return pts;
  }

  static List<Offset> _transformPoints(List<Offset> pts, double dx, double dy, double dt) {
    final cosT = math.cos(dt);
    final sinT = math.sin(dt);
    return pts.map((p) => Offset(
      p.dx * cosT - p.dy * sinT + dx,
      p.dx * sinT + p.dy * cosT + dy,
    )).toList();
  }
}
