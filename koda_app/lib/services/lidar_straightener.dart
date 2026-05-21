import 'dart:math' as math;
import 'dart:ui';
import 'lidar_service.dart';

class LidarStraightener {
  // Proximity threshold to group consecutive valid points into clusters (in mm)
  static const double proximityThresholdMm = 250.0;
  
  // Maximum deviation in mm before splitting a segment in Split-and-Merge
  static const double splitThresholdMm = 80.0;
  
  // Minimum number of points in a segment to apply straightening
  static const int minPointsPerSegment = 5;

  /// Straightens the curves in LidarScan caused by Time-of-Flight beam divergence on flat walls.
  static LidarScan straightenScan(LidarScan scan) {
    final validPoints = scan.validPoints;
    if (validPoints.length < minPointsPerSegment) {
      return scan;
    }

    // 1. Sort points by angle to ensure sequential order in rotation
    final sortedPts = List<LidarPoint>.from(validPoints)
      ..sort((a, b) => a.angleDeg.compareTo(b.angleDeg));

    // 2. Convert sorted points to Cartesian coordinates (in robot frame)
    final cartesianPts = List<Offset>.generate(sortedPts.length, (i) {
      final pt = sortedPts[i];
      final rad = pt.angleDeg * math.pi / 180.0;
      return Offset(
        pt.distanceMm * math.cos(-rad),
        pt.distanceMm * math.sin(-rad),
      );
    });

    // 3. Cluster points based on distance between consecutive points
    final clusters = <List<int>>[];
    var currentCluster = <int>[0];

    for (int i = 1; i < sortedPts.length; i++) {
      final p1 = cartesianPts[i - 1];
      final p2 = cartesianPts[i];
      final dx = p2.dx - p1.dx;
      final dy = p2.dy - p1.dy;
      final distSq = dx * dx + dy * dy;

      if (distSq < proximityThresholdMm * proximityThresholdMm) {
        currentCluster.add(i);
      } else {
        if (currentCluster.length >= minPointsPerSegment) {
          clusters.add(currentCluster);
        }
        currentCluster = [i];
      }
    }
    if (currentCluster.length >= minPointsPerSegment) {
      clusters.add(currentCluster);
    }

    // Initialize output coordinates with original Cartesian coordinates
    final outputCartesian = List<Offset>.from(cartesianPts);

    // 4. Run Split-and-Merge on each cluster to find straight segments, and project them
    for (final cluster in clusters) {
      final segments = <List<int>>[];
      _splitAndMergeRecursive(
        cartesianPts,
        cluster.first,
        cluster.last,
        splitThresholdMm,
        segments,
      );

      for (final seq in segments) {
        final startIdx = seq[0];
        final endIdx = seq[1];
        final count = endIdx - startIdx + 1;

        if (count >= minPointsPerSegment) {
          _projectSegmentToBestFitLine(cartesianPts, startIdx, endIdx, outputCartesian);
        }
      }
    }

    // 5. Re-convert corrected Cartesian coordinates back to polar coordinates
    final straightenedPoints = List<LidarPoint>.generate(sortedPts.length, (i) {
      final orig = sortedPts[i];
      final corrected = outputCartesian[i];
      
      final dist = math.sqrt(corrected.dx * corrected.dx + corrected.dy * corrected.dy);
      // If the projected point is somehow invalid or near-zero, keep the original distance
      if (dist < 10.0) {
        return orig;
      }
      
      final theta = math.atan2(-corrected.dy, corrected.dx);
      var angle = theta * 180.0 / math.pi;
      if (angle < 0) angle += 360.0;
      
      return LidarPoint(angleDeg: angle, distanceMm: dist);
    });

    // 6. Return a new LidarScan with the straightened points
    return scan.copyWithPoints(straightenedPoints);
  }

  static void _splitAndMergeRecursive(
    List<Offset> pts,
    int start,
    int end,
    double threshold,
    List<List<int>> segments,
  ) {
    if (end - start < 2) {
      segments.add([start, end]);
      return;
    }

    final pStart = pts[start];
    final pEnd = pts[end];

    final A = pEnd.dy - pStart.dy;
    final B = pStart.dx - pEnd.dx;
    final C = pEnd.dx * pStart.dy - pStart.dx * pEnd.dy;
    final len = math.sqrt(A * A + B * B);

    double maxDist = 0.0;
    int maxIndex = -1;

    if (len > 1e-6) {
      for (int i = start + 1; i < end; i++) {
        final p = pts[i];
        final dist = (A * p.dx + B * p.dy + C).abs() / len;
        if (dist > maxDist) {
          maxDist = dist;
          maxIndex = i;
        }
      }
    }

    if (maxIndex != -1 && maxDist > threshold) {
      _splitAndMergeRecursive(pts, start, maxIndex, threshold, segments);
      _splitAndMergeRecursive(pts, maxIndex, end, threshold, segments);
    } else {
      segments.add([start, end]);
    }
  }

  static void _projectSegmentToBestFitLine(
    List<Offset> pts,
    int start,
    int end,
    List<Offset> outputPts,
  ) {
    final count = end - start + 1;
    if (count < 2) return;

    // 1. Calculate Centroid
    double sumX = 0.0;
    double sumY = 0.0;
    for (int i = start; i <= end; i++) {
      sumX += pts[i].dx;
      sumY += pts[i].dy;
    }
    final cx = sumX / count;
    final cy = sumY / count;

    // 2. Calculate Covariance Matrix Elements
    double covXX = 0.0;
    double covYY = 0.0;
    double covXY = 0.0;
    for (int i = start; i <= end; i++) {
      final dx = pts[i].dx - cx;
      final dy = pts[i].dy - cy;
      covXX += dx * dx;
      covYY += dy * dy;
      covXY += dx * dy;
    }
    covXX /= count;
    covYY /= count;
    covXY /= count;

    // 3. Find Angle of Best-Fit Line (Principal Eigenvector Angle)
    final theta = 0.5 * math.atan2(2 * covXY, covXX - covYY);
    final cosT = math.cos(theta);
    final sinT = math.sin(theta);

    // 4. Project points orthogonally onto this line
    for (int i = start; i <= end; i++) {
      final dx = pts[i].dx - cx;
      final dy = pts[i].dy - cy;
      final proj = dx * cosT + dy * sinT;
      outputPts[i] = Offset(cx + proj * cosT, cy + proj * sinT);
    }
  }
}
