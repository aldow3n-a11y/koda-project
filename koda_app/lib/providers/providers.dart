import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:camera/camera.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../models/models.dart';
import '../services/ble_service.dart';
import '../services/llm_service.dart';
import '../services/voice_service.dart';
import '../services/context_service.dart';
import '../services/skill_executor.dart';
import '../services/lidar_service.dart';
import '../services/slam_service.dart';

// ─── Camera Provider ──────────────────────────────────────────────────────────
final cameraControllerProvider = StateProvider<CameraController?>((ref) => null);

// ─── Remote Control Speed ─────────────────────────────────────────────────────
final remoteSpeedProvider = StateProvider<int>((ref) => 60);

// ─── Services (singletons) ────────────────────────────────────────────────────
final lidarServiceProvider = Provider<LidarService>((ref) {
  final s = LidarService();
  // Note: settingsProvider._load() is async, so we can't read the saved value here.
  // Instead we set the default and let SettingsNotifier sync it once _load() completes.
  s.angularOffsetDeg = 40.0;
  ref.onDispose(s.dispose);
  return s;
});

final slamServiceProvider = Provider<SlamService>((ref) => SlamService());

final bleServiceProvider = Provider<BleService>((ref) {
  final s = BleService();
  // Inject LidarService so BLE callbacks route to it
  s.lidarService = ref.read(lidarServiceProvider);
  ref.onDispose(s.dispose);
  return s;
});

final llmServiceProvider = Provider<LlmService>((ref) => LlmService());
final ttsServiceProvider = Provider<TtsService>((ref) {
  final s = TtsService();
  final savedVoice = ref.read(settingsProvider).ttsVoice;
  s.init(savedVoiceName: savedVoice == 'en-US' ? null : savedVoice);
  ref.onDispose(s.dispose);
  return s;
});
final sttServiceProvider = Provider<SttService>((ref) {
  final s = SttService();
  s.init();
  ref.onDispose(s.dispose);
  return s;
});
final contextServiceProvider = Provider<ContextService>((ref) => ContextService());

// ─── Settings Provider ────────────────────────────────────────────────────────
class SettingsNotifier extends StateNotifier<AppSettings> {
  final Ref _ref;

  SettingsNotifier(this._ref) : super(const AppSettings()) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('app_settings');
    if (raw != null) {
      state = AppSettings.fromJson(jsonDecode(raw));
      // Sync loaded offset to LidarService immediately
      _ref.read(lidarServiceProvider).angularOffsetDeg = state.lidarAngularOffset;
    }
  }

  Future<void> update(AppSettings settings) async {
    state = settings;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_settings', jsonEncode(settings.toJson()));
    // Sync lidar offset live — user sees map update as they drag slider
    _ref.read(lidarServiceProvider).angularOffsetDeg = settings.lidarAngularOffset;
  }

  Future<void> updateField(AppSettings Function(AppSettings) fn) async {
    await update(fn(state));
  }
}

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, AppSettings>((ref) {
  return SettingsNotifier(ref);
});

// ─── Motor Config Provider ────────────────────────────────────────────────────
class MotorConfigNotifier extends StateNotifier<MotorConfig> {
  MotorConfigNotifier() : super(const MotorConfig()) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('motor_config');
    if (raw != null) state = MotorConfig.fromJson(jsonDecode(raw));
  }

  Future<void> update(MotorConfig config) async {
    state = config;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('motor_config', jsonEncode(config.toJson()));
  }

  void setTrim({int? fl, int? fr, int? rl, int? rr}) {
    update(state.copyWith(fl: fl, fr: fr, rl: rl, rr: rr));
  }

  void resetTrim() {
    update(state.copyWith(fl: 100, fr: 100, rl: 100, rr: 100));
  }
}

final motorConfigProvider =
    StateNotifierProvider<MotorConfigNotifier, MotorConfig>((ref) {
  return MotorConfigNotifier();
});

