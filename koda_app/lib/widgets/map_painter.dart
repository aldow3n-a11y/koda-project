import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../services/slam_service.dart';
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
  final Future<void> Function() onSave;
  final SlamMode slamMode;
  final int bootstrapSecsLeft;
  final bool hasSavedMap;

  const LidarMapCard({
    super.key,
    required this.slam,
    required this.isReceiving,
    required this.pointCount,
    required this.revision,
    required this.onReset,
    required this.onSave,
    required this.slamMode,
    required this.bootstrapSecsLeft,
    required this.hasSavedMap,
  });

  @override
  State<LidarMapCard> createState() => _LidarMapCardState();
}

class _LidarMapCardState extends State<LidarMapCard> {
  final TransformationController _transformCtrl = TransformationController();
  bool _initialized = false;

  // Resizable height
  double _mapHeight = 280.0;
  static const double _minHeight = 160.0;
  static const double _maxHeight = 600.0;

  // Edge scroll threshold — start scrolling when robot within this many px of edge
  static const double _edgeThreshold = 80.0;

  @override
  void didUpdateWidget(LidarMapCard old) {
    super.didUpdateWidget(old);
    // Check if robot moved (revision changed) — may need to scroll
    if (old.revision != widget.revision) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeScrollToRobot());
    }
  }

  /// Returns robot position in viewport coordinates, accounting for pan + zoom
  Offset _robotInViewport() {
    final m = _transformCtrl.value;
    final robotPx = _worldToPx(widget.slam.pose.xMm, widget.slam.pose.yMm);
    // m is a 4x4 matrix: scale in entry(0,0)/entry(1,1), translate in entry(0,3)/entry(1,3)
    final scaleX = m.entry(0, 0);
    final scaleY = m.entry(1, 1);
    return Offset(
      robotPx.dx * scaleX + m.entry(0, 3),
      robotPx.dy * scaleY + m.entry(1, 3),
    );
  }

  Offset _worldToPx(double xMm, double yMm) {
    final xIdx = kOriginCell + xMm / kCellSizeMm;
    final yIdx = kOriginCell + yMm / kCellSizeMm;
    final px = (kGridSize - 1 - yIdx) * OccupancyMapPainter.cellPx;
    final py = (kGridSize - 1 - xIdx) * OccupancyMapPainter.cellPx;
    return Offset(px, py);
  }

  void _initCenter(double vpWidth, double vpHeight) {
    final robotPx = _worldToPx(widget.slam.pose.xMm, widget.slam.pose.yMm);
    _transformCtrl.value = Matrix4.identity()
      ..translate(vpWidth / 2 - robotPx.dx, vpHeight / 2 - robotPx.dy);
  }

  @override
  void dispose() {
    _transformCtrl.dispose();
    super.dispose();
  }

  void _maybeScrollToRobot() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;

    final vpWidth  = box.size.width;
    final vpHeight = _mapHeight;
    final robotVp  = _robotInViewport();

    // Scale scroll step inversely with zoom — at 2× zoom, step is 80px in world space
    final scale = _transformCtrl.value.entry(0, 0).clamp(0.3, 5.0);
    final scrollStep = 40.0 * scale;

    double dx = 0, dy = 0;

    if (robotVp.dx < _edgeThreshold)              dx =  scrollStep;
    if (robotVp.dx > vpWidth  - _edgeThreshold)   dx = -scrollStep;
    if (robotVp.dy < _edgeThreshold)              dy =  scrollStep;
    if (robotVp.dy > vpHeight - _edgeThreshold)   dy = -scrollStep;

    if (dx != 0 || dy != 0) {
      final current = _transformCtrl.value.clone();
      current.translate(dx / scale, dy / scale);
      _transformCtrl.value = current;
    }
  }

  Widget _toolBtn({
    required Widget child,
    required VoidCallback onTap,
    required String label,
    Color color = KodaColors.dim,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minWidth: 52, minHeight: 52),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            child,
            const SizedBox(height: 3),
            Text(label, style: monoStyle(size: 8, color: color)),
          ],
        ),
      ),
    );
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
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              children: [
                Text('LIDAR MAP',
                    style: monoStyle(size: 11, color: KodaColors.amber, spacing: 2)),
                const SizedBox(width: 8),
                // Mode badge
                _ModeBadge(
                  slamMode: widget.slamMode,
                  secsLeft: widget.bootstrapSecsLeft,
                  isReceiving: widget.isReceiving,
                ),
                const Spacer(),
                // Pose readout
                Text(
                  'x:${widget.slam.pose.xMm.toStringAsFixed(0)} '
                  'y:${widget.slam.pose.yMm.toStringAsFixed(0)} '
                  'θ:${(widget.slam.pose.heading * 180 / math.pi).toStringAsFixed(0)}°  '
                  '${widget.pointCount}pts',
                  style: monoStyle(size: 9, color: KodaColors.sub),
                ),
                const SizedBox(width: 8),
                // Save button — only visible in mapping mode
                if (widget.slamMode == SlamMode.mapping)
                  GestureDetector(
                    onTap: () async {
                      await widget.onSave();
                      setState(() {}); // refresh hasSavedMap indicator
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: KodaColors.green.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: KodaColors.green.withValues(alpha: 0.4)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.save, size: 12, color: KodaColors.green),
                          const SizedBox(width: 4),
                          Text('SAVE', style: monoStyle(size: 9, color: KodaColors.green)),
                        ],
                      ),
                    ),
                  ),
                if (widget.hasSavedMap && widget.slamMode != SlamMode.mapping) ...[
                  const Icon(Icons.check_circle, size: 12, color: KodaColors.green),
                  const SizedBox(width: 4),
                  Text('SAVED', style: monoStyle(size: 9, color: KodaColors.green)),
                ],
              ],
            ),
          ),

          // ── Bootstrap progress bar ────────────────────────────────────────
          if (widget.slamMode == SlamMode.bootstrap)
            _BootstrapBar(secsLeft: widget.bootstrapSecsLeft),

          const Divider(height: 1, color: KodaColors.border),

          // ── Map canvas — auto-scrolls when robot near edge ───────────────
          ClipRect(
            child: SizedBox(
              height: _mapHeight,
              width: double.infinity,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (!_initialized) {
                    _initialized = true;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _initCenter(constraints.maxWidth, constraints.maxHeight);
                    });
                  }
                  // InteractiveViewer with user interaction disabled —
                  // only _maybeScrollToRobot() moves the transform
                  return InteractiveViewer(
                    transformationController: _transformCtrl,
                    constrained: false,
                    minScale: 0.3,
                    maxScale: 5.0,
                    panEnabled: true,
                    scaleEnabled: true,
                    child: CustomPaint(
                      painter: OccupancyMapPainter(
                        grid: widget.slam.grid,
                        pose: widget.slam.pose,
                        revision: widget.revision,
                      ),
                      size: const Size(
                          OccupancyMapPainter.mapSize, OccupancyMapPainter.mapSize),
                    ),
                  );
                },
              ),
            ),
          ),

          // ── Resize handle ─────────────────────────────────────────────────
          GestureDetector(
            onVerticalDragUpdate: (details) {
              setState(() {
                _mapHeight = (_mapHeight + details.delta.dy)
                    .clamp(_minHeight, _maxHeight);
              });
            },
            child: Container(
              height: 18,
              color: KodaColors.bg,
              child: Center(
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                    color: KodaColors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ),

          const Divider(height: 1, color: KodaColors.border),

          // ── Bottom toolbar ────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [

                _toolBtn(
                  label: 'RESET',
                  color: KodaColors.red,
                  onTap: () {
                    widget.onReset();
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      final box = context.findRenderObject() as RenderBox?;
                      if (box != null) _initCenter(box.size.width, _mapHeight);
                    });
                  },
                  child: const Icon(Icons.refresh, size: 24, color: KodaColors.red),
                ),

                _toolBtn(
                  label: '-7.5°',
                  color: KodaColors.amber,
                  onTap: () {
                    widget.slam.adjustHeading(-math.pi / 24);
                    setState(() {});
                  },
                  child: const Icon(Icons.rotate_left, size: 28, color: KodaColors.amber),
                ),

                _toolBtn(
                  label: '+7.5°',
                  color: KodaColors.amber,
                  onTap: () {
                    widget.slam.adjustHeading(math.pi / 24);
                    setState(() {});
                  },
                  child: const Icon(Icons.rotate_right, size: 28, color: KodaColors.amber),
                ),

                _toolBtn(
                  label: '-1°',
                  color: KodaColors.sub,
                  onTap: () {
                    widget.slam.adjustHeading(-math.pi / 180);
                    setState(() {});
                  },
                  child: const Icon(Icons.chevron_left, size: 24, color: KodaColors.sub),
                ),

                _toolBtn(
                  label: '+1°',
                  color: KodaColors.sub,
                  onTap: () {
                    widget.slam.adjustHeading(math.pi / 180);
                    setState(() {});
                  },
                  child: const Icon(Icons.chevron_right, size: 24, color: KodaColors.sub),
                ),

              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Mode Badge ───────────────────────────────────────────────────────────────

