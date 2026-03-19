import 'dart:math';
import 'package:flutter/material.dart';
import '../models/models.dart';

class RobotFaceOverlay extends StatelessWidget {
  final RobotEmotion emotion;
  
  const RobotFaceOverlay({
    super.key, 
    required this.emotion,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Center(
        child: AnimatedRobotEyes(emotion: emotion),
      ),
    );
  }
}

class AnimatedRobotEyes extends StatefulWidget {
  final RobotEmotion emotion;
  const AnimatedRobotEyes({super.key, required this.emotion});

  @override
  State<AnimatedRobotEyes> createState() => _AnimatedRobotEyesState();
}

class _AnimatedRobotEyesState extends State<AnimatedRobotEyes> with SingleTickerProviderStateMixin {
  late AnimationController _blinkController;
  
  @override
  void initState() {
    super.initState();
    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _scheduleBlink();
  }

  void _scheduleBlink() {
    if (!mounted) return;
    final delay = 2000 + Random().nextInt(4000);
    Future.delayed(Duration(milliseconds: delay), () {
      if (!mounted) return;
      _blinkController.forward().then((_) {
        _blinkController.reverse().then((_) => _scheduleBlink());
      });
    });
  }

  @override
  void dispose() {
    _blinkController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Determine eye shape based on emotion
    double height = 40;
    double width = 30;
    double arch = 0; // Positive for happy (upper arch), negative for sad (lower arch)
    double gap = 45;
    double yOffset = 0;
    
    switch (widget.emotion) {
      case RobotEmotion.happy:
        height = 15;
        arch = 25;
        break;
      case RobotEmotion.sad:
        height = 20;
        arch = -15;
        yOffset = 10;
        break;
      case RobotEmotion.curious:
        height = 45;
        width = 35;
        gap = 35;
        break;
      case RobotEmotion.surprised:
        height = 50;
        width = 40;
        break;
      case RobotEmotion.thinking:
        height = 10;
        break;
      case RobotEmotion.neutral:
        break;
    }

    return AnimatedBuilder(
      animation: _blinkController,
      builder: (context, child) {
        // Apply blink compression
        final currentHeight = height * (1 - _blinkController.value) + 2 * _blinkController.value;
        
        return AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutBack,
          transform: Matrix4.translationValues(0, yOffset, 0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Eye(width: width, height: currentHeight, arch: arch),
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: gap,
              ),
              _Eye(width: width, height: currentHeight, arch: arch),
            ],
          ),
        );
      },
    );
  }
}

class _Eye extends StatelessWidget {
  final double width;
  final double height;
  final double arch;

  const _Eye({
    required this.width,
    required this.height,
    required this.arch,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: width,
      height: height,
      child: CustomPaint(
        painter: _EyePainter(arch: arch, color: Colors.cyanAccent),
      ),
    );
  }
}

class _EyePainter extends CustomPainter {
  final double arch;
  final Color color;

  _EyePainter({required this.arch, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    
    // Smooth organic squircle for the eye
    final r = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Radius.circular(size.width / 2),
    );
    
    if (arch == 0) {
      canvas.drawRRect(r, paint..style = PaintingStyle.fill);
    } else {
      // Draw an arch (happy or sad)
      final yMid = size.height / 2;
      path.moveTo(0, yMid);
      path.quadraticBezierTo(
        size.width / 2, 
        yMid - arch, 
        size.width, 
        yMid
      );
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _EyePainter oldDelegate) {
    return oldDelegate.arch != arch || oldDelegate.color != color;
  }
}
