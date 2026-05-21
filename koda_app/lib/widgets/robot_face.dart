import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/models.dart';
import '../providers/providers.dart';

class RobotFaceOverlay extends ConsumerStatefulWidget {
  final RobotEmotion emotion;
  
  const RobotFaceOverlay({
    super.key, 
    required this.emotion,
  });

  @override
  ConsumerState<RobotFaceOverlay> createState() => _RobotFaceOverlayState();
}

class _RobotFaceOverlayState extends ConsumerState<RobotFaceOverlay> with TickerProviderStateMixin {
  late AnimationController _loopController;
  late AnimationController _blinkController;
  
  // Drift look offset for the pupils/look direction
  Offset _lookOffset = Offset.zero;
  Offset _targetLookOffset = Offset.zero;
  Timer? _driftTimer;
  late AnimationController _driftController;
  late Animation<Offset> _driftAnimation;

  // Smoothed active look offset
  Offset _currentLookOffset = Offset.zero;

  @override
  void initState() {
    super.initState();
    
    // 1. Loop controller for continuous animations (spirals, breathing, waving hands)
    _loopController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();

    // 2. Blink controller (standard single/double blink duration)
    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );
    _scheduleBlink();

    // 3. Drift controller for looking around
    _driftController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _driftAnimation = Tween<Offset>(begin: Offset.zero, end: Offset.zero).animate(
      CurvedAnimation(parent: _driftController, curve: Curves.easeInOut),
    );
    _scheduleDrift();
  }

  void _scheduleBlink() {
    if (!mounted) return;
    final delay = 2500 + Random().nextInt(3500);
    Future.delayed(Duration(milliseconds: delay), () {
      if (!mounted) return;
      
      // 15% chance of double blink
      final isDouble = Random().nextDouble() < 0.18;
      
      _blinkController.forward().then((_) {
        _blinkController.reverse().then((_) {
          if (isDouble) {
            Future.delayed(const Duration(milliseconds: 70), () {
              if (!mounted) return;
              _blinkController.forward().then((_) {
                _blinkController.reverse().then((_) => _scheduleBlink());
              });
            });
          } else {
            _scheduleBlink();
          }
        });
      });
    });
  }

  void _scheduleDrift() {
    if (!mounted) return;
    final delay = 2000 + Random().nextInt(4000);
    _driftTimer = Timer(Duration(milliseconds: delay), () {
      if (!mounted) return;
      
      // Decide if we should look in a direction, or reset to center
      if (Random().nextDouble() < 0.3) {
        _targetLookOffset = Offset.zero;
      } else {
        // Pick random looking target offset
        final randX = (Random().nextDouble() - 0.5) * 22.0;
        final randY = (Random().nextDouble() - 0.5) * 10.0;
        _targetLookOffset = Offset(randX, randY);
      }
      
      _driftAnimation = Tween<Offset>(
        begin: _lookOffset,
        end: _targetLookOffset,
      ).animate(
        CurvedAnimation(parent: _driftController, curve: Curves.easeInOut),
      );
      
      _driftController.forward(from: 0.0).then((_) {
        _lookOffset = _targetLookOffset;
        _scheduleDrift();
      });
    });
  }

  @override
  void didUpdateWidget(covariant RobotFaceOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.emotion != oldWidget.emotion) {
      // Trigger a quick blink and look reset on emotion change
      _blinkController.forward().then((_) => _blinkController.reverse());
      _driftController.stop();
      setState(() {
        _lookOffset = Offset.zero;
        _targetLookOffset = Offset.zero;
      });
    }
  }

  @override
  void dispose() {
    _loopController.dispose();
    _blinkController.dispose();
    _driftController.dispose();
    _driftTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_loopController, _blinkController, _driftController]),
      builder: (context, child) {
        final blinkProgress = _blinkController.value;
        final driftOffset = _driftController.isAnimating ? _driftAnimation.value : _lookOffset;
        final animationValue = _loopController.value;
        
        // 1. Get target look offset from cognition layer if active, else use standard drift
        final cognition = ref.watch(cognitionProvider);
        final targetOffset = (cognition.attentionTarget != Offset.zero) ? cognition.attentionTarget : driftOffset;
        
        // 2. Smoothly LERP the eyes' look direction (12% shift per frame)
        _currentLookOffset = Offset.lerp(_currentLookOffset, targetOffset, 0.12)!;
        
        // Calculate slow breathing scale (2.5% variation)
        final breatheScale = 1.0 + 0.025 * sin(animationValue * 2 * pi);

        return IgnorePointer(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Center features: Eyes, Eyebrows, Mouth
              Center(
                child: Transform.scale(
                  scale: breatheScale,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Row of eyes
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _Eye(
                            isLeft: true,
                            emotion: widget.emotion,
                            blinkProgress: blinkProgress,
                            lookOffset: _currentLookOffset,
                            animationValue: animationValue,
                          ),
                          const SizedBox(width: 80),
                          _Eye(
                            isLeft: false,
                            emotion: widget.emotion,
                            blinkProgress: blinkProgress,
                            lookOffset: _currentLookOffset,
                            animationValue: animationValue,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _Mouth(
                        emotion: widget.emotion,
                        animationValue: animationValue,
                      ),
                    ],
                  ),
                ),
              ),
              // Hands overlay at edges
              _Hands(
                emotion: widget.emotion,
                animationValue: animationValue,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Eye extends StatelessWidget {
  final bool isLeft;
  final RobotEmotion emotion;
  final double blinkProgress;
  final Offset lookOffset;
  final double animationValue;

  const _Eye({
    required this.isLeft,
    required this.emotion,
    required this.blinkProgress,
    required this.lookOffset,
    required this.animationValue,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 70,
      height: 120,
      child: CustomPaint(
        painter: _EyePainter(
          isLeft: isLeft,
          emotion: emotion,
          blinkProgress: blinkProgress,
          lookOffset: lookOffset,
          animationValue: animationValue,
          color: Colors.cyanAccent,
        ),
      ),
    );
  }
}

class _EyePainter extends CustomPainter {
  final bool isLeft;
  final RobotEmotion emotion;
  final double blinkProgress;
  final Offset lookOffset;
  final double animationValue;
  final Color color;

  _EyePainter({
    required this.isLeft,
    required this.emotion,
    required this.blinkProgress,
    required this.lookOffset,
    required this.animationValue,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double eyeTop = 35.0;
    final double eyeHeight = size.height - eyeTop; // 85.0
    final double eyeWidth = size.width; // 70.0

    // Draw Eyebrow first
    final eyebrowPaint = Paint();
    drawEyebrow(canvas, size, eyebrowPaint, isLeft);

    // Prepare eye paint
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    // Apply blink scaling to the eye height
    final double scaleY = 1.0 - blinkProgress;
    final double centerY = eyeTop + (eyeHeight / 2);
    
    canvas.save();
    canvas.translate(eyeWidth / 2, centerY);
    canvas.scale(1.0, scaleY);
    canvas.translate(-eyeWidth / 2, -centerY);

    final rect = Rect.fromLTWH(0, eyeTop, eyeWidth, eyeHeight);
    
    // Shader for eye gradient
    final gradientShader = LinearGradient(
      colors: [
        Colors.cyanAccent,
        Colors.cyan.shade600,
        Colors.blueAccent,
      ],
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
    ).createShader(rect);

    paint.shader = gradientShader;

    switch (emotion) {
      case RobotEmotion.happy:
        // Upside-down U arch curve
        final archPaint = Paint()
          ..shader = gradientShader
          ..style = PaintingStyle.stroke
          ..strokeWidth = 14
          ..strokeCap = StrokeCap.round;
        final archPath = Path();
        archPath.moveTo(5, eyeTop + eyeHeight * 0.7);
        archPath.quadraticBezierTo(
          eyeWidth / 2, 
          eyeTop + eyeHeight * 0.1, 
          eyeWidth - 5, 
          eyeTop + eyeHeight * 0.7
        );
        canvas.drawPath(archPath, archPaint);
        break;

      case RobotEmotion.sad:
        // Drooping curve downwards
        final archPaint = Paint()
          ..shader = gradientShader
          ..style = PaintingStyle.stroke
          ..strokeWidth = 14
          ..strokeCap = StrokeCap.round;
        final archPath = Path();
        archPath.moveTo(5, eyeTop + eyeHeight * 0.3);
        archPath.quadraticBezierTo(
          eyeWidth / 2, 
          eyeTop + eyeHeight * 0.9, 
          eyeWidth - 5, 
          eyeTop + eyeHeight * 0.3
        );
        canvas.drawPath(archPath, archPaint);
        break;

      case RobotEmotion.excited:
        // Chevron upwards '^'
        final chevronPaint = Paint()
          ..shader = gradientShader
          ..style = PaintingStyle.stroke
          ..strokeWidth = 14
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;
        final chevronPath = Path();
        chevronPath.moveTo(10, eyeTop + eyeHeight * 0.75);
        chevronPath.lineTo(eyeWidth / 2, eyeTop + eyeHeight * 0.25);
        chevronPath.lineTo(eyeWidth - 10, eyeTop + eyeHeight * 0.75);
        canvas.drawPath(chevronPath, chevronPaint);
        break;

      case RobotEmotion.playing:
        // Cross '+' on left, Circle 'O' on right
        final symbolPaint = Paint()
          ..shader = gradientShader
          ..style = PaintingStyle.stroke
          ..strokeWidth = 12
          ..strokeCap = StrokeCap.round;
        if (isLeft) {
          canvas.drawLine(
            Offset(10, eyeTop + eyeHeight / 2),
            Offset(eyeWidth - 10, eyeTop + eyeHeight / 2),
            symbolPaint
          );
          canvas.drawLine(
            Offset(eyeWidth / 2, eyeTop + 10),
            Offset(eyeWidth / 2, eyeTop + eyeHeight - 10),
            symbolPaint
          );
        } else {
          canvas.drawCircle(
            Offset(eyeWidth / 2, eyeTop + eyeHeight / 2),
            min(eyeWidth, eyeHeight) / 2.5,
            symbolPaint
          );
        }
        break;

      case RobotEmotion.wink:
        if (isLeft) {
          // Closed eye: happy arch curve
          final archPaint = Paint()
            ..shader = gradientShader
            ..style = PaintingStyle.stroke
            ..strokeWidth = 12
            ..strokeCap = StrokeCap.round;
          final archPath = Path();
          archPath.moveTo(10, eyeTop + eyeHeight * 0.5);
          archPath.quadraticBezierTo(
            eyeWidth / 2, 
            eyeTop + eyeHeight * 0.8, 
            eyeWidth - 10, 
            eyeTop + eyeHeight * 0.5
          );
          canvas.drawPath(archPath, archPaint);
        } else {
          // Open eye: normal squircle
          final rrect = RRect.fromRectAndRadius(
            Rect.fromLTWH(0, eyeTop, eyeWidth, eyeHeight),
            Radius.circular(eyeWidth / 2),
          );
          canvas.drawRRect(rrect, paint);
          drawPupilAndHighlights(canvas, rect, lookOffset);
        }
        break;

      case RobotEmotion.love:
        // Heart shape
        final heartPath = Path();
        final hw = eyeWidth;
        final hh = eyeHeight;
        final hOffset = eyeTop;
        
        heartPath.moveTo(hw / 2, hOffset + hh * 0.25);
        heartPath.cubicTo(
          hw * 5 / 6, hOffset, 
          hw, hOffset + hh / 3, 
          hw / 2, hOffset + hh * 0.95
        );
        heartPath.cubicTo(
          0, hOffset + hh / 3, 
          hw / 6, hOffset, 
          hw / 2, hOffset + hh * 0.25
        );
        canvas.drawPath(heartPath, paint);
        
        final reflectPaint = Paint()..color = Colors.white.withValues(alpha: 0.65);
        canvas.drawCircle(Offset(hw * 0.35, hOffset + hh * 0.35), 6, reflectPaint);
        break;

      case RobotEmotion.dizzy:
        // Spiral
        final spiralPaint = Paint()
          ..shader = gradientShader
          ..style = PaintingStyle.stroke
          ..strokeWidth = 10
          ..strokeCap = StrokeCap.round;
        final center = Offset(eyeWidth / 2, eyeTop + eyeHeight / 2);
        final spiralPath = Path();
        final maxRadius = min(eyeWidth, eyeHeight) / 2 - 5;
        
        for (double theta = 0; theta < 4.5 * pi; theta += 0.15) {
          final r = (theta / (4.5 * pi)) * maxRadius;
          final angle = theta + animationValue * 2 * pi * (isLeft ? 1 : -1);
          final x = center.dx + r * cos(angle);
          final y = center.dy + r * sin(angle);
          if (theta == 0) {
            spiralPath.moveTo(x, y);
          } else {
            spiralPath.lineTo(x, y);
          }
        }
        canvas.drawPath(spiralPath, spiralPaint);
        break;

      case RobotEmotion.thinking:
        // Narrow squircle looking up/sideways
        final thinkHeight = eyeHeight * 0.45;
        final thinkTop = eyeTop + (eyeHeight - thinkHeight) / 2;
        final rrect = RRect.fromRectAndRadius(
          Rect.fromLTWH(0, thinkTop, eyeWidth, thinkHeight),
          Radius.circular(thinkHeight / 2),
        );
        canvas.drawRRect(rrect, paint);
        
        final thinkRect = Rect.fromLTWH(0, thinkTop, eyeWidth, thinkHeight);
        drawPupilAndHighlights(canvas, thinkRect, lookOffset + const Offset(0, -6));
        break;

      case RobotEmotion.curious:
        // Wide circle
        final diameter = min(eyeWidth, eyeHeight);
        final rrect = RRect.fromRectAndRadius(
          Rect.fromLTWH((eyeWidth - diameter)/2, eyeTop + (eyeHeight - diameter)/2, diameter, diameter),
          Radius.circular(diameter / 2),
        );
        canvas.drawRRect(rrect, paint);
        drawPupilAndHighlights(canvas, Rect.fromLTWH((eyeWidth - diameter)/2, eyeTop + (eyeHeight - diameter)/2, diameter, diameter), lookOffset);
        break;

      case RobotEmotion.surprised:
        // Tall oval
        final rrect = RRect.fromRectAndRadius(
          Rect.fromLTWH(0, eyeTop, eyeWidth, eyeHeight),
          Radius.circular(eyeWidth / 2),
        );
        canvas.drawRRect(rrect, paint);
        drawPupilAndHighlights(canvas, rect, lookOffset * 0.5);
        break;

      case RobotEmotion.neutral:
      default:
        // Standard organic squircle
        final rrect = RRect.fromRectAndRadius(
          Rect.fromLTWH(0, eyeTop, eyeWidth, eyeHeight),
          Radius.circular(eyeWidth / 2.3),
        );
        canvas.drawRRect(rrect, paint);
        drawPupilAndHighlights(canvas, rect, lookOffset);
        break;
    }

    canvas.restore();
  }

  void drawEyebrow(Canvas canvas, Size size, Paint paint, bool isLeft) {
    paint.style = PaintingStyle.stroke;
    paint.strokeWidth = 6;
    paint.color = Colors.cyanAccent.withValues(alpha: 0.9);
    paint.strokeCap = StrokeCap.round;

    final path = Path();
    final yPos = 18.0; 
    final xStart = 5.0;
    final xEnd = size.width - 5.0;
    final xMid = size.width / 2;

    switch (emotion) {
      case RobotEmotion.neutral:
        path.moveTo(xStart, yPos);
        path.quadraticBezierTo(xMid, yPos - 3, xEnd, yPos);
        break;
      case RobotEmotion.happy:
      case RobotEmotion.excited:
        path.moveTo(xStart, yPos - 8);
        path.quadraticBezierTo(xMid, yPos - 16, xEnd, yPos - 8);
        break;
      case RobotEmotion.sad:
        if (isLeft) {
          path.moveTo(xStart, yPos + 6);
          path.lineTo(xEnd, yPos - 6);
        } else {
          path.moveTo(xStart, yPos - 6);
          path.lineTo(xEnd, yPos + 6);
        }
        break;
      case RobotEmotion.angry:
        if (isLeft) {
          path.moveTo(xStart, yPos - 6);
          path.lineTo(xEnd, yPos + 8);
        } else {
          path.moveTo(xStart, yPos + 8);
          path.lineTo(xEnd, yPos - 6);
        }
        break;
      case RobotEmotion.curious:
      case RobotEmotion.surprised:
        path.moveTo(xStart, yPos - 12);
        path.quadraticBezierTo(xMid, yPos - 20, xEnd, yPos - 12);
        break;
      case RobotEmotion.thinking:
        if (isLeft) {
          path.moveTo(xStart, yPos + 4);
          path.lineTo(xEnd, yPos - 4);
        } else {
          path.moveTo(xStart, yPos - 4);
          path.lineTo(xEnd, yPos + 4);
        }
        break;
      case RobotEmotion.wink:
        if (isLeft) {
          path.moveTo(xStart, yPos);
          path.quadraticBezierTo(xMid, yPos - 3, xEnd, yPos);
        } else {
          path.moveTo(xStart, yPos - 10);
          path.quadraticBezierTo(xMid, yPos - 18, xEnd, yPos - 10);
        }
        break;
      case RobotEmotion.love:
        final pulse = 3 * sin(animationValue * 2 * pi);
        path.moveTo(xStart, yPos - 6 + pulse);
        path.quadraticBezierTo(xMid, yPos - 14 + pulse, xEnd, yPos - 6 + pulse);
        break;
      case RobotEmotion.dizzy:
        path.moveTo(xStart, yPos);
        for (double x = xStart; x <= xEnd; x += 2) {
          final y = yPos + 3 * sin((x / 5) + animationValue * 2 * pi);
          if (x == xStart) {
            path.moveTo(x, y);
          } else {
            path.lineTo(x, y);
          }
        }
        break;
      case RobotEmotion.playing:
        if (isLeft) {
          path.moveTo(xStart, yPos - 4);
          path.lineTo(xMid, yPos + 2);
          path.lineTo(xEnd, yPos - 4);
        } else {
          path.moveTo(xStart, yPos + 2);
          path.lineTo(xMid, yPos - 4);
          path.lineTo(xEnd, yPos + 2);
        }
        break;
    }
    canvas.drawPath(path, paint);
  }

  void drawPupilAndHighlights(Canvas canvas, Rect rect, Offset lookOffset) {
    final center = rect.center;
    final maxOffset = rect.width * 0.15;
    final actualOffset = Offset(
      lookOffset.dx.clamp(-maxOffset, maxOffset),
      lookOffset.dy.clamp(-maxOffset, maxOffset),
    );

    // Deep pupil
    final pupilPaint = Paint()..color = const Color(0xFF004D40).withValues(alpha: 0.5);
    canvas.drawCircle(center + actualOffset, rect.width * 0.3, pupilPaint);

    // Main highlight (large white oval)
    final reflectionPaint = Paint()..color = Colors.white.withValues(alpha: 0.85);
    canvas.drawCircle(
      center + actualOffset + Offset(rect.width * 0.14, -rect.height * 0.14),
      rect.width * 0.11,
      reflectionPaint
    );

    // Secondary highlight (small reflection)
    final secondaryPaint = Paint()..color = Colors.white.withValues(alpha: 0.5);
    canvas.drawCircle(
      center + actualOffset + Offset(-rect.width * 0.14, rect.height * 0.14),
      rect.width * 0.06,
      secondaryPaint
    );
  }

  @override
  bool shouldRepaint(covariant _EyePainter oldDelegate) {
    return oldDelegate.isLeft != isLeft ||
        oldDelegate.emotion != emotion ||
        oldDelegate.blinkProgress != blinkProgress ||
        oldDelegate.lookOffset != lookOffset ||
        oldDelegate.animationValue != animationValue ||
        oldDelegate.color != color;
  }
}

class _Mouth extends StatelessWidget {
  final RobotEmotion emotion;
  final double animationValue;

  const _Mouth({
    required this.emotion,
    required this.animationValue,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 60,
      height: 25,
      child: CustomPaint(
        painter: _MouthPainter(
          emotion: emotion,
          animationValue: animationValue,
          color: Colors.cyanAccent,
        ),
      ),
    );
  }
}

class _MouthPainter extends CustomPainter {
  final RobotEmotion emotion;
  final double animationValue;
  final Color color;

  _MouthPainter({
    required this.emotion,
    required this.animationValue,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final glowPaint = Paint()
      ..color = color.withValues(alpha: 0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);

    final path = Path();
    final double w = size.width;
    final double h = size.height;

    switch (emotion) {
      case RobotEmotion.neutral:
        path.moveTo(w * 0.35, h / 2);
        path.lineTo(w * 0.65, h / 2);
        break;
      case RobotEmotion.happy:
        path.moveTo(w * 0.2, h * 0.3);
        path.quadraticBezierTo(w / 2, h * 0.8, w * 0.8, h * 0.3);
        break;
      case RobotEmotion.sad:
        path.moveTo(w * 0.2, h * 0.7);
        path.quadraticBezierTo(w / 2, h * 0.2, w * 0.8, h * 0.7);
        break;
      case RobotEmotion.curious:
        canvas.drawPath(path..addOval(Rect.fromCenter(center: Offset(w / 2, h / 2), width: 12, height: 12)), glowPaint);
        canvas.drawOval(Rect.fromCenter(center: Offset(w / 2, h / 2), width: 12, height: 12), paint);
        return;
      case RobotEmotion.surprised:
        canvas.drawPath(path..addOval(Rect.fromCenter(center: Offset(w / 2, h / 2), width: 16, height: 22)), glowPaint);
        canvas.drawOval(Rect.fromCenter(center: Offset(w / 2, h / 2), width: 16, height: 22), paint);
        return;
      case RobotEmotion.thinking:
        path.moveTo(w * 0.25, h / 2);
        for (double x = w * 0.25; x <= w * 0.75; x += 1) {
          final y = h / 2 + 3 * sin((x / 4) + animationValue * 2 * pi);
          path.lineTo(x, y);
        }
        break;
      case RobotEmotion.excited:
        final mouthRect = Rect.fromCenter(center: Offset(w / 2, h * 0.4), width: w * 0.5, height: h * 0.6);
        final fillPaint = Paint()
          ..color = color
          ..style = PaintingStyle.fill;
        canvas.drawArc(mouthRect, 0, pi, true, fillPaint);
        return;
      case RobotEmotion.playing:
        path.moveTo(w * 0.2, h * 0.35);
        path.lineTo(w * 0.35, h * 0.65);
        path.lineTo(w * 0.5, h * 0.35);
        path.lineTo(w * 0.65, h * 0.65);
        path.lineTo(w * 0.8, h * 0.35);
        break;
      case RobotEmotion.wink:
        path.moveTo(w * 0.3, h * 0.5);
        path.quadraticBezierTo(w * 0.5, h * 0.75, w * 0.75, h * 0.4);
        break;
      case RobotEmotion.angry:
        path.moveTo(w * 0.25, h * 0.4);
        path.lineTo(w * 0.35, h * 0.6);
        path.lineTo(w * 0.45, h * 0.4);
        path.lineTo(w * 0.55, h * 0.6);
        path.lineTo(w * 0.65, h * 0.4);
        path.lineTo(w * 0.75, h * 0.6);
        break;
      case RobotEmotion.love:
        final heartLips = Path();
        final cx = w / 2;
        final cy = h / 2;
        heartLips.moveTo(cx, cy + 4);
        heartLips.quadraticBezierTo(cx - 8, cy - 6, cx - 4, cy - 10);
        heartLips.quadraticBezierTo(cx, cy - 10, cx, cy - 4);
        heartLips.quadraticBezierTo(cx, cy - 10, cx + 4, cy - 10);
        heartLips.quadraticBezierTo(cx + 8, cy - 6, cx, cy + 4);
        final fillPaint = Paint()
          ..color = color
          ..style = PaintingStyle.fill;
        canvas.drawPath(heartLips, fillPaint);
        return;
      case RobotEmotion.dizzy:
        path.moveTo(w * 0.2, h / 2);
        for (double x = w * 0.2; x <= w * 0.8; x += 1) {
          final y = h / 2 + 5 * sin((x / 5) + animationValue * 4 * pi);
          path.lineTo(x, y);
        }
        break;
    }

    canvas.drawPath(path, glowPaint);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _MouthPainter oldDelegate) {
    return oldDelegate.emotion != emotion ||
        oldDelegate.animationValue != animationValue ||
        oldDelegate.color != color;
  }
}

class _Hands extends StatelessWidget {
  final RobotEmotion emotion;
  final double animationValue;

  const _Hands({
    required this.emotion,
    required this.animationValue,
  });

  bool _shouldShowHands(RobotEmotion emotion) {
    return emotion == RobotEmotion.happy ||
        emotion == RobotEmotion.excited ||
        emotion == RobotEmotion.playing ||
        emotion == RobotEmotion.love ||
        emotion == RobotEmotion.surprised ||
        emotion == RobotEmotion.wink ||
        emotion == RobotEmotion.dizzy;
  }

  @override
  Widget build(BuildContext context) {
    final show = _shouldShowHands(emotion);
    final double leftPos = show ? 15 : -70;
    final double rightPos = show ? 15 : -70;
    
    double leftTilt = 0;
    double rightTilt = 0;
    double leftY = 0;
    double rightY = 0;

    switch (emotion) {
      case RobotEmotion.excited:
        leftTilt = 0.3 * sin(animationValue * 4 * pi);
        rightTilt = -0.3 * cos(animationValue * 4 * pi);
        leftY = 12 * sin(animationValue * 4 * pi);
        rightY = 12 * cos(animationValue * 4 * pi);
        break;
      case RobotEmotion.playing:
        leftTilt = 0.25 * sin(animationValue * 3 * pi);
        rightTilt = -0.25 * sin(animationValue * 3 * pi);
        leftY = 8 * sin(animationValue * 3 * pi);
        rightY = 8 * sin(animationValue * 3 * pi);
        break;
      case RobotEmotion.happy:
        leftTilt = 0.15 * sin(animationValue * 2 * pi);
        rightTilt = -0.15 * cos(animationValue * 2 * pi);
        leftY = 4 * sin(animationValue * 2 * pi);
        rightY = 4 * cos(animationValue * 2 * pi);
        break;
      case RobotEmotion.love:
        leftTilt = 0.1 * sin(animationValue * pi);
        rightTilt = -0.1 * sin(animationValue * pi);
        break;
      case RobotEmotion.surprised:
        leftY = -25 + 2 * sin(animationValue * 8 * pi);
        rightY = -25 + 2 * cos(animationValue * 8 * pi);
        leftTilt = 0.35 + 0.05 * sin(animationValue * 8 * pi);
        rightTilt = -0.35 - 0.05 * cos(animationValue * 8 * pi);
        break;
      case RobotEmotion.wink:
        leftTilt = 0.2 * sin(animationValue * 2.5 * pi);
        leftY = 6 * sin(animationValue * 2.5 * pi);
        break;
      case RobotEmotion.dizzy:
        leftY = 8 * sin(animationValue * 2 * pi);
        rightY = 8 * cos(animationValue * 2 * pi);
        leftTilt = 0.2 * cos(animationValue * 2 * pi);
        rightTilt = -0.2 * sin(animationValue * 2 * pi);
        break;
      default:
        break;
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // Left hand
        AnimatedPositioned(
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOutBack,
          left: leftPos,
          top: 105, 
          child: Transform.translate(
            offset: Offset(0, leftY),
            child: Transform.rotate(
              angle: leftTilt,
              child: SizedBox(
                width: 50,
                height: 50,
                child: CustomPaint(
                  painter: _HandPainter(isLeft: true, color: Colors.cyanAccent),
                ),
              ),
            ),
          ),
        ),
        // Right hand
        AnimatedPositioned(
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOutBack,
          right: rightPos,
          top: 105, 
          child: Transform.translate(
            offset: Offset(0, rightY),
            child: Transform.rotate(
              angle: rightTilt,
              child: SizedBox(
                width: 50,
                height: 50,
                child: CustomPaint(
                  painter: _HandPainter(isLeft: false, color: Colors.cyanAccent),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _HandPainter extends CustomPainter {
  final bool isLeft;
  final Color color;

  _HandPainter({required this.isLeft, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final double w = size.width;
    final double h = size.height;
    final center = Offset(w / 2, h / 2);

    // Glow effect
    final glowPaint = Paint()
      ..color = color.withValues(alpha: 0.3)
      ..style = PaintingStyle.fill
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawCircle(center, 15, glowPaint);

    // Draw Palm
    canvas.drawCircle(center, 12, paint);

    // Fingers as small rounded rectangles
    final fingerPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    void drawFinger(double cx, double cy, double width, double height, double rotationRad) {
      canvas.save();
      canvas.translate(cx, cy);
      canvas.rotate(rotationRad);
      final rrect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset.zero, width: width, height: height),
        Radius.circular(width / 2),
      );
      canvas.drawRRect(rrect, fingerPaint);
      canvas.restore();
    }

    if (isLeft) {
      // Left Hand: Thumb is on the right (pointing inwards)
      drawFinger(w * 0.74, h * 0.55, 6, 12, pi / 3);
      drawFinger(w * 0.45, h * 0.22, 6, 14, -pi / 12);
      drawFinger(w * 0.26, h * 0.32, 6, 14, -pi / 4);
      drawFinger(w * 0.22, h * 0.55, 6, 12, -pi / 2);
    } else {
      // Right Hand: Thumb is on the left (pointing inwards)
      drawFinger(w * 0.26, h * 0.55, 6, 12, -pi / 3);
      drawFinger(w * 0.55, h * 0.22, 6, 14, pi / 12);
      drawFinger(w * 0.74, h * 0.32, 6, 14, pi / 4);
      drawFinger(w * 0.78, h * 0.55, 6, 12, pi / 2);
    }
  }

  @override
  bool shouldRepaint(covariant _HandPainter oldDelegate) {
    return oldDelegate.isLeft != isLeft || oldDelegate.color != color;
  }
}
