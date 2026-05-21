import 'dart:async';
import '../models/models.dart';

typedef SendBleCmd = Future<void> Function(KodaCmd cmd, int speed, int ms);
typedef SpeakFn = Future<void> Function(String text);
typedef LogFn = void Function(String type, String message);
typedef ProcessInputFn = Future<void> Function(String input, {bool isLoopStep});
typedef StartListenFn = void Function({required void Function(String) onResult, int timeoutSec});
typedef StopListenFn = void Function();
typedef GetMaxLoopFn = int Function();
typedef GetUptimeFn = String Function();
typedef GetIsConnectedFn = bool Function();
typedef GetMemoryCountFn = int Function();
typedef SetEmotionFn = void Function(RobotEmotion emotion);
typedef SaveMemoryFn = Future<void> Function(String fact);
typedef SetLastSummaryFn = void Function(String summary);

/// Returns the obstacle distance in mm for a given direction ('forward','backward','left','right').
/// Returns null if no obstacle detected (CLEAR).
typedef GetLidarRangeFn = int? Function(String direction);

typedef PlanToFn = Future<bool> Function(double x, double y);
typedef ChangeScreenFn = Future<void> Function(int index);
typedef SetCanvasFn = void Function(CanvasContent content);
typedef AnalyzeFrameFn = Future<List<String>> Function(String currentHeading);
typedef GetObjectTrackingDataFn = ObjectTrackingData? Function();
typedef GetCancelRequestedFn = bool Function();
typedef GetTrackingEnabledFn = bool Function();
typedef SetTrackingEnabledFn = void Function(bool enabled);

/// Dispatches SkillAction items to handler functions.
/// All dependencies are injected as callbacks to avoid circular imports.
/// To add a new skill: add a handler + register it in [_registry].
class SkillExecutor {
  final SendBleCmd onBle;
  final SpeakFn onSpeak;
  final LogFn onLog;
  final ProcessInputFn onProcessInput;
  final StartListenFn onStartListen;
  final StopListenFn onStopListen;
  final GetMaxLoopFn getMaxLoop;
  final GetUptimeFn getUptime;
  final GetIsConnectedFn getIsConnected;
  final GetMemoryCountFn getMemoryCount;
  final SetEmotionFn onSetEmotion;
  final SaveMemoryFn onSaveMemory;
  final GetLidarRangeFn getLidarRange;
  final PlanToFn onPlanTo;
  final ChangeScreenFn onChangeScreen;
  final SetCanvasFn onSetCanvas;
  final AnalyzeFrameFn? onAnalyzeFrame;
  final GetObjectTrackingDataFn? getObjectTrackingData;
  final GetCancelRequestedFn? getCancelRequested;
  final GetTrackingEnabledFn? getTrackingEnabled;
  final SetTrackingEnabledFn? onSetTracking;
  final SetLastSummaryFn? onSetLastSummary;

  /// Minimum safe distance in mm before a move is blocked.
  static const int _safetyDistanceMm = 250;

  int _loopCount = 0;

  SkillExecutor({
    required this.onBle,
    required this.onSpeak,
    required this.onLog,
    required this.onProcessInput,
    required this.onStartListen,
    required this.onStopListen,
    required this.getMaxLoop,
    required this.getUptime,
    required this.getIsConnected,
    required this.getMemoryCount,
    required this.onSetEmotion,
    required this.onSaveMemory,
    required this.getLidarRange,
    required this.onPlanTo,
    required this.onChangeScreen,
    required this.onSetCanvas,
    this.onAnalyzeFrame,
    this.getObjectTrackingData,
    this.getCancelRequested,
    this.getTrackingEnabled,
    this.onSetTracking,
    this.onSetLastSummary,
  });

  void resetLoopCount() => _loopCount = 0;

  /// Checks LiDAR before moving forward. Returns true if move was executed, false if blocked.
  Future<bool> _safeMoveForward(int speed, int ms) async {
    final rangeMm = getLidarRange('forward');
    if (rangeMm != null && rangeMm < _safetyDistanceMm) {
      onLog('err', '[SAFETY] Blocked! forward ${rangeMm}mm < ${_safetyDistanceMm}mm. Skipping.');
      return false;
    }
    await onBle(KodaCmd.forward, speed, ms);
    return true;
  }