class _ModeBadge extends StatelessWidget {
  final SlamMode slamMode;
  final int secsLeft;
  final bool isReceiving;

  const _ModeBadge({
    required this.slamMode,
    required this.secsLeft,
    required this.isReceiving,
  });

  @override
  Widget build(BuildContext context) {
    Color color;
    String label;

    switch (slamMode) {
      case SlamMode.bootstrap:
        color = KodaColors.amber;
        label = 'ANCHOR ${secsLeft}s';
      case SlamMode.mapping:
        color = isReceiving ? KodaColors.green : KodaColors.dim;
        label = isReceiving ? 'MAPPING' : 'NO SIGNAL';
      case SlamMode.navigation:
        color = isReceiving ? KodaColors.blue : KodaColors.dim;
        label = isReceiving ? 'NAV LIVE' : 'NAV OFFLINE';
      case SlamMode.idle:
        color = KodaColors.dim;
        label = 'IDLE';
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6, height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(label, style: monoStyle(size: 9, color: color)),
      ],
    );
  }
}

// ─── Bootstrap Progress Bar ───────────────────────────────────────────────────

class _BootstrapBar extends StatelessWidget {
  final int secsLeft;
  static const int _total = 10;

  const _BootstrapBar({required this.secsLeft});

  @override
  Widget build(BuildContext context) {
    final progress = (_total - secsLeft) / _total;
    return Container(
      height: 24,
      color: KodaColors.bg,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      child: Row(
        children: [
          Text('BUILDING ANCHOR',
              style: monoStyle(size: 8, color: KodaColors.amber, spacing: 1)),
          const SizedBox(width: 8),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: progress,
                backgroundColor: KodaColors.border,
                color: KodaColors.amber,
                minHeight: 4,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text('${secsLeft}s',
              style: monoStyle(size: 8, color: KodaColors.amber)),
          const SizedBox(width: 4),
          Text('KEEP KODA STILL',
              style: monoStyle(size: 8, color: KodaColors.dim)),
        ],
      ),
    );
  }
}
