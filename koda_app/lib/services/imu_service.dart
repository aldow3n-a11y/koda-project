import 'dart:async';
import 'dart:math' as math;
import 'package:sensors_plus/sensors_plus.dart';
import 'slam_service.dart';

class ImuService {
  final SlamService _slamService;
  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  StreamSubscription<MagnetometerEvent>? _magSub;

  double _gravityX = 0;
  double _gravityY = 1; // Default to Y
  double _gravityZ = 0;

  double _magX = 0;
  double _magY = 0;
  double _magZ = 0;
  double? _magHeading;
  bool _initializedHeadingWithMag = false;

  DateTime? _lastGyroTime;
  bool _isRunning = false;
  bool invert = false;

  // ── Kidnap Detection ──────────────────────────────────────────────────────
  /// Fired when Koda detects it has been physically picked up and moved.
  void Function()? onKidnapped;

  // ── Stuck/Tilt Detection ──────────────────────────────────────────────────
  /// Fired when Koda detects it is physically stuck or tilted.
  void Function(String reason)? onStuck;

  double? _nominalGx;
  double? _nominalGy;
  double? _nominalGz;
  int _tiltTicks = 0;
  
  static const double _tiltThresholdDot = 0.82; // cos(35 degrees)
  static const int _requiredTiltSamples = 50; // ~1.0 second at 50Hz

  // Smoothed gyro magnitude — low when robot is NOT rotating/driving
  double _smoothedGyroMag = 0.0;

  // Debounce to prevent multiple kidnap events from one lift action
  DateTime? _lastKidnapTime;

  // Timestamp of the last motor command — suppress kidnap detection during motion
  DateTime? _lastMotorTime;

  // How long to suppress kidnap detection after a motor command (ms)
  static const int _motorSuppressionMs = 1500;

  // Jolt threshold: must exceed this to consider a lift
  // High value (8.0) prevents normal vibration/swing from triggering
  static const double _liftJoltThreshold = 8.0;

  // Only fire once every 5 seconds (generous debounce)
  static const int _kidnapDebounceMs = 5000;

  // How many consecutive high-jolt samples required to confirm a lift
  // (prevents single-spike false positives from driving vibration)
  static const int _requiredJoltSamples = 5;
  int _consecutiveJoltCount = 0;

  ImuService(this._slamService);

  /// Call this whenever a motor command is sent.
  /// Suppresses kidnap detection for [_motorSuppressionMs] after each call.
  void setMotorActive() {
    _lastMotorTime = DateTime.now();
    _consecutiveJoltCount = 0; // Reset jolt counter on motor activity
  }

  void start() {
    if (_isRunning) return;
    _isRunning = true;
    _lastGyroTime = DateTime.now();

    _accelSub = accelerometerEventStream().listen((event) {
      // Low-pass filter to track the slowly-changing gravity direction
      const alpha = 0.1;
      _gravityX = alpha * event.x + (1 - alpha) * _gravityX;
      _gravityY = alpha * event.y + (1 - alpha) * _gravityY;
      _gravityZ = alpha * event.z + (1 - alpha) * _gravityZ;

      // ── Tilt / Tip-over Detection ──────────────────────────────────────
      final gMag = math.sqrt(_gravityX * _gravityX + _gravityY * _gravityY + _gravityZ * _gravityZ);
      if (gMag > 0.1) {
        final gx = _gravityX / gMag;
        final gy = _gravityY / gMag;
        final gz = _gravityZ / gMag;

        // Initialize nominal gravity vector with first stable sample
        if (_nominalGx == null) {
          _nominalGx = gx;
          _nominalGy = gy;
          _nominalGz = gz;
        }

        // Dot product represents the cosine of tilt angle relative to nominal baseline
        final dot = gx * _nominalGx! + gy * _nominalGy! + gz * _nominalGz!;
        if (dot < _tiltThresholdDot) {
          _tiltTicks++;
        } else {
          _tiltTicks = 0;
        }

        if (_tiltTicks >= _requiredTiltSamples) {
          _tiltTicks = 0;
          onStuck?.call('tilted');
        }
      }

      // ── Kidnap / Lift Detection ────────────────────────────────────────
      // High-pass filter: subtract gravity to isolate sudden jolts
      final joltX = event.x - _gravityX;
      final joltY = event.y - _gravityY;
      final joltZ = event.z - _gravityZ;
      final joltMag = math.sqrt(joltX * joltX + joltY * joltY + joltZ * joltZ);

      // Suppress if motors are actively running (phone holder swings with movement)
      final now = DateTime.now();
      final msSinceMotor = _lastMotorTime == null
          ? _motorSuppressionMs + 1
          : now.difference(_lastMotorTime!).inMilliseconds;
      final motorSuppressed = msSinceMotor < _motorSuppressionMs;

      // A lift event = big sustained jolt AND motors have been quiet for a while
      if (!motorSuppressed && joltMag > _liftJoltThreshold && _smoothedGyroMag < 0.5) {
        _consecutiveJoltCount++;
      } else {
        // Reset counter if any condition fails
        _consecutiveJoltCount = 0;
      }

      // Only trigger after N consecutive high-jolt samples (avoids single spikes)
      if (_consecutiveJoltCount >= _requiredJoltSamples) {
        _consecutiveJoltCount = 0;
        final msSinceLast = _lastKidnapTime == null
            ? _kidnapDebounceMs + 1
            : now.difference(_lastKidnapTime!).inMilliseconds;

        if (msSinceLast > _kidnapDebounceMs) {
          _lastKidnapTime = now;
          _slamService.invalidatePose();
          onKidnapped?.call();
        }
      }
    });

    _magSub = magnetometerEventStream().listen((event) {
      const alpha = 0.1;
      _magX = alpha * event.x + (1 - alpha) * _magX;
      _magY = alpha * event.y + (1 - alpha) * _magY;
      _magZ = alpha * event.z + (1 - alpha) * _magZ;
      _updateMagHeading();
    });

    _gyroSub = gyroscopeEventStream().listen((event) {
      final now = DateTime.now();

      // Track gyro magnitude for kidnap detection (smoothed)
      final gyroMag = math.sqrt(
          event.x * event.x + event.y * event.y + event.z * event.z);
      _smoothedGyroMag = 0.8 * _smoothedGyroMag + 0.2 * gyroMag;

      if (_lastGyroTime != null) {
        final dt = now.difference(_lastGyroTime!).inMilliseconds / 1000.0;
        if (dt > 0 && dt < 1.0) {
          // Normalize gravity vector
          final gMag = math.sqrt(
              _gravityX * _gravityX + _gravityY * _gravityY + _gravityZ * _gravityZ);
          if (gMag > 0.1) {
            final gx = _gravityX / gMag;
            final gy = _gravityY / gMag;
            final gz = _gravityZ / gMag;

            // Dot product isolates vertical rotation (yaw) regardless of phone slant
            double rotationRate =
                (event.x * gx) + (event.y * gy) + (event.z * gz);

            double deltaHeading = rotationRate * dt;
            if (invert) deltaHeading = -deltaHeading;

            if (_magHeading != null) {
              final currentHeading = _slamService.pose.heading;
              var nextHeading = currentHeading + deltaHeading;
              nextHeading = (nextHeading + math.pi) % (2.0 * math.pi) - math.pi;

              var diff = _magHeading! - nextHeading;
              diff = (diff + math.pi) % (2.0 * math.pi) - math.pi;

              // compAlpha corrects gyro drift toward magnetometer heading slowly.
              // Disabled (0.0) to stop magnetometer drift when motors/battery interfere with compass.
              const compAlpha = 0.0;
              final correctedHeading = nextHeading + diff * compAlpha;

              _slamService.pose.heading = (correctedHeading + math.pi) % (2.0 * math.pi) - math.pi;
            } else {
              _slamService.adjustHeading(deltaHeading);
            }
          }
        }
      }
      _lastGyroTime = now;
    });
  }

