import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../services/slam_service.dart';
import '../services/lidar_service.dart';
import '../theme/koda_theme.dart';

// ─── Occupancy Map Painter ────────────────────────────────────────────────────

class OccupancyMapPainter extends CustomPainter {
  final OccupancyGrid grid;
  final RobotPose pose;
  final int revision;

  static const double cellPx = 3.0; // 300 cells * 3 = 900px map size
  static const double mapSize = kGridSize * cellPx;

  OccupancyMapPainter({
    required this.grid,
    required this.pose,
    required this.revision,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // ── Draw cells ──────────────────────────────────────────────────────────
    // Unknown = transparent, Free = blue, Occupied = thick bright cyan
    final freePaint = Paint()..color = const Color(0xFF324F69); // Roborock style
    final occupiedPaint = Paint()
      ..color = const Color(0xFF86D5FD)
      ..style = PaintingStyle.fill;

    for (int xIdx = 0; xIdx < kGridSize; xIdx++) {
      for (int yIdx = 0; yIdx < kGridSize; yIdx++) {
        final val = grid.cells[yIdx][xIdx];
        if (val == -1) continue;

        // Map world +x (forward) to -py (UP), world +y (left) to -px (LEFT)
        final px = (kGridSize - 1 - yIdx) * cellPx;
        final py = (kGridSize - 1 - xIdx) * cellPx;

        if (val >= 0 && val < 50) {
          canvas.drawRect(Rect.fromLTWH(px, py, cellPx + 0.5, cellPx + 0.5), freePaint);
        } else if (val >= 50) {
          // Draw occupied as slightly overflowing for thick continuous walls
          canvas.drawRect(Rect.fromLTWH(px - 1, py - 1, cellPx + 2, cellPx + 2), occupiedPaint);
        }
      }
    }

    // ── Robot marker ───────────────────────────────────────────────────────
    final robotPx = _worldToPx(pose.xMm, pose.yMm);
    _drawRobotArrow(canvas, robotPx, pose.heading, cellPx * 4);
  }

  Offset _worldToPx(double xMm, double yMm) {
    final xIdx = kOriginCell + xMm / kCellSizeMm;
    final yIdx = kOriginCell + yMm / kCellSizeMm;
    
    // Exact same mapping as the cell loop
    final px = (kGridSize - 1 - yIdx) * cellPx;
    final py = (kGridSize - 1 - xIdx) * cellPx;
    return Offset(px, py);
  }

  void _drawRobotArrow(Canvas canvas, Offset center, double heading, double size) {
    final screenAngle = -heading - math.pi / 2;

    final path = Path();
    final tip  = Offset(center.dx + size * math.cos(screenAngle),
                        center.dy + size * math.sin(screenAngle));
    final left = Offset(center.dx + size * 0.5 * math.cos(screenAngle + 2.4),
                        center.dy + size * 0.5 * math.sin(screenAngle + 2.4));
    final right= Offset(center.dx + size * 0.5 * math.cos(screenAngle - 2.4),
                        center.dy + size * 0.5 * math.sin(screenAngle - 2.4));
    path
      ..moveTo(tip.dx,   tip.dy)
      ..lineTo(left.dx,  left.dy)
      ..lineTo(right.dx, right.dy)
      ..close();

    // Glow
    canvas.drawCircle(center, size * 0.7,
        Paint()..color = Colors.white.withValues(alpha: 0.15));
    canvas.drawPath(path, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(OccupancyMapPainter old) =>
      old.revision != revision || old.pose.xMm != pose.xMm ||
      old.pose.yMm != pose.yMm || old.pose.heading != pose.heading;
}

// ─── Map Card Widget ──────────────────────────────────────────────────────────

class LidarMapCard extends StatefulWidget {
  final SlamService slam;
  final bool isReceiving;
  final int pointCount;
  final int revision;
  final VoidCallback onReset;

  const LidarMapCard({
    super.key,
    required this.slam,
    required this.isReceiving,
    required this.pointCount,
    required this.revision,
    required this.onReset,
  });

  @override
  State<LidarMapCard> createState() => _LidarMapCardState();
}

class _LidarMapCardState extends State<LidarMapCard> {
  final TransformationController _transformCtrl = TransformationController();
  bool _initialized = false;

  void _centerMap(double viewportWidth, double viewportHeight) {
    // Current robot pos in pixels
    final xIdx = kOriginCell + widget.slam.pose.xMm / kCellSizeMm;
    final yIdx = kOriginCell + widget.slam.pose.yMm / kCellSizeMm;
    
    final rx = (kGridSize - 1 - yIdx) * OccupancyMapPainter.cellPx;
    final ry = (kGridSize - 1 - xIdx) * OccupancyMapPainter.cellPx;

    final mx = viewportWidth / 2 - rx;
    final my = viewportHeight / 2 - ry;

    _transformCtrl.value = Matrix4.identity()..translate(mx, my);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: KodaColors.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: KodaColors.border2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ───────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Text('LIDAR MAP', style: monoStyle(size: 11, color: KodaColors.amber, spacing: 2)),
                const Spacer(),
                Container(
                  width: 6, height: 6,
                  margin: const EdgeInsets.only(right: 4),
                  decoration: BoxDecoration(
                    color: widget.isReceiving ? KodaColors.green : KodaColors.dim,
                    shape: BoxShape.circle,
                  ),
                ),
                Text(
                  widget.isReceiving ? 'LIVE' : 'NO SIGNAL',
                  style: monoStyle(size: 9, color: widget.isReceiving ? KodaColors.green : KodaColors.dim),
                ),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: () {
                    widget.onReset();
                    final size = context.size;
                    if (size != null) _centerMap(size.width, 220);
                  },
                  child: Text('RESET', style: monoStyle(size: 9, color: KodaColors.dim)),
                ),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: () {
                    final size = context.size;
                    // Reset view to robot exact center
                    if (size != null) _centerMap(size.width, 220);
                  },
                  child: const Icon(Icons.my_location, size: 16, color: KodaColors.dim),
                ),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: () => widget.slam.adjustHeading(-math.pi / 24), // -7.5 deg
                  child: const Icon(Icons.rotate_left, size: 18, color: KodaColors.amber),
                ),
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: () => widget.slam.adjustHeading(math.pi / 24), // +7.5 deg
                  child: const Icon(Icons.rotate_right, size: 18, color: KodaColors.amber),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: KodaColors.border),

