import 'dart:async';
import '../models/models.dart';

typedef SendBleCmd = Future<void> Function(KodaCmd cmd, int speed, int ms);
typedef SpeakFn = Future<void> Function(String text);
typedef LogFn = void Function(String type, String message);
typedef ProcessInputFn = Future<void> Function(String input, {bool isLoopStep});
typedef StartListenFn = void Function({required void Function(String) onResult});
typedef StopListenFn = void Function();
typedef GetMaxLoopFn = int Function();
typedef GetUptimeFn = String Function();
typedef GetIsConnectedFn = bool Function();
typedef GetMemoryCountFn = int Function();
typedef SetEmotionFn = void Function(RobotEmotion emotion);

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
  });

  void resetLoopCount() => _loopCount = 0;

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
    'dance':             _dance,
    'report_status':     _reportStatus,
  };

  // ── Handlers ──────────────────────────────────────────────────────────────

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
        await onBle(KodaCmd.forward, 30, 200);
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
    }
  }

  Future<void> _speech(SkillAction a) async {
    final text = a.param('text', '');
    if (text.isEmpty) return;
    onLog('koda', text);
    await onSpeak(text);
  }

  Future<void> _move(SkillAction a) async {
    final dir = a.param('direction', 'forward');
    final speed = a.paramInt('speed', 55);
    final ms = a.paramInt('ms', 800);
    final cmd = dir == 'backward' ? KodaCmd.backward : KodaCmd.forward;
    onLog('cmd', 'move $dir speed:$speed ms:$ms');
    await onBle(cmd, speed, ms);
  }

  Future<void> _turn(SkillAction a) async {
    final dir = a.param('direction', 'cw');
    final speed = a.paramInt('speed', 45);
    final ms = a.paramInt('ms', 400);
    final cmd = dir == 'ccw' ? KodaCmd.turnCcw : KodaCmd.turnCw;
    onLog('cmd', 'turn $dir speed:$speed ms:$ms');
    await onBle(cmd, speed, ms);
  }

  Future<void> _listen(SkillAction a) async {
    final timeout = a.paramInt('timeout', 10);
    onLog('sys', 'Listening for ${timeout}s…');

    final completer = Completer<String>();
    final timer = Timer(Duration(seconds: timeout), () {
      if (!completer.isCompleted) completer.complete('');
    });

    onStartListen(onResult: (text) {
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
      await _speech(SkillAction(
        skill: 'speech',
        params: {'text': "I've looked around a lot. What should I do next?"},
      ));
      return;
    }
    onLog('sys', 'Evaluate location (step $_loopCount/$maxIter)…');
    await Future.delayed(const Duration(milliseconds: 500));
    await onProcessInput(
      'Analyze what\'s in front of Koda. Identify obstacles, people, or objects of interest. Then decide what to do next.',
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
}