// ─── BLE Connection State ─────────────────────────────────────────────────────
class BleConnectionNotifier extends StateNotifier<BleConnectionState> {
  final BleService _ble;

  BleConnectionNotifier(this._ble) : super(const BleConnectionState()) {
    _ble.statusStream.listen((status) {
      state = state.copyWith(status: status);
    });
    _ble.devicesStream.listen((devices) {
      state = state.copyWith(scannedDevices: devices);
    });
    _ble.logStream.listen((log) {
      state = state.copyWith(
        logs: [...state.logs.takeLast(49), log],
      );
    });
  }

  Future<void> scan() => _ble.startScan();
  void stopScan() => _ble.stopScan();

  Future<bool> connect(KodaBtDevice device) async {
    final ok = await _ble.connect(device);
    if (ok) state = state.copyWith(connectedDevice: device);
    return ok;
  }

  Future<void> disconnect() async {
    await _ble.disconnect();
    state = state.copyWith(connectedDevice: null);
  }

  Future<bool> sendCommand(MotorCommand cmd) => _ble.sendCommand(cmd);
  Future<bool> sendBatch(List<MotorCommand> cmds) => _ble.sendCommandBatch(cmds);
  Future<bool> sendStop() => _ble.sendStop();
}

class BleConnectionState {
  final BleStatus status;
  final KodaBtDevice? connectedDevice;
  final List<KodaBtDevice> scannedDevices;
  final List<String> logs;

  const BleConnectionState({
    this.status = BleStatus.idle,
    this.connectedDevice,
    this.scannedDevices = const [],
    this.logs = const [],
  });

  bool get isConnected => status == BleStatus.connected;
  bool get isScanning  => status == BleStatus.scanning;

  BleConnectionState copyWith({
    BleStatus? status,
    KodaBtDevice? connectedDevice,
    List<KodaBtDevice>? scannedDevices,
    List<String>? logs,
  }) =>
      BleConnectionState(
        status: status ?? this.status,
        connectedDevice: connectedDevice ?? this.connectedDevice,
        scannedDevices: scannedDevices ?? this.scannedDevices,
        logs: logs ?? this.logs,
      );
}

extension TakeLast<T> on List<T> {
  List<T> takeLast(int n) => length <= n ? this : sublist(length - n);
}

final bleConnectionProvider =
    StateNotifierProvider<BleConnectionNotifier, BleConnectionState>((ref) {
  return BleConnectionNotifier(ref.watch(bleServiceProvider));
});

// ─── LiDAR + SLAM Provider ────────────────────────────────────────────────────

class LidarState {
  final bool      isReceiving;
  final int       pointCount;
  final int       revision;
  final double?   nearestMm;
  final double?   nearestAngleDeg;
  final SlamMode  slamMode;
  final int       bootstrapSecsLeft;  // countdown during bootstrap phase
  final bool      hasSavedMap;

  const LidarState({
    this.isReceiving       = false,
    this.pointCount        = 0,
    this.revision          = 0,
    this.nearestMm,
    this.nearestAngleDeg,
    this.slamMode          = SlamMode.idle,
    this.bootstrapSecsLeft = 0,
    this.hasSavedMap       = false,
  });

  LidarState copyWith({
    bool?     isReceiving,
    int?      pointCount,
    int?      revision,
    double?   nearestMm,
    double?   nearestAngleDeg,
    SlamMode? slamMode,
    int?      bootstrapSecsLeft,
    bool?     hasSavedMap,
  }) => LidarState(
    isReceiving:       isReceiving       ?? this.isReceiving,
    pointCount:        pointCount        ?? this.pointCount,
    revision:          revision          ?? this.revision,
    nearestMm:         nearestMm         ?? this.nearestMm,
    nearestAngleDeg:   nearestAngleDeg   ?? this.nearestAngleDeg,
    slamMode:          slamMode          ?? this.slamMode,
    bootstrapSecsLeft: bootstrapSecsLeft ?? this.bootstrapSecsLeft,
    hasSavedMap:       hasSavedMap       ?? this.hasSavedMap,
  );
}