  Future<void> run(SkillAction action) async {
    final handler = _registry[action.skill];
    if (handler != null) {
      await handler(action);
    } else {
      onLog('err', 'Unknown skill: "${action.skill}"');
    }
  }

  late final Map<String, Future<void> Function(SkillAction)> _registry = {
    'emotion':           _emotion,
    'speech':            _speech,
    'move':              _move,
    'turn':              _turn,
    'listen':            _listen,
    'evaluate_location': _evaluateLocation,
    'explore':           _explore,
    'drive_to':          _driveTo,
    'dance':             _dance,
    'report_status':     _reportStatus,
    'save_memory':       _saveMemory,
    'monitor':           _monitor,
    'patrol':            _patrol,
    'visual_align':      _visualAlign,
    'drive_to_object':   _driveToObject,
    'follow_trajectory': _followTrajectory,
    'change_screen':     _changeScreen,
    'show_display':      _showDisplay,
    'change_display':    _showDisplay,
    'scan_room':         _scanRoom,
    'follow':            _follow,
  };

  // ── Handlers ──────────────────────────────────────────────────────────────

  Future<void> _scanRoom(SkillAction a) async {
    onLog('sys', 'Starting 360-degree room scan...');
    final Set<String> allObjects = {};
    
    // Convert current heading to compass direction (provided by BrainNotifier during callback)
    // We'll execute 4 turns of roughly 90 degrees
    for (int i = 0; i < 4; i++) {
      onLog('sys', 'Scan step ${i + 1}/4...');
      
      if (onAnalyzeFrame != null) {
        // Pass a formatted heading string. Wait, we agreed that we will get the heading from BrainNotifier 
        // but wait, the callback signature expects `currentHeading` to be passed *to* it? No, BrainNotifier 
        // has the SLAM state! We don't need to pass `currentHeading` from SkillExecutor. BrainNotifier can compute it.
        // But since we defined `AnalyzeFrameFn = Future<List<String>> Function(String currentHeading)`, 
        // we should instead define it without args and let BrainNotifier inject the heading inside its own closure, 
        // OR we can pass an empty string and BrainNotifier ignores it. Let's just pass "Scan frame ${i+1}".
        final objects = await onAnalyzeFrame!('Frame ${i + 1}');
        allObjects.addAll(objects);
      }
      
      if (i < 3) {
        await onBle(KodaCmd.turnCw, 60, 600);
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
    
    final objectsStr = allObjects.isNotEmpty ? allObjects.join(', ') : 'no objects detected';
    onLog('sys', 'Scan complete. Found: $objectsStr');
    
    await onProcessInput(
      'SYSTEM NOTIFICATION: I have completed a full 360-degree scan of the room. I saw the following positioned objects: $objectsStr. Please report this mental history back to the user in a natural, conversational way.',
      isLoopStep: false,
    );
  }

  Future<void> _follow(SkillAction a) async {
    final target = a.param('target', 'object');
    onLog('sys', 'Starting fast ML follow for: $target');
    
    final wasTracking = getTrackingEnabled != null && getTrackingEnabled!();
    if (onSetTracking != null) onSetTracking!(true);
    
    int lostFrames = 0;
    int trackedFrames = 0;
    
    try {
      while (getCancelRequested != null && !getCancelRequested!()) {
        if (getObjectTrackingData == null) break;
        final data = getObjectTrackingData!();
        
        if (data == null) {
          lostFrames++;
          trackedFrames = 0; // Reset consecutive frame counter
          if (lostFrames > 30) { // ~3 seconds at 10 Hz
             onLog('sys', 'Lost track of $target. Triggering LLM vision analysis.');
             await onBle(KodaCmd.stop, 0, 0);
             if (onAnalyzeFrame != null) {
               final objects = await onAnalyzeFrame!('Forward');
               final objStr = objects.isNotEmpty ? objects.join(', ') : 'nothing';
               await onProcessInput('SYSTEM NOTIFICATION: I lost track of the $target. I am currently looking at: $objStr. Please ask the user where the $target went.', isLoopStep: false);
             } else {
               await onProcessInput('SYSTEM NOTIFICATION: I lost track of the $target while following. Please ask the user what to do next.', isLoopStep: false);
             }
             break;
          }
          await Future.delayed(const Duration(milliseconds: 100));
          continue;
        }
        
        lostFrames = 0;
        trackedFrames++;
        final dx = data.offset.dx; 
        final area = data.areaRatio; 

        // Trigger 1: Proximity Lock (Object is very large/close)
        if (area > 0.45) {
          onLog('sys', 'Proximity trigger: caught up to $target.');
          await onBle(KodaCmd.stop, 0, 0);
          if (onAnalyzeFrame != null) {
            final objects = await onAnalyzeFrame!('Forward');
            final objStr = objects.isNotEmpty ? objects.join(', ') : 'nothing';
            await onProcessInput('SYSTEM NOTIFICATION: I successfully navigated extremely close to the $target. I see: $objStr. Tell the user I caught up to it.', isLoopStep: false);
          } else {
            await onProcessInput('SYSTEM NOTIFICATION: I successfully navigated close to the $target. Tell the user.', isLoopStep: false);
          }
          break;
        }

        // Trigger 2: Time-based Lock (Tracked continuously for 10 seconds / ~100 frames)
        if (trackedFrames > 100) {
          trackedFrames = 0; // Reset to avoid spam
          if (onAnalyzeFrame != null) {
            onLog('sys', 'Time-based lock trigger: identifying tracked object in background...');
            // Do not await to ensure the motor control loop doesn't pause!
            onAnalyzeFrame!('Forward').then((objects) {
              if (objects.isNotEmpty) {
                final objStr = objects.join(', ');
                onProcessInput('SYSTEM NOTIFICATION: While continuously following the $target, I analyzed the vision feed and identified the prominent objects as: $objStr. Mention this naturally if appropriate, but do not stop following.', isLoopStep: false);
              }
            });
          }
        }
        
        // Motor Steering Logic
        if (dx > 3.0) {
          await onBle(KodaCmd.turnCw, 55, 100);
        } else if (dx < -3.0) {
          await onBle(KodaCmd.turnCcw, 55, 100);
        } else {
          if (area < 0.1) {
            await _safeMoveForward(60, 150);
          } else if (area > 0.3) {
            await onBle(KodaCmd.backward, 50, 150);
          } else {
            // Optimal distance, stop moving
            await onBle(KodaCmd.stop, 0, 0);
          }
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }
    } finally {
      if (onSetTracking != null) onSetTracking!(wasTracking);
    }
  }

  Future<void> _followTrajectory(SkillAction a) async {
    final points = a.params['points'] as List?;
    if (points == null || points.isEmpty) return;
    
    onLog('cmd', 'follow_trajectory: ${points.length} points');
    
    // We process up to 10 points to avoid long blocking loops
    final limitedPoints = points.take(10).toList();

    for (var i = 0; i < limitedPoints.length; i++) {
      final p = limitedPoints[i];
      if (p is! List || p.length < 2) continue;

      final y = (p[0] as num).toDouble();
      final x = (p[1] as num).toDouble();
      
      // 1. Align to point (center it in view)
      await _visualAlign(SkillAction(skill: 'visual_align', params: {
        'point': [y, x], 
        'label': 'path point $i'
      }));
      
      // 2. Move forward towards it
      // For a trajectory, we take small-to-medium steps
      await _move(SkillAction(skill: 'move', params: {
        'direction': 'forward', 
        'speed': 65, 
        'ms': 800
      }));
      
      // Brief pause between segments
      await Future.delayed(const Duration(milliseconds: 100));
    }
    
    onLog('sys', 'Trajectory complete.');
  }

  Future<void> _emotion(SkillAction a) async {
    final type = a.param('type', 'happy');
    onLog('cmd', 'emotion: $type');

    // Parse string to RobotEmotion
    final emotion = RobotEmotion.values.firstWhere(
      (e) => e.name == type,
      orElse: () => RobotEmotion.neutral,
    );
    onSetEmotion(emotion);

    switch (type) {
      case 'happy':
        await onBle(KodaCmd.turnCw, 60, 300);
        await onBle(KodaCmd.turnCcw, 60, 300);
        break;
      case 'curious':
        if ((getLidarRange('forward') ?? 9999) >= _safetyDistanceMm) {
          await onBle(KodaCmd.forward, 30, 200);
        }
        await onBle(KodaCmd.backward, 30, 200);
        break;
      case 'excited':
        for (var i = 0; i < 2; i++) {
          await onBle(KodaCmd.turnCw, 70, 250);
          await onBle(KodaCmd.turnCcw, 70, 250);
        }
        break;
      case 'surprised':
        await onBle(KodaCmd.backward, 50, 200);
        break;
      case 'sad':
        await onBle(KodaCmd.turnCw, 25, 500);
        break;
      case 'playing':
        // A playful wiggle loop
        await _safeMoveForward(45, 200);
        await onBle(KodaCmd.turnCw, 65, 200);
        await onBle(KodaCmd.turnCcw, 65, 200);
        await onBle(KodaCmd.backward, 45, 200);
        break;
      case 'wink':
        // A quick tilt forward
        if (await _safeMoveForward(35, 150)) await onBle(KodaCmd.backward, 35, 150);
        break;
      case 'angry':
        // Aggressive shaking
        for (var i = 0; i < 3; i++) {
          await onBle(KodaCmd.turnCw, 85, 120);
          await onBle(KodaCmd.turnCcw, 85, 120);
        }
        break;
      case 'love':
        // Gentle back-and-forth nuzzling
        if (await _safeMoveForward(40, 400)) await onBle(KodaCmd.backward, 40, 400);
        break;
      case 'dizzy':
        // Spin rapidly in a circle
        await onBle(KodaCmd.turnCw, 90, 800);
        break;
    }
  }

  Future<void> _speech(SkillAction a) async {
    final text = a.param('text', '');
    if (text.isEmpty) return;
    onLog('koda', text);
    await onSpeak(text);
  }

  Future<void> _move(SkillAction a) async {
    final dir   = a.param('direction', 'forward');
    final speed = a.paramInt('speed', 65);
    final ms    = a.paramInt('ms', 1000);

    // ── Hardware Safety Gate ──────────────────────────────────────────────
    // Check LiDAR BEFORE executing. Forward only — backward is NOT guarded
    // because the phone holder physically blocks the rear LiDAR sector.
    if (dir == 'forward') {
      final rangeMm = getLidarRange('forward');
      if (rangeMm != null && rangeMm < _safetyDistanceMm) {
        onLog('err', '[SAFETY] Blocked! forward ${rangeMm}mm < ${_safetyDistanceMm}mm. Skipping.');
        await onSpeak('Blocked.');
        if (onSetLastSummary != null) {
          onSetLastSummary!('Action failed: move forward was blocked by an obstacle (${(rangeMm / 10).round()}cm ahead)');
        }
        return;
      }
    }
    // ─────────────────────────────────────────────────────────────────────

    final cmd = dir == 'backward' ? KodaCmd.backward : KodaCmd.forward;
    onLog('cmd', 'move $dir speed:$speed ms:$ms');
    await onBle(cmd, speed, ms);
    if (onSetLastSummary != null) {
      onSetLastSummary!('Action succeeded: move $dir completed.');
    }
  }

  Future<void> _turn(SkillAction a) async {
    final dir = a.param('direction', 'cw');
    _lastTurnDir = dir; // Remember manual turns too
    final speed = a.paramInt('speed', 55);
    final ms = a.paramInt('ms', 500);
    final cmd = dir == 'ccw' ? KodaCmd.turnCcw : KodaCmd.turnCw;
    onLog('cmd', 'turn $dir speed:$speed ms:$ms');
    await onBle(cmd, speed, ms);
    if (onSetLastSummary != null) {
      onSetLastSummary!('Action succeeded: turn $dir completed.');
    }
  }

  Future<void> _listen(SkillAction a) async {
    final timeout = a.paramInt('timeout', 10);
    onLog('sys', 'Listening for ${timeout}s…');

    final completer = Completer<String>();
    final timer = Timer(Duration(seconds: timeout), () {
      if (!completer.isCompleted) completer.complete('');
    });

    onStartListen(timeoutSec: timeout, onResult: (text) {
      if (text.isNotEmpty && !completer.isCompleted) {
        timer.cancel();
        completer.complete(text);
      }
    });

    final heard = await completer.future;
    onStopListen();

    if (heard.isNotEmpty) {
      onLog('user', heard);
      await onProcessInput(heard);
    }
  }

  Future<void> _evaluateLocation(SkillAction a) async {
    final maxIter = getMaxLoop();
    _loopCount++;
    if (_loopCount >= maxIter) {
      onLog('sys', 'Loop limit reached ($_loopCount). Stopping.');
      _loopCount = 0;
      await _speech(const SkillAction(
        skill: 'speech',
        params: {'text': "I've looked around a lot. What should I do next?"},
      ));
      return;
    }
    onLog('sys', 'Evaluate location (step $_loopCount/$maxIter)…');
    await Future.delayed(const Duration(milliseconds: 500));
    await onProcessInput(
      'AUTONOMOUS NAVIGATION: Analyze the scene. If the path ahead is clear (>100cm), MOVE BOLDLY (at least 1200ms-1500ms). Do NOT move in short timid bursts if you have space. Use "evaluate_location" to continue the sequence.',
      isLoopStep: true,
    );

  }

  Future<void> _explore(SkillAction a) async {
    final goal = a.param('goal', 'explore the area');
    onLog('sys', 'Starting explore: $goal');
    _loopCount = 0;
    await onProcessInput(
      'Explore and $goal. Use evaluate_location to navigate autonomously.',
      isLoopStep: true,
    );
  }

  Future<void> _driveTo(SkillAction a) async {
    final x = a.paramInt('target_x', 0).toDouble();
    final y = a.paramInt('target_y', 0).toDouble();
    onLog('cmd', 'drive_to: X:$x, Y:$y');
    
    final ok = await onPlanTo(x, y);
    if (!ok) {
      onLog('err', 'Failed to plan path to X:$x, Y:$y');
      await onSpeak("I can't find a path to those coordinates. It might be blocked.");
      if (onSetLastSummary != null) {
        onSetLastSummary!('Action failed: drive_to X:$x, Y:$y failed. No path found.');
      }
    } else {
      onLog('sys', 'Path planned. Executing…');
      if (onSetLastSummary != null) {
        onSetLastSummary!('Action succeeded: path to X:$x, Y:$y planned and execution started.');
      }
    }
  }

  Future<void> _dance(SkillAction a) async {
    final style = a.param('style', 'happy');
    onLog('cmd', 'dance: $style');
    switch (style) {
      case 'victory':
        for (var i = 0; i < 3; i++) {
          await onBle(KodaCmd.turnCw, 80, 300);
          await onBle(KodaCmd.turnCcw, 80, 300);
        }
        break;
      case 'silly':
        await onBle(KodaCmd.forward, 40, 300);
        await onBle(KodaCmd.turnCw, 60, 400);
        await onBle(KodaCmd.backward, 40, 300);
        break;
      default: // happy
        await onBle(KodaCmd.turnCw, 65, 400);
        await onBle(KodaCmd.turnCcw, 65, 400);
    }
  }

  Future<void> _reportStatus(SkillAction a) async {
    final msg = "I've been running for ${getUptime()}. "
        "BLE is ${getIsConnected() ? 'connected' : 'disconnected'}. "
        "I have ${getMemoryCount()} memories.";
    await _speech(SkillAction(skill: 'speech', params: {'text': msg}));
  }

  Future<void> _saveMemory(SkillAction a) async {
    final fact = a.param('fact', '');
    if (fact.isNotEmpty) {
      onLog('sys', 'Saved memory: $fact');
      await onSaveMemory(fact);
    }
  }

  Future<void> _monitor(SkillAction a) async {
    final condition = a.param('condition', 'anything changes');
    onLog('sys', 'Starting monitor: $condition');
    _loopCount = 0;
    await Future.delayed(const Duration(seconds: 5));
    await onProcessInput(
      'Monitor the area. Has $condition occurred? If not, keep monitoring.',
      isLoopStep: true,
    );
  }

  Future<void> _patrol(SkillAction a) async {
    final target = a.param('target', 'intruder');
    onLog('sys', 'Starting patrol for: $target');
    _loopCount = 0;
    await onBle(KodaCmd.turnCw, 55, 600);
    await onProcessInput(
      'Patrol the area looking for $target. Move and evaluate repeatedly until found.',
      isLoopStep: true,
    );
  }

  Future<void> _visualAlign(SkillAction a) async {
    final point = a.params['point'] as List?;
    final label = a.param('label', 'object');
    if (point == null || point.length < 2) return;
    
    final x = (point[1] as num).toDouble();
    onLog('cmd', 'visual_align on $label at X:$x');

    if (x < 450) {
      // Turn CCW to center (object is to the left)
      final ms = ((450 - x) * 1.5).round().clamp(200, 800);
      await onBle(KodaCmd.turnCcw, 55, ms);
    } else if (x > 550) {
      // Turn CW to center (object is to the right)
      final ms = ((x - 550) * 1.5).round().clamp(200, 800);
      await onBle(KodaCmd.turnCw, 55, ms);
    } else {
      onLog('sys', '$label is already centered.');
    }
  }

  Future<void> _driveToObject(SkillAction a) async {
    final box = a.params['box_2d'] as List?;
    final label = a.param('label', 'object');
    if (box == null || box.length < 4) return;

    final ymin = (box[0] as num).toDouble();
    final xmin = (box[1] as num).toDouble();
    final ymax = (box[2] as num).toDouble();
    final xmax = (box[3] as num).toDouble();
    final xCenter = (xmin + xmax) / 2;
    final height = ymax - ymin;

    onLog('cmd', 'drive_to_object: $label (height: $height)');

    // 1. Align first
    if (xCenter < 450) {
      await onBle(KodaCmd.turnCcw, 55, 400);
    } else if (xCenter > 550) {
      await onBle(KodaCmd.turnCw, 55, 400);
    }

    // 2. Drive forward based on height (rough heuristic: small object = far away)
    // If height < 40% of image, it's far.
    if (height < 400) {
      await _move(SkillAction(skill: 'move', params: {
        'direction': 'forward',
        'speed': 60,
        'ms': (600 - height).round().clamp(500, 1500)
      }));
    } else {
      onLog('sys', '$label is close enough.');
    }
  }

  Future<void> _changeScreen(SkillAction a) async {
    final target = a.param('screen', 'brain');
    onLog('cmd', 'change_screen: $target');
    
    int index = 1; // Default to Brain
    if (target == 'home') index = 0;
    else if (target == 'brain') index = 1;
    else if (target == 'remote') index = 2;
    else if (target == 'settings') index = 3;

    await onChangeScreen(index);
  }

  Future<void> _showDisplay(SkillAction a) async {
    final typeStr   = a.param('type', 'face');
    final seconds   = a.paramInt('seconds', 0);
    final url       = a.param('url', '');
    final text      = a.param('text', '');
    final title     = a.param('title', '');
    final subtitle  = a.param('subtitle', '');
    final temp      = a.param('temp', '');
    final condition = a.param('condition', '');

    onLog('cmd', 'show_display type:$typeStr seconds:$seconds url:$url text:$text title:$title subtitle:$subtitle temp:$temp condition:$condition');

    final type = CanvasType.values.firstWhere(
      (e) => e.name == typeStr,
      orElse: () => CanvasType.face,
    );

    onSetCanvas(CanvasContent(
      type: type,
      url: url.isNotEmpty ? url : null,
      seconds: seconds > 0 ? seconds : null,
      text: text.isNotEmpty ? text : null,
      title: title.isNotEmpty ? title : null,
      subtitle: subtitle.isNotEmpty ? subtitle : null,
      temp: temp.isNotEmpty ? temp : null,
      condition: condition.isNotEmpty ? condition : null,
    ));
  }
}