  void _updateMagHeading() {
    final gMag = math.sqrt(_gravityX * _gravityX + _gravityY * _gravityY + _gravityZ * _gravityZ);
    final bMag = math.sqrt(_magX * _magX + _magY * _magY + _magZ * _magZ);
    if (gMag < 0.1 || bMag < 0.1) return;

    // 1. Down vector (normalized gravity)
    final dx = _gravityX / gMag;
    final dy = _gravityY / gMag;
    final dz = _gravityZ / gMag;

    // 2. East vector = Down x MagneticField
    final ex = dy * _magZ - dz * _magY;
    final ey = dz * _magX - dx * _magZ;
    final ez = dx * _magY - dy * _magX;
    final eMag = math.sqrt(ex * ex + ey * ey + ez * ez);
    if (eMag < 0.01) return; // Magnetic field is parallel to gravity
    final uex = ex / eMag;
    final uey = ey / eMag;
    final uez = ez / eMag;

    // 3. North vector = East x Down
    final nx = uey * dz - uez * dy;
    final ny = uez * dx - uex * dz;
    final nz = uex * dy - uey * dx;

    // 4. Project phone's forward camera direction (-Z axis in portrait) onto horizontal plane.
    // The phone is vertical: top is Up, bottom is Down (gravity Y is positive).
    // The rear camera points forward, which is -Z direction in phone frame.
    // Projection of v = (0, 0, -1) onto plane perpendicular to Down D = (dx, dy, dz) is:
    // v_proj = v - (v . D) * D = (0, 0, -1) - (-dz) * (dx, dy, dz) = (dz * dx, dz * dy, dz * dz - 1)
    final ux = dz * dx;
    final uy = dz * dy;
    final uz = dz * dz - 1.0;
    final uMag = math.sqrt(ux * ux + uy * uy + uz * uz);
    if (uMag < 0.01) return; // Phone is lying completely flat on the screen
    final fx = ux / uMag;
    final fy = uy / uMag;
    final fz = uz / uMag;

    // 5. Calculate angle of forward vector relative to North in the horizontal plane
    final fNorth = fx * nx + fy * ny + fz * nz;
    final fEast = fx * uex + fy * uey + fz * uez;

    // Magnetic heading: absolute angle relative to North (0 = North, pi/2 = East, -pi/2 = West)
    final thetaMag = math.atan2(fEast, fNorth);

    // Convert to Koda's map coordinate heading system where:
    // 0 = East, pi/2 = North, -pi/2 = South, pi = West
    // Conversion: thetaMap = pi/2 - thetaMag
    final thetaMap = math.pi / 2.0 - thetaMag;

    // Normalize to [-pi, pi]
    _magHeading = (thetaMap + math.pi) % (2.0 * math.pi) - math.pi;

    // Initialize Koda's heading with magnetometer if not yet initialized
    if (!_initializedHeadingWithMag) {
      _slamService.pose.heading = _magHeading!;
      _initializedHeadingWithMag = true;
    }
  }

  void stop() {
    if (!_isRunning) return;
    _isRunning = false;
    _accelSub?.cancel();
    _gyroSub?.cancel();
    _magSub?.cancel();
    _accelSub = null;
    _gyroSub = null;
    _magSub = null;
  }
}