class LidarNotifier extends StateNotifier<LidarState> {
  final LidarService  _lidar;
  final SlamService   _slam;
  StreamSubscription? _scanSub;

  LidarNotifier(this._lidar, this._slam) : super(const LidarState()) {
    // Wire SLAM mode/bootstrap changes to state
    _slam.onStateChange = (mode, secsLeft) {
      state = state.copyWith(slamMode: mode, bootstrapSecsLeft: secsLeft);
    };
    _scanSub = _lidar.scanStream.listen(_onScan);
    _initOnBoot();
  }

  /// On boot: check for saved map — load it, else start bootstrap.
  Future<void> _initOnBoot() async {
    final has = await SlamService.hasSavedMap();
    if (has) {
      final loaded = await _slam.loadMap();
      state = state.copyWith(
        hasSavedMap: loaded,
        slamMode: loaded ? SlamMode.navigation : SlamMode.idle,
      );
    } else {
      // No map — start bootstrap immediately
      _slam.startBootstrap();
      state = state.copyWith(
        hasSavedMap: false,
        slamMode: SlamMode.bootstrap,
        bootstrapSecsLeft: 10,
      );
    }
  }

  void _onScan(LidarScan scan) {
    _slam.integrateScan(scan);
    state = state.copyWith(
      isReceiving:     true,
      pointCount:      scan.pointCount,
      revision:        state.revision + 1,
      nearestMm:       scan.nearestDistanceMm,
      nearestAngleDeg: scan.nearestAngleDeg,
      slamMode:        _slam.mode,
      bootstrapSecsLeft: _slam.bootstrapSecsLeft,
    );
  }

  void notifyMotorCommand(String cmd, int speedPct, int durationMs) {
    _slam.updatePoseFromCommand(
      cmd: cmd, speedPct: speedPct, durationMs: durationMs,
    );
  }

  /// Reset + restart bootstrap
  void resetMap() {
    _slam.resetMap();
    _lidar.reset();
    _slam.startBootstrap();
    state = state.copyWith(
      isReceiving: false,
      pointCount: 0,
      revision: state.revision + 1,
      nearestMm: null,
      nearestAngleDeg: null,
      slamMode: SlamMode.bootstrap,
      bootstrapSecsLeft: 10,
    );
  }

  /// Save map to disk
  Future<bool> saveMap() async {
    final ok = await _slam.saveMap();
    if (ok) state = state.copyWith(hasSavedMap: true);
    return ok;
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    super.dispose();
  }
}

final lidarProvider =
    StateNotifierProvider<LidarNotifier, LidarState>((ref) {
  return LidarNotifier(
    ref.watch(lidarServiceProvider),
    ref.watch(slamServiceProvider),
  );
});

// ─── Brain Mode Provider ──────────────────────────────────────────────────────
enum BrainStatus { idle, listening, thinking, executing, speaking }

class BrainState {
  final bool active;
  final BrainStatus status;
  final List<BrainLogEntry> log;
  final String currentSpeech;
  final int interactionCount;
  final List<String> memories;
  final DateTime? startTime;
  final RobotEmotion currentEmotion;

  const BrainState({
    this.active = false,
    this.status = BrainStatus.idle,
    this.log = const [],
    this.currentSpeech = '',
    this.interactionCount = 0,
    this.memories = const [],
    this.startTime,
    this.currentEmotion = RobotEmotion.neutral,
  });