          // ── Map canvas ───────────────────────────────────────────────────
          ClipRRect(
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(0)),
            child: SizedBox(
              height: 220,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (!_initialized) {
                    _initialized = true;
                    // Wait for initial render to calculate center properly
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                       _centerMap(constraints.maxWidth, constraints.maxHeight);
                    });
                  }
                  return InteractiveViewer(
                    transformationController: _transformCtrl,
                    constrained: false, // Core instruction: unlocks panning!
                    minScale: 0.1,
                    maxScale: 10.0,
                    child: CustomPaint(
                      painter: OccupancyMapPainter(
                        grid: widget.slam.grid,
                        pose: widget.slam.pose,
                        revision: widget.revision,
                      ),
                      size: const Size(OccupancyMapPainter.mapSize, OccupancyMapPainter.mapSize),
                    ),
                  );
                }
              ),
            ),
          ),

          // ── Status strip ─────────────────────────────────────────────────
          const Divider(height: 1, color: KodaColors.border),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            child: Row(
              children: [
                Text(
                  'x:${widget.slam.pose.xMm.toStringAsFixed(0)}mm  '
                  'y:${widget.slam.pose.yMm.toStringAsFixed(0)}mm  '
                  'θ:${(widget.slam.pose.heading * 180 / math.pi).toStringAsFixed(1)}°',
                  style: monoStyle(size: 9, color: KodaColors.sub),
                ),
                const Spacer(),
                Text(
                  '${widget.pointCount} pts',
                  style: monoStyle(size: 9, color: KodaColors.dim),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
