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

  static List<Offset> _toCartesian(LidarScan scan) {
    return scan.validPoints.map((pt) {
      final rad = pt.angleDeg * math.pi / 180.0;
      return Offset(
        pt.distanceMm * math.cos(-rad),
        pt.distanceMm * math.sin(-rad),
      );
    }).toList();
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