  String get uptimeString {
    if (startTime == null) return '00:00:00';
    final d = DateTime.now().difference(startTime!);
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  BrainState copyWith({
    bool? active, BrainStatus? status, List<BrainLogEntry>? log,
    String? currentSpeech, int? interactionCount,
    List<String>? memories, DateTime? startTime,
    RobotEmotion? currentEmotion,
  }) =>
      BrainState(
        active: active ?? this.active,
        status: status ?? this.status,
        log: log ?? this.log,
        currentSpeech: currentSpeech ?? this.currentSpeech,
        interactionCount: interactionCount ?? this.interactionCount,
        memories: memories ?? this.memories,
        startTime: startTime ?? this.startTime,
        currentEmotion: currentEmotion ?? this.currentEmotion,
      );
}

class BrainLogEntry {
  final String time;
  final String type; // sys | koda | cmd | err | user
  final String message;

  BrainLogEntry(this.type, this.message) : time = _now();

  static String _now() {
    final n = DateTime.now();
    return '${n.hour.toString().padLeft(2, '0')}:'
        '${n.minute.toString().padLeft(2, '0')}:'
        '${n.second.toString().padLeft(2, '0')}';
  }
}

class BrainNotifier extends StateNotifier<BrainState> {
  final LlmService _llm;
  final TtsService _tts;
  final SttService _stt;
  final BleConnectionNotifier _bleNotifier;
  final ContextService _ctx;
  final Ref _ref;
  Timer? _uptimeTimer;
  late final SkillExecutor _skillExecutor;
  String _systemPrompt = '';
  String _recentHistoryStr = '';
  DateTime? _lastApiCallTime;
  int _processingDepth = 0;
  bool _cancelRequested = false;

  BrainNotifier(this._llm, this._tts, this._stt, this._bleNotifier, this._ctx, this._ref)
      : super(const BrainState()) {
    _skillExecutor = SkillExecutor(
      onBle: (cmd, speed, ms) async {
        await _bleNotifier.sendCommand(MotorCommand(cmd: cmd, speed: speed, ms: ms));
        // Notify SLAM dead-reckoning of movement
        _ref.read(lidarProvider.notifier).notifyMotorCommand(
          cmd.name, speed, ms,
        );
        if (ms > 0) await Future.delayed(Duration(milliseconds: ms + 80));
      },
      onSpeak: (text) => _tts.speak(text),
      onLog: (type, msg) => addLog(type, msg),
      onProcessInput: (input, {isLoopStep = false}) =>
          processInput(input, isLoopStep: isLoopStep, isInternal: true),
      onStartListen: ({required onResult}) =>
          _stt.startListening(onResult: onResult),
      onStopListen: () => _stt.stopListening(),
      getMaxLoop: () => _ref.read(settingsProvider).maxLoopIterations,
      getUptime: () => state.uptimeString,
      getIsConnected: () => _ref.read(bleConnectionProvider).isConnected,
      getMemoryCount: () => state.memories.length,
      onSetEmotion: (emotion) => setEmotion(emotion),
    );
  }

  /// Public — lets SkillExecutor post entries to the activity log
  void addLog(String type, String message) => _addLog(type, message);

  void _addLog(String type, String message) {
    state = state.copyWith(
      log: [...state.log.takeLast(199), BrainLogEntry(type, message)],
    );
    _ctx.appendSessionLog('[$type] $message');
  }

  void setEmotion(RobotEmotion emotion) {
    state = state.copyWith(currentEmotion: emotion);
  }

  Future<void> activate() async {
    final settings = _ref.read(settingsProvider);
    _llm.configure(
      apiKey: settings.apiKey,
      model: settings.model,
      customApiUrl: settings.customApiUrl,
      maxTokens: settings.maxTokens,
    );

    await _ctx.init();
    _addLog('sys', 'Loading context files…');
    _systemPrompt = await _ctx.buildSystemPrompt();
    _addLog('sys', 'Context loaded (${_systemPrompt.length} chars)');

    // Non-blocking memory extraction from last session log
    _extractMemoryInBackground();

    await _ctx.startSession();
    _recentHistoryStr = await _ctx.getRecentHistoryString(10);

    state = state.copyWith(
      active: true,
      status: BrainStatus.listening,
      startTime: DateTime.now(),
    );
    _addLog('sys', 'Brain mode activated. Model: ${settings.model}');

    if (settings.keepScreenAwake) WakelockPlus.enable();

    _uptimeTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      state = state.copyWith();
    });

