import 'dart:async';
import 'dart:math' as math;
import 'package:sensors_plus/sensors_plus.dart';
import 'slam_service.dart';

class ImuService {
  final SlamService _slamService;
  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;

  double _gravityX = 0;
  double _gravityY = 1; // Default to Y
  double _gravityZ = 0;

  DateTime? _lastGyroTime;
  bool _isRunning = false;
  bool invert = false;

  ImuService(this._slamService);

  void start() {
    if (_isRunning) return;
    _isRunning = true;
    _lastGyroTime = DateTime.now();

    _accelSub = accelerometerEventStream().listen((event) {
      // Low-pass filter for gravity to isolate the direction of true down
      const alpha = 0.1;
      _gravityX = alpha * event.x + (1 - alpha) * _gravityX;
      _gravityY = alpha * event.y + (1 - alpha) * _gravityY;
      _gravityZ = alpha * event.z + (1 - alpha) * _gravityZ;
    });

    _gyroSub = gyroscopeEventStream().listen((event) {
      final now = DateTime.now();
      if (_lastGyroTime != null) {
        final dt = now.difference(_lastGyroTime!).inMilliseconds / 1000.0;
        if (dt > 0 && dt < 1.0) { // Safety check to prevent huge jumps
          // Normalize gravity vector
          final gMag = math.sqrt(_gravityX * _gravityX + _gravityY * _gravityY + _gravityZ * _gravityZ);
          if (gMag > 0.1) {
            final gx = _gravityX / gMag;
            final gy = _gravityY / gMag;
            final gz = _gravityZ / gMag;

            // Dot product isolates the vertical rotation (yaw) regardless of phone slant
            double rotationRate = (event.x * gx) + (event.y * gy) + (event.z * gz);
            
            // Apply delta
            double deltaHeading = rotationRate * dt;
            if (invert) deltaHeading = -deltaHeading;
            
            _slamService.adjustHeading(deltaHeading);
          }
        }
      }
      _lastGyroTime = now;
    });
  }

  void stop() {
    if (!_isRunning) return;
    _isRunning = false;
    _accelSub?.cancel();
    _gyroSub?.cancel();
    _accelSub = null;
    _gyroSub = null;
  }
}