    await _tts.speak("Hello! I'm Koda. Ready to explore.");
    _addLog('koda', "Hello! I'm Koda. Ready to explore.");

    if (settings.voiceEnabled) _startListening();
  }

  Future<void> _extractMemoryInBackground() async {
    try {
      final prompt = await _ctx.buildMemoryExtractionPrompt();
      if (prompt == null) return;
      _addLog('sys', 'Extracting memories from last session…');
      final result = await _llm.callRaw(prompt);
      if (result != null && result.trim() != 'NONE') {
        await _ctx.appendMemory(result);
        _addLog('sys', 'Memory updated.');
        _systemPrompt = await _ctx.buildSystemPrompt();
      }
    } catch (_) {}
  }

  void deactivate() {
    _uptimeTimer?.cancel();
    _stt.stopListening();
    _tts.stop();
    WakelockPlus.disable();
    state = state.copyWith(active: false, status: BrainStatus.idle);
    _addLog('sys', 'Brain mode deactivated.');
  }

  void forceListenOnce(VoidCallback onDone) {
    if (_processingDepth > 0) {
      _cancelRequested = true;
      _tts.stop();
      _stt.stopListening();
      _bleNotifier.sendCommand(const MotorCommand(cmd: KodaCmd.stop, ms: 0));
      _addLog('sys', 'Processing interrupted by user.');
    }

    _stt.startListening(
      onResult: (text) async {
        if (text.isNotEmpty) {
          _addLog('user', text);
          _stt.stopListening();
          onDone();
          await processInput(text);
        }
      },
    );
  }

  void _startListening() {
    final settings = _ref.read(settingsProvider);
    _stt.startListening(
      onResult: (text) async {
        _addLog('user', text);
        if (_stt.containsWakeWord(text, settings.wakeWord)) {
          final cmd = _stt.stripWakeWord(text, settings.wakeWord);
          await processInput(cmd.isNotEmpty ? cmd : 'hello');
        }
      },
    );
  }

  Future<void> processInput(String input, {bool isLoopStep = false, bool isInternal = false}) async {
    if (!state.active) return;
    
    if (_processingDepth == 0) _cancelRequested = false;
    if (_cancelRequested) return;

    if (_processingDepth > 0 && !isInternal) {
      _addLog('sys', 'System busy. Ignoring input: $input');
      return;
    }
    
    _processingDepth++;
    try {
      if (!isLoopStep) _skillExecutor.resetLoopCount();

    state = state.copyWith(status: BrainStatus.thinking);
    _addLog('sys', 'Thinking…');

    // Capture image from camera
    List<int>? imageBytes;
    String? visionContext;
    final camera = _ref.read(cameraControllerProvider);
    if (camera != null && camera.value.isInitialized) {
      try {
        final lens = camera.description.lensDirection;
        visionContext = lens == CameraLensDirection.front
            ? 'FRONT camera active — vision points BACKWARD relative to wheels.'
            : 'REAR camera active — vision points FORWARD relative to wheels.';

        if (!camera.value.isTakingPicture) {
          final xfile = await camera.takePicture();
          final rawBytes = await xfile.readAsBytes();
          
          _addLog('sys', 'Captured ${rawBytes.length ~/ 1024}KB raw image');
          // Since we use ResolutionPreset.medium (720x480), the image is small enough (~140KB).
          // The API occasional failures are likely Google rate-limits, so we keep the resolution
          // high enough for OCR/character reading without scaling it down.
          imageBytes = rawBytes;

          _addLog('sys', 'Sending ${imageBytes.length ~/ 1024}KB to LLM');
        } else {
          _addLog('sys', 'Camera busy — skipping image');
        }
      } catch (e) {
        _addLog('sys', 'Camera error: $e');
      }
    }

    final recentMem = state.log
        .where((e) => e.type == 'user' || e.type == 'koda')
        .toList();
    final currentHist = recentMem.length <= 10 ? recentMem : recentMem.sublist(recentMem.length - 10);
    final historyStr = currentHist.map((e) => '${e.type.toUpperCase()}: ${e.message}').join('\n');
    
    final fullHistory = '$_recentHistoryStr\n$historyStr'.trim();
    
    String dynamicSystemPrompt = fullHistory.isEmpty 
        ? _systemPrompt 
        : '$_systemPrompt\n\n### RECENT CONVERSATION HISTORY\n$fullHistory\n\n(Use this history for conversational context across tasks. Do not repeat yourself.)';

    // Append live LiDAR obstacle data to prompt if sensor is active
    final lidarState = _ref.read(lidarProvider);
    if (lidarState.isReceiving && lidarState.nearestMm != null) {
      final distCm  = (lidarState.nearestMm! / 10).round();
      final angleDeg = lidarState.nearestAngleDeg?.toStringAsFixed(0) ?? '?';
      dynamicSystemPrompt +=
          '\n\n### LIVE OBSTACLE SENSOR\n'
          'Nearest obstacle: ${distCm}cm at ${angleDeg}° '
          '(0°=forward, 90°=right, 180°=behind, 270°=left)\n'
          'Use this to avoid collisions and make spatial decisions.';
    }

    // Enforce LLM request cooldown to prevent rate limiting
    final cooldownMs = _ref.read(settingsProvider).llmCooldownMs;
    if (_lastApiCallTime != null) {
      final elapsed = DateTime.now().difference(_lastApiCallTime!).inMilliseconds;
      if (elapsed < cooldownMs) {
        final waitTime = cooldownMs - elapsed;
        _addLog('sys', 'Cooldown: Waiting ${waitTime}ms…');
        await Future.delayed(Duration(milliseconds: waitTime));
      }
    }
    _lastApiCallTime = DateTime.now();

    // Force the LLM to remember the output format at the very end of the prompt
    final enforcedInput = '$input\n\n[SYSTEM REMINDER: You MUST respond ONLY with the valid JSON unified command format containing the "actions" array. Do not output any conversational text outside of the JSON.]';

    final response = await _llm.chat(
      userMessage: enforcedInput,
      systemPrompt: dynamicSystemPrompt,
      imageBytes: imageBytes,
      visionContext: visionContext,
    );

    if (response == null) {
      _addLog('err', 'LLM call failed. Check API key and model.');
      state = state.copyWith(status: BrainStatus.listening);
      if (_ref.read(settingsProvider).voiceEnabled) _startListening();
      return;
    }

    if (response.context.isNotEmpty) {
      await _ctx.appendSessionLog('[context] ${response.context}');
    }

    // Execute all actions in sequence
    state = state.copyWith(status: BrainStatus.executing);
    for (final action in response.actions) {
      if (!state.active || _cancelRequested) break;
      await _skillExecutor.run(action);
    }

    state = state.copyWith(
      status: BrainStatus.listening,
      interactionCount: state.interactionCount + 1,
    );

    // Resume voice listening unless a skill will do it (listen/explore/evaluate_location)
    final hasOpenLoop = response.actions.any(
      (a) => a.skill == 'listen' || a.skill == 'evaluate_location' || a.skill == 'explore',
    );
    if (state.active && _ref.read(settingsProvider).voiceEnabled && !hasOpenLoop) {
      _startListening();
    }
    } finally {
      _processingDepth--;
    }
  }
}

final brainProvider = StateNotifierProvider<BrainNotifier, BrainState>((ref) {
  return BrainNotifier(
    ref.watch(llmServiceProvider),
    ref.watch(ttsServiceProvider),
    ref.watch(sttServiceProvider),
    ref.read(bleConnectionProvider.notifier),
    ref.watch(contextServiceProvider),
    ref,
  );
});
