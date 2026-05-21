import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:camera/camera.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:image/image.dart' as img;
import '../models/models.dart';
import '../services/ble_service.dart';
import '../services/llm_service.dart';
import '../services/voice_service.dart';
import '../services/context_service.dart';
import '../services/skill_executor.dart';
import '../services/lidar_service.dart';
import '../services/slam_service.dart';
import '../services/imu_service.dart';
import '../services/object_tracker_service.dart';

// ─── Camera Provider ──────────────────────────────────────────────────────────
final cameraControllerProvider = StateProvider<CameraController?>((ref) => null);

// ─── Face / Object Tracking ───────────────────────────────────────────────────
final faceTrackingEnabledProvider = StateProvider<bool>((ref) => false);
final objectTrackingDataProvider = StateProvider<ObjectTrackingData?>((ref) => null);

final objectTrackerServiceProvider = Provider<ObjectTrackerService>((ref) {
  final service = ObjectTrackerService();
  ref.onDispose(service.dispose);
  return service;
});

// ─── Remote Control Speed ─────────────────────────────────────────────────────
final remoteSpeedProvider = StateProvider<int>((ref) => 60);

// ─── Active Page navigation Provider ──────────────────────────────────────────
final activePageProvider = StateProvider<int>((ref) => 0); // 0: Home, 1: Brain, 2: Remote, 3: Settings

// ─── Services (singletons) ────────────────────────────────────────────────────
final lidarServiceProvider = Provider<LidarService>((ref) {
  final s = LidarService();
  // Default angular offset — must match the calibrated value in AppSettings.
  // Update this if you recalibrate in the Settings page.
  s.angularOffsetDeg = 105.0;
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

final imuServiceProvider = Provider<ImuService>((ref) {
  final slam = ref.read(slamServiceProvider);
  final s = ImuService(slam);

  // Wire kidnap detection → trigger Gemini relocalization
  s.onKidnapped = () {
    final brain = ref.read(brainProvider.notifier);
    brain.addLog('sys', '[KIDNAP] Robot picked up! Requesting visual relocalization.');
    brain.interruptAndProcess(
      'SYSTEM ALERT: Koda has been picked up and placed at a new location. '
      'Your position coordinates are now UNKNOWN. Look around with evaluate_location '
      'and describe any visible landmarks to help figure out where you are.',
    );
  };

  // Wire tilt detection → trigger safety balance procedure
  s.onStuck = (reason) {
    if (reason == 'tilted') {
      final brain = ref.read(brainProvider.notifier);
      brain.addLog('sys', '[SAFETY] Robot tilted / lost balance!');
      brain.interruptAndProcess(
        'SYSTEM ALERT: Koda is tilted or has tipped over. Stop moving, explain to the user '
        'that you have lost balance / tipped over, ask the user to place you upright on flat ground, '
        'and use the listen skill to wait for help.',
      );
    }
  };

  ref.onDispose(s.stop);
  return s;
});

final llmServiceProvider = Provider<LlmService>((ref) => LlmService());
final ttsServiceProvider = Provider<TtsService>((ref) {
  final s = TtsService();
  ref.onDispose(s.dispose);
  return s;
});
final sttServiceProvider = Provider<SttService>((ref) {
  final s = SttService();
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
    }
    
    // Always sync state (either loaded or defaults) to services on startup
    _ref.read(lidarServiceProvider).angularOffsetDeg = state.lidarAngularOffset;
    
    final slam = _ref.read(slamServiceProvider);
    slam.setDecay(state.lidarDecaySec);
    slam.wheelbaseMm = state.wheelbaseMm;
    slam.mmPerSecAt100pct = state.mmPerSecAt100pct;
    slam.turnCalibrationFactor = state.turnCalibrationFactor;
    slam.useImuHeading = state.useImuHeading;
    
    final imu = _ref.read(imuServiceProvider);
    imu.invert = state.imuInvertTurn;
    if (state.useImuHeading) imu.start(); else imu.stop();
  }

  Future<void> update(AppSettings settings) async {
    state = settings;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_settings', jsonEncode(settings.toJson()));
    // Sync lidar offset live — user sees map update as they drag slider
    _ref.read(lidarServiceProvider).angularOffsetDeg = settings.lidarAngularOffset;
    // Sync decay timer live
    final slam = _ref.read(slamServiceProvider);
    slam.setDecay(settings.lidarDecaySec);
    slam.wheelbaseMm = settings.wheelbaseMm;
    slam.mmPerSecAt100pct = settings.mmPerSecAt100pct;
    slam.turnCalibrationFactor = settings.turnCalibrationFactor;
    slam.useImuHeading = settings.useImuHeading;
    
    final imu = _ref.read(imuServiceProvider);
    imu.invert = settings.imuInvertTurn;
    if (settings.useImuHeading) imu.start(); else imu.stop();
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
    _ble.bodyStateStream.listen((bodyState) {
      state = state.copyWith(bodyState: bodyState);
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
  final KodaBodyState? bodyState;

  const BleConnectionState({
    this.status = BleStatus.idle,
    this.connectedDevice,
    this.scannedDevices = const [],
    this.logs = const [],
    this.bodyState,
  });

  bool get isConnected => status == BleStatus.connected;
  bool get isScanning  => status == BleStatus.scanning;

  BleConnectionState copyWith({
    BleStatus? status,
    KodaBtDevice? connectedDevice,
    List<KodaBtDevice>? scannedDevices,
    List<String>? logs,
    KodaBodyState? bodyState,
  }) =>
      BleConnectionState(
        status: status ?? this.status,
        connectedDevice: connectedDevice ?? this.connectedDevice,
        scannedDevices: scannedDevices ?? this.scannedDevices,
        logs: logs ?? this.logs,
        bodyState: bodyState ?? this.bodyState,
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
  final double?   frontMm;
  final double?   leftMm;
  final double?   rightMm;
  final double?   backMm;
  final List<LidarPoint> points;

  const LidarState({
    this.isReceiving       = false,
    this.pointCount        = 0,
    this.revision          = 0,
    this.nearestMm,
    this.nearestAngleDeg,
    this.slamMode          = SlamMode.idle,
    this.bootstrapSecsLeft = 0,
    this.hasSavedMap       = false,
    this.frontMm,
    this.leftMm,
    this.rightMm,
    this.backMm,
    this.points            = const [],
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
    double?   frontMm,
    double?   leftMm,
    double?   rightMm,
    double?   backMm,
    List<LidarPoint>? points,
  }) => LidarState(
    isReceiving:       isReceiving       ?? this.isReceiving,
    pointCount:        pointCount        ?? this.pointCount,
    revision:          revision          ?? this.revision,
    nearestMm:         nearestMm         ?? this.nearestMm,
    nearestAngleDeg:   nearestAngleDeg   ?? this.nearestAngleDeg,
    slamMode:          slamMode          ?? this.slamMode,
    bootstrapSecsLeft: bootstrapSecsLeft ?? this.bootstrapSecsLeft,
    hasSavedMap:       hasSavedMap       ?? this.hasSavedMap,
    frontMm:           frontMm           ?? this.frontMm,
    leftMm:            leftMm            ?? this.leftMm,
    rightMm:           rightMm           ?? this.rightMm,
    backMm:            backMm            ?? this.backMm,
    points:            points            ?? this.points,
  );
}

class LidarNotifier extends StateNotifier<LidarState> {
  final LidarService  _lidar;
  final SlamService   _slam;
  final BleConnectionNotifier _bleNotifier;
  StreamSubscription? _scanSub;

  LidarNotifier(this._lidar, this._slam, this._bleNotifier) : super(const LidarState()) {
    // Wire SLAM mode/bootstrap changes to state
    _slam.onStateChange = (mode, secsLeft) {
      state = state.copyWith(slamMode: mode, bootstrapSecsLeft: secsLeft);
    };

    // Wire Local Planner driving loop commands to BLE
    _slam.onMotorCommand = (cmdStr, speed, ms) {
      final cmdEnum = KodaCmd.values.firstWhere((e) => e.name == cmdStr, orElse: () => KodaCmd.stop);
      _bleNotifier.sendCommand(MotorCommand(cmd: cmdEnum, speed: speed, ms: ms));
      notifyMotorCommand(cmdStr, speed, ms);
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
      frontMm:         scan.getSectorMin(0, 90),   // 90° front cone (±45° from forward)
      leftMm:          scan.getSectorMin(270, 60), // 60° left cone
      rightMm:         scan.getSectorMin(90, 60),  // 60° right cone
      backMm:          scan.getSectorMin(180, 60), // 60° back cone
      slamMode:        _slam.mode,
      bootstrapSecsLeft: _slam.bootstrapSecsLeft,
      points:          scan.points,
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
    ref.watch(bleConnectionProvider.notifier),
  );
});

// ─── Perception Layer ────────────────────────────────────────────────────────
class PerceptionState {
  final List<LidarPoint> scanPoints;
  final int frontCm;
  final int leftCm;
  final int rightCm;
  final int backCm;
  final ObjectTrackingData? trackingData;
  final KodaBodyState? bodyState;

  const PerceptionState({
    this.scanPoints = const [],
    this.frontCm = 255,
    this.leftCm = 255,
    this.rightCm = 255,
    this.backCm = 255,
    this.trackingData,
    this.bodyState,
  });

  PerceptionState copyWith({
    List<LidarPoint>? scanPoints,
    int? frontCm,
    int? leftCm,
    int? rightCm,
    int? backCm,
    ObjectTrackingData? trackingData,
    bool clearTrackingData = false,
    KodaBodyState? bodyState,
    bool clearBodyState = false,
  }) {
    return PerceptionState(
      scanPoints: scanPoints ?? this.scanPoints,
      frontCm: frontCm ?? this.frontCm,
      leftCm: leftCm ?? this.leftCm,
      rightCm: rightCm ?? this.rightCm,
      backCm: backCm ?? this.backCm,
      trackingData: clearTrackingData ? null : (trackingData ?? this.trackingData),
      bodyState: clearBodyState ? null : (bodyState ?? this.bodyState),
    );
  }
}

class PerceptionNotifier extends StateNotifier<PerceptionState> {
  final Ref _ref;

  PerceptionNotifier(this._ref) : super(const PerceptionState()) {
    // 1. Listen to LiDAR ranges
    _ref.listen<LidarState>(lidarProvider, (prev, next) {
      state = state.copyWith(
        scanPoints: next.points,
        frontCm: next.frontMm != null ? (next.frontMm! / 10).round() : 255,
        leftCm: next.leftMm != null ? (next.leftMm! / 10).round() : 255,
        rightCm: next.rightMm != null ? (next.rightMm! / 10).round() : 255,
        backCm: next.backMm != null ? (next.backMm! / 10).round() : 255,
      );
    });

    // 2. Listen to ML Kit Object tracking data
    _ref.listen<ObjectTrackingData?>(objectTrackingDataProvider, (prev, next) {
      state = state.copyWith(
        trackingData: next,
        clearTrackingData: next == null,
      );
    });

    // 3. Listen to incoming BLE KodaBodyState
    _ref.listen<BleConnectionState>(bleConnectionProvider, (prev, next) {
      if (next.bodyState != null) {
        state = state.copyWith(
          bodyState: next.bodyState,
          frontCm: next.bodyState!.frontCm,
          leftCm: next.bodyState!.leftCm,
          rightCm: next.bodyState!.rightCm,
        );
      } else if (next.bodyState == null && prev?.bodyState != null) {
        state = state.copyWith(clearBodyState: true);
      }
    });
  }
}

final perceptionProvider = StateNotifierProvider<PerceptionNotifier, PerceptionState>((ref) {
  return PerceptionNotifier(ref);
});

// ─── Cognition Layer ─────────────────────────────────────────────────────────
class CognitionState {
  final RobotEmotion activeEmotion;
  final Offset attentionTarget;
  final int arousalLevel;
  final bool isEmergencyActive;

  const CognitionState({
    this.activeEmotion = RobotEmotion.neutral,
    this.attentionTarget = Offset.zero,
    this.arousalLevel = 15,
    this.isEmergencyActive = false,
  });

  CognitionState copyWith({
    RobotEmotion? activeEmotion,
    Offset? attentionTarget,
    int? arousalLevel,
    bool? isEmergencyActive,
  }) {
    return CognitionState(
      activeEmotion: activeEmotion ?? this.activeEmotion,
      attentionTarget: attentionTarget ?? this.attentionTarget,
      arousalLevel: arousalLevel ?? this.arousalLevel,
      isEmergencyActive: isEmergencyActive ?? this.isEmergencyActive,
    );
  }
}

class CognitionNotifier extends StateNotifier<CognitionState> {
  final Ref _ref;
  DateTime _lastAlertTime = DateTime.fromMillisecondsSinceEpoch(0);

  CognitionNotifier(this._ref) : super(const CognitionState()) {
    // Listen to perception state to run Urgency Scorer
    _ref.listen<PerceptionState>(perceptionProvider, (prev, next) {
      _evaluateUrgency(next);
    });
  }

  void _evaluateUrgency(PerceptionState perception) {
    // 1. Urgency Scorer logic: check sector distances
    final int minDist = [
      perception.frontCm,
      perception.leftCm,
      perception.rightCm,
    ].reduce((a, b) => a < b ? a : b);

    // If an obstacle is extremely close (< 25cm)
    if (minDist < 25) {
      final now = DateTime.now();
      
      // ── Reflex Race Condition Guard ─────────────────────────────────────
      // If the LLM brain is already executing a turn/evasion command to handle
      // this very obstacle, do NOT override it with a blanket STOP.
      // The LLM command is the deliberate response; the reflex would cancel it.
      final brain = _ref.read(brainProvider.notifier);
      final reflexSuppressed = brain.isReflexSuppressed;
      // ────────────────────────────────────────────────────────────────────

      // Prevent rapid alert loops (cooldown 5 seconds for voice alert)
      final bool canSpeakAlert = now.difference(_lastAlertTime).inSeconds > 5;
      
      if (!reflexSuppressed && (!state.isEmergencyActive || state.arousalLevel < 90)) {
        state = state.copyWith(
          activeEmotion: RobotEmotion.surprised,
          arousalLevel: 95,
          isEmergencyActive: true,
          attentionTarget: perception.trackingData?.offset ?? Offset.zero,
        );

        // Command the BLE motor controller to STOP immediately
        _ref.read(bleConnectionProvider.notifier).sendCommand(
          const MotorCommand(cmd: KodaCmd.stop, ms: 0),
        );
      }

      if (canSpeakAlert && !reflexSuppressed) {
        _lastAlertTime = now;
        
        // If brain/agent mode is active, interrupt standard task and speak
        if (brain.state.active) {
          brain.interruptAndProcess(
            'SYSTEM ALERT: Immediate obstacle collision threat detected at distance $minDist cm! '
            'Stop, act startled/surprised, warn the user about the obstacle, and ask them to clear the path.',
          );
        }
      }
    } else {
      // Resolve emergency state when obstacles clear
      if (state.isEmergencyActive) {
        state = state.copyWith(
          arousalLevel: perception.bodyState?.arousal ?? 15,
          isEmergencyActive: false,
          activeEmotion: RobotEmotion.neutral,
        );
      }
    }

    // 2. Map tracking target or look drift to attention target
    if (!state.isEmergencyActive) {
      if (perception.trackingData != null) {
        state = state.copyWith(
          attentionTarget: perception.trackingData!.offset,
          arousalLevel: 60, // higher arousal when tracking an object
        );
      } else {
        // Fall back to calm drift / default
        state = state.copyWith(
          arousalLevel: perception.bodyState?.arousal ?? 15,
        );
      }
    }
  }

  void updateEmotion(RobotEmotion emotion) {
    state = state.copyWith(activeEmotion: emotion);
  }
}

final cognitionProvider = StateNotifierProvider<CognitionNotifier, CognitionState>((ref) {
  return CognitionNotifier(ref);
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
  final CanvasContent canvasContent;

  const BrainState({
    this.active = false,
    this.status = BrainStatus.idle,
    this.log = const [],
    this.currentSpeech = '',
    this.interactionCount = 0,
    this.memories = const [],
    this.startTime,
    this.currentEmotion = RobotEmotion.neutral,
    this.canvasContent = const CanvasContent(type: CanvasType.face),
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
    CanvasContent? canvasContent,
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
        canvasContent: canvasContent ?? this.canvasContent,
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
  Timer? _canvasResetTimer;
  late final SkillExecutor _skillExecutor;
  String _systemPrompt = '';
  String _recentHistoryStr = '';
  DateTime? _lastApiCallTime;
  int _processingDepth = 0;
  bool _cancelRequested = false;
  String? _pendingNextTaskPrompt;
  bool _pendingNextTaskIsLoop = false;
  int _waypointCounter = 0;
  String _lastSummary = 'Idle';
  List<int>? _initialTaskImage;

  /// When set, the cognition reflex STOP is suppressed until this time.
  /// This prevents the emergency stop from cancelling deliberate LLM turn commands.
  DateTime? _reflexSuppressedUntil;

  /// Returns true if the LLM is actively executing a motor command that should
  /// not be overridden by the reflexive emergency stop.
  bool get isReflexSuppressed {
    final until = _reflexSuppressedUntil;
    if (until == null) return false;
    return DateTime.now().isBefore(until);
  }

  BrainNotifier(this._llm, this._tts, this._stt, this._bleNotifier, this._ctx, this._ref)
      : super(const BrainState()) {
    _skillExecutor = SkillExecutor(
      onBle: (cmd, speed, ms) async {
        // Suppress kidnap detection while motors are running
        _ref.read(imuServiceProvider).setMotorActive();
        // ── Reflex Suppression ──────────────────────────────────────────────
        // If the LLM is issuing a turn/evasion command, suppress the cognition
        // layer's emergency STOP reflex for the duration of the maneuver.
        // This prevents the reflex from racing against and cancelling the turn.
        final isTurn = cmd == KodaCmd.turnCw || cmd == KodaCmd.turnCcw;
        final isMove = cmd == KodaCmd.forward || cmd == KodaCmd.backward;
        final isEvasion = isTurn || cmd == KodaCmd.backward;
        if (isEvasion && ms > 0) {
          _reflexSuppressedUntil = DateTime.now().add(Duration(milliseconds: ms + 600));
        }

        final slam = _ref.read(slamServiceProvider);
        final startHeading = slam.pose.heading;
        final startX = slam.pose.xMm;
        final startY = slam.pose.yMm;
        final startTime = DateTime.now();

        await _bleNotifier.sendCommand(MotorCommand(cmd: cmd, speed: speed, ms: ms));
        // Notify SLAM dead-reckoning of movement
        _ref.read(lidarProvider.notifier).notifyMotorCommand(
          cmd.name, speed, ms,
        );
        if (ms > 0) {
          await Future.delayed(Duration(milliseconds: ms + 80));

          // Calculate actual delta time
          final actualDt = DateTime.now().difference(startTime).inMilliseconds / 1000.0;
          final settings = _ref.read(settingsProvider);
          const emaAlpha = 0.15;

          if (isTurn && settings.useImuHeading && actualDt > 0.05) {
            final spd = settings.mmPerSecAt100pct * speed / 100.0;
            final expectedDeltaRad = (spd / (settings.wheelbaseMm / 2.0)) * actualDt;
            final isCw = cmd == KodaCmd.turnCw;
            final directionSign = isCw ? -1.0 : 1.0;
            final uncalibratedExpectedDelta = expectedDeltaRad * directionSign;

            final endHeading = slam.pose.heading;
            double actualDelta = endHeading - startHeading;
            actualDelta = (actualDelta + math.pi) % (2.0 * math.pi) - math.pi;

            if (uncalibratedExpectedDelta.abs() > 0.05 && actualDelta.abs() > 0.05) {
              final observedFactor = actualDelta / uncalibratedExpectedDelta;
              // Make sure direction aligns (observedFactor > 0) and is reasonable
              if (observedFactor > 0.1 && observedFactor < 2.5) {
                final currentFactor = settings.turnCalibrationFactor;
                final newFactor = currentFactor * (1.0 - emaAlpha) + observedFactor * emaAlpha;
                final clampedFactor = newFactor.clamp(0.1, 2.5);

                _addLog('sys', '[FEEDBACK] Turn calibration: expected=${uncalibratedExpectedDelta.toStringAsFixed(3)}rad, actual=${actualDelta.toStringAsFixed(3)}rad. Observed factor=${observedFactor.toStringAsFixed(3)}. Auto-tuning turnCalibrationFactor from ${currentFactor.toStringAsFixed(3)} to ${clampedFactor.toStringAsFixed(3)}');

                await _ref.read(settingsProvider.notifier).updateField(
                  (s) => s.copyWith(turnCalibrationFactor: clampedFactor),
                );
              }
            }
          } else if (isMove && actualDt > 0.05) {
            final isSlamActive = slam.mode == SlamMode.mapping || slam.mode == SlamMode.navigation;
            final isSlamValid = isSlamActive && !slam.isLost && slam.latestScan != null;

            final spd = settings.mmPerSecAt100pct * speed / 100.0;
            final expectedMoved = spd * actualDt;

            final endX = slam.pose.xMm;
            final endY = slam.pose.yMm;
            final dx = endX - startX;
            final dy = endY - startY;
            final actualMoved = math.sqrt(dx * dx + dy * dy);

            if (isSlamValid && expectedMoved > 50.0 && actualMoved > 10.0) {
              final observedSpeed = (actualMoved / actualDt) / (speed / 100.0);
              if (observedSpeed >= 100.0 && observedSpeed <= 600.0) {
                final currentSpeed = settings.mmPerSecAt100pct;
                final newSpeed = currentSpeed * (1.0 - emaAlpha) + observedSpeed * emaAlpha;
                final clampedSpeed = newSpeed.clamp(100.0, 600.0);

                _addLog('sys', '[FEEDBACK] Move calibration: expectedMoved=${expectedMoved.toStringAsFixed(1)}mm, actualMoved=${actualMoved.toStringAsFixed(1)}mm. Observed speed at 100%=${observedSpeed.toStringAsFixed(1)}mm/s. Auto-tuning mmPerSecAt100pct from ${currentSpeed.toStringAsFixed(1)} to ${clampedSpeed.toStringAsFixed(1)}');

                await _ref.read(settingsProvider.notifier).updateField(
                  (s) => s.copyWith(mmPerSecAt100pct: clampedSpeed),
                );
              }
            }
          }
        }
      },
      onSpeak: (text) => _tts.speak(text),
      onLog: (type, msg) => addLog(type, msg),
      onProcessInput: (input, {isLoopStep = false}) async {
        // Instead of recursive call, we set the pending prompt for the iterative loop
        _pendingNextTaskPrompt = input;
        _pendingNextTaskIsLoop = isLoopStep;
      },
      onStartListen: ({required onResult, timeoutSec = 10}) =>
          _stt.startListening(onResult: onResult, timeoutSec: timeoutSec),
      onStopListen: () => _stt.stopListening(),
      getMaxLoop: () => _ref.read(settingsProvider).maxLoopIterations,
      getUptime: () => state.uptimeString,
      getIsConnected: () => _ref.read(bleConnectionProvider).isConnected,
      getMemoryCount: () => state.memories.length,
      onSetEmotion: (emotion) => setEmotion(emotion),
      onSaveMemory: (fact) async {
        await _ctx.appendMemory('- $fact');
        // Instantly add to state so it's available without restarting Brain Mode
        state = state.copyWith(
          memories: [...state.memories, fact],
        );
        // Rebuild system prompt to include the new memory immediately
        _systemPrompt = await _ctx.buildSystemPrompt();
      },

      getLidarRange: (direction) {
        final perception = _ref.read(perceptionProvider);
        int? cm;
        switch (direction) {
          case 'forward':  cm = perception.frontCm; break;
          case 'backward': cm = perception.backCm;  break;
          case 'left':     cm = perception.leftCm;  break;
          case 'right':    cm = perception.rightCm; break;
        }
        return cm != null && cm != 255 ? cm * 10 : null; // mm output for skill logic
      },
      onPlanTo: (x, y) async => _ref.read(slamServiceProvider).driveTo(x, y),
      onChangeScreen: (index) async {
        _ref.read(activePageProvider.notifier).state = index;
      },
      onSetCanvas: (content) {
        state = state.copyWith(canvasContent: content);
      },
      onAnalyzeFrame: (headingStr) => _analyzeCurrentFrameForObjects(headingStr),
      getObjectTrackingData: () => _ref.read(perceptionProvider).trackingData,
      getCancelRequested: () => _cancelRequested,
      getTrackingEnabled: () => _ref.read(faceTrackingEnabledProvider),
      onSetTracking: (enabled) {
        _ref.read(faceTrackingEnabledProvider.notifier).state = enabled;
      },
      onSetLastSummary: (summary) {
        _lastSummary = summary;
        _addLog('sys', 'Action outcome: $summary');
      },
    );

    // Wire SlamService stuck detection
    _ref.read(slamServiceProvider).onStuck = (reason) {
      if (reason == 'stuck') {
        _addLog('sys', '[SAFETY] Robot is physically stuck!');
        interruptAndProcess(
          'SYSTEM ALERT: Koda is physically stuck. The wheels are spinning but the robot is not moving. '
          'Stop moving, explain to the user that you are stuck, ask for assistance, '
          'and use the listen skill to wait for help.',
        );
      }
    };

    // Listen to Cognition state changes to keep BrainState's emotion in sync
    _ref.listen<CognitionState>(cognitionProvider, (prev, next) {
      if (next.activeEmotion != state.currentEmotion) {
        state = state.copyWith(currentEmotion: next.activeEmotion);
      }
    });
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
    _canvasResetTimer?.cancel();
    state = state.copyWith(
      currentEmotion: emotion,
      canvasContent: const CanvasContent(type: CanvasType.face),
    );
    _ref.read(cognitionProvider.notifier).updateEmotion(emotion);
  }

  void setCanvasContent(CanvasContent content) {
    _canvasResetTimer?.cancel();
    state = state.copyWith(canvasContent: content);

    // Revert static image/gif display canvas back to face after 30 seconds
    if (content.type == CanvasType.image || content.type == CanvasType.gif) {
      _canvasResetTimer = Timer(const Duration(seconds: 30), () {
        if (state.canvasContent.type == content.type && state.canvasContent.url == content.url) {
          setCanvasContent(const CanvasContent(type: CanvasType.face));
        }
      });
    }
  }

  Future<void> activate() async {
    final settings = _ref.read(settingsProvider);
    _llm.configure(
      apiKey: settings.apiKey,
      model: settings.model,
      customApiUrl: settings.customApiUrl,
      maxTokens: settings.maxTokens,
      thinkingBudget: settings.thinkingBudget,
    );

    // Initialize local Gemma model if selected
    if (settings.model == 'gemma4-native') {
      try {
        _addLog('sys', 'Loading local Gemma 4 model…');
        // Path where we pushed the model via adb
        const modelPath = '/storage/emulated/0/Android/data/com.example.koda_app/files/gemma.litertlm';
        if (!FlutterGemma.hasActiveModel()) {
          await FlutterGemma.initialize();
          await FlutterGemma.installModel(
            modelType: ModelType.gemma4,
            fileType: ModelFileType.litertlm,
          ).fromFile(modelPath).install();
        }
        _addLog('sys', 'Gemma 4 model ready ✓');
      } catch (e) {
        _addLog('sys', 'Gemma 4 load failed: $e — using cloud fallback.');
      }
    }

    await _ctx.init();
    _addLog('sys', 'Loading context files…');
    _systemPrompt = await _ctx.buildSystemPrompt();
    _addLog('sys', 'Context loaded (${_systemPrompt.length} chars)');

    _addLog('sys', 'Initializing speech services…');
    await _tts.init(savedVoiceName: settings.ttsVoice == 'en-US' ? null : settings.ttsVoice);
    await _stt.init();

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

      // Auto STT restart disabled as requested.
    });

    await _tts.speak("Hello! I'm Koda. Ready to explore.");
    _addLog('koda', "Hello! I'm Koda. Ready to explore.");

    // STT is manual-only (mic button) — no auto-start here.
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
    _canvasResetTimer?.cancel();
    _stt.stopListening();
    _tts.stop();
    WakelockPlus.disable();
    state = state.copyWith(
      active: false,
      status: BrainStatus.idle,
      canvasContent: const CanvasContent(type: CanvasType.face),
    );
    _addLog('sys', 'Brain mode deactivated.');
  }

  @override
  void dispose() {
    _uptimeTimer?.cancel();
    _canvasResetTimer?.cancel();
    super.dispose();
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

  Future<void> interruptAndProcess(String alertText) async {
    // Revert screen to face and stop motors immediately on safety interruption
    setCanvasContent(const CanvasContent(type: CanvasType.face));
    await _bleNotifier.sendCommand(const MotorCommand(cmd: KodaCmd.stop, ms: 0));

    if (_processingDepth > 0) {
      _cancelRequested = true;
      _tts.stop();
      _stt.stopListening();
      _addLog('sys', 'Task interrupted by safety system.');
      
      // Wait for the active loop to exit and processingDepth to return to 0
      int retries = 0;
      while (_processingDepth > 0 && retries < 15) {
        await Future.delayed(const Duration(milliseconds: 100));
        retries++;
      }
    }
    
    // Now that we are idle, process the alert internally
    await processInput(alertText, isInternal: true);
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
      
      String currentInput = input;
      bool currentIsLoopStep = isLoopStep;
      bool taskSequenceActive = true;

      while (taskSequenceActive && state.active && !_cancelRequested) {
        _pendingNextTaskPrompt = null; // Clear any previous signal
        _pendingNextTaskIsLoop = false;

        state = state.copyWith(status: BrainStatus.thinking);
        _addLog('sys', isInternal ? 'Navigating…' : 'Thinking…');

        // Capture image from camera
        List<int>? imageBytes;
        String? visionContext;

        final inputLower = currentInput.toLowerCase();
        final containsVisionKeyword = inputLower.contains('see') ||
            inputLower.contains('look') ||
            inputLower.contains('find') ||
            inputLower.contains('watch') ||
            inputLower.contains('detect') ||
            inputLower.contains('identify') ||
            inputLower.contains('align') ||
            inputLower.contains('photo') ||
            inputLower.contains('camera') ||
            inputLower.contains('show') ||
            inputLower.contains('describe') ||
            inputLower.contains('what') ||
            inputLower.contains('where') ||
            inputLower.contains('who') ||
            inputLower.contains('which') ||
            inputLower.contains('scan') ||
            inputLower.contains('explore') ||
            inputLower.contains('patrol') ||
            inputLower.contains('monitor') ||
            inputLower.contains('remember') ||
            inputLower.contains('front') ||
            inputLower.contains('back') ||
            inputLower.contains('disappear') ||
            inputLower.contains('missing') ||
            inputLower.contains('change');

        final bool needsVision = currentIsLoopStep || containsVisionKeyword;

        if (needsVision) {
          final camera = _ref.read(cameraControllerProvider);
          if (camera != null && camera.value.isInitialized) {
            try {
              final lens = camera.description.lensDirection;
              visionContext = lens == CameraLensDirection.front
                  ? 'FRONT camera active — vision points BACKWARD relative to wheels.'
                  : 'REAR camera active — vision points FORWARD relative to wheels.';

              if (!camera.value.isTakingPicture) {
                final xfile = await camera.takePicture();
                
                // Run image read and compression in a background isolate to keep UI responsive and fast
                imageBytes = await compute(_readAndCompressImage, xfile.path);
                
                // Delete the temporary camera file to prevent storage/inode exhaustion
                try { File(xfile.path).deleteSync(); } catch (_) {}
                
                _addLog('sys', 'Vision: Compressed to ${(imageBytes?.length ?? 0) ~/ 1024}KB');
              } else {
                _addLog('sys', 'Camera busy — skipping image');
              }
            } catch (e) {
              _addLog('sys', 'Camera error: $e');
            }
          }
        } else {
          _addLog('sys', 'Text-only query: Skipping camera capture.');
        }

        // Read settings early — needed for isRoboticsER check below
        final settings = _ref.read(settingsProvider);

        // Multi-Image state comparison for Robotics-ER (Before/After)
        final List<List<int>> images = [];
        if (imageBytes != null) {
          final bool isRoboticsER = settings.model.toLowerCase().contains('robotics-er');
          if (isRoboticsER && _initialTaskImage != null && currentIsLoopStep) {
            // Send Previous image and Current image
            images.add(_initialTaskImage!);
            images.add(imageBytes);
            visionContext = (visionContext ?? '') + 
                '\nMULTI-VIEW MODE: Image 1 is BEFORE movement. Image 2 is AFTER movement (Current view).';
          } else {
            // First step, just send the current image
            images.add(imageBytes);
          }
          
          // Update the "before" image for the NEXT loop iteration
          _initialTaskImage = imageBytes;
        }

        // ─── ROS-Style Model Context Protocol (MCP) Prompt Construction ───
        
        // 1. Filtered Conversation History (Stateless Executive philosophy)
        // We only keep the very recent dialogue to prevent "Attention Dilution".
        final recentMem = state.log
            .where((e) => e.type == 'user' || e.type == 'koda')
            .toList();
        final currentHist = recentMem.length <= 5 ? recentMem : recentMem.sublist(recentMem.length - 5);
        final historyStr = currentHist.map((e) => '${e.type.toUpperCase()}: ${e.message}').join('\n');
        
        // 2. Semantic State Snapshot (The "Session Vector")
        final lidarState = _ref.read(lidarProvider);
        final slam = _ref.read(slamServiceProvider);
        final pose = slam.poseContext;
        
        final String stateSnapshot = '''
### INTERNAL STATE OF MIND
- Emotion: ${state.currentEmotion.name.toUpperCase()}
- Brain Status: ${state.status.name.toUpperCase()}
- Active Screen UI: ${state.canvasContent.type.name.toUpperCase()}

### ROBOT SPATIAL STATE (The Costmap)
- Current Position: X: ${pose["x"]}, Y: ${pose["y"]}
- Heading: ${pose["heading"]}
- Position Knowledge: ${pose["isLost"]}
- Waypoint Counter: $_waypointCounter steps in sequence
- Last Action Outcome: $_lastSummary

### LIDAR RANGE REPORT (Obstacle Sensors)
⚠️ LIDAR IS GROUND TRUTH. Visual impressions of walls are NOT reliable for distance. Always use LIDAR cm values below for navigation decisions.

${() {
  final fCm = lidarState.frontMm != null ? (lidarState.frontMm! / 10).round() : null;
  final lCm = lidarState.leftMm  != null ? (lidarState.leftMm!  / 10).round() : null;
  final rCm = lidarState.rightMm != null ? (lidarState.rightMm! / 10).round() : null;

  String verdict(int? cm) {
    if (cm == null) return 'CLEAR ✅ (no obstacle detected — SAFE to move)';
    if (cm >= 50) return '$cm cm ✅ SAFE (>50cm — move OR turn freely)';
    if (cm >= 25) return '$cm cm ⚠️ CAUTION (25–50cm — SAFE to turn, do NOT move forward)';
    return '$cm cm 🚫 BLOCKED (<25cm — MUST turn or back up)';
  }

  final fv = verdict(fCm);
  final lv = verdict(lCm);
  final rv = verdict(rCm);

  // Pre-compute recommended action
  String nav;
  if (fCm == null || fCm >= 50) {
    nav = '✅ MOVE FORWARD — path is clear (${fCm == null ? "no obstacle" : "${fCm}cm"})';
  } else if (fCm >= 25) {
    final bestTurn = (lCm ?? 9999) >= (rCm ?? 9999) ? 'CCW (left is more open)' : 'CW (right is more open)';
    nav = '⚠️ CAUTION AHEAD — DO NOT move forward. TURN $bestTurn to find a clear path.';
  } else {
    final bestTurn = (lCm ?? 9999) >= (rCm ?? 9999) ? 'CCW (left is more open)' : 'CW (right is more open)';
    nav = '🚫 BLOCKED — Back up or TURN $bestTurn immediately.';
  }

  return '''- FRONT: $fv
- LEFT:  $lv
- RIGHT: $rv
- BACK:  BLINDSPOT (Phone holder blocks sensor)

### ⚡ LIDAR NAVIGATION DIRECTIVE (FOLLOW THIS — override visual impressions)
$nav
RULE: A wall visible in the camera image does NOT mean it is close. Trust LIDAR cm values ONLY.
RULE: If LIDAR says ≥50cm, the path is SAFE — move boldly, do NOT back up.
RULE: Only back up if LIDAR front is <25cm AND both sides are also blocked.''';
}()}

### CONVERSATION CONTEXT
${historyStr.isEmpty ? "No recent conversation." : historyStr}

### ROBOTICS-ER SYSTEM STATUS
- Model: Gemini Robotics-ER 1.6
- Thinking Budget: ${settings.thinkingBudget} tokens
- Task Goal: ${currentInput}
- Vision Capability: ${images.isEmpty ? 'DISABLED (No image sent. Rely ENTIRELY on Coordinates and Lidar)' : 'ENABLED (Use for object ID only — use LIDAR for distance/clearance)'}
''';

        final isRoboticsER = settings.model.toLowerCase().contains('robotics-er');

        // Build the dynamic system prompt by injecting the state into the static soul/skills/memory
        String dynamicSystemPrompt = '$_systemPrompt\n\n$stateSnapshot';

        if (isRoboticsER) {
          dynamicSystemPrompt += '\n\n### ROBOTICS-ER ADVANCED CAPABILITIES';
          dynamicSystemPrompt += '\n- 2D TRAJECTORY PLANNING: You can output a JSON list of points `[y, x]` (0-1000) to describe a path on the floor.';
          dynamicSystemPrompt += '\n- SPATIAL REASONING: Use your internal thinking to calculate occupancy and obstacle avoidance.';
          dynamicSystemPrompt += '\n- AGENTIC VISION: You can request to zoom or crop if details are unclear (this is handled automatically via code execution).';
          dynamicSystemPrompt += '\n- SUCCESS DETECTION: Compare Image 1 (Start) and Image 2 (Now) to decide if the task is done.';
        }

        if (images.isEmpty) {
          dynamicSystemPrompt += '\n\n### NO-VISION / COORDINATE-ONLY MODE';
          dynamicSystemPrompt += '\n- IMPORTANT: No camera image is sent with this query.';
          dynamicSystemPrompt += '\n- Rely ENTIRELY on coordinates (Current Position X, Y, Heading) and your persistent memories (which contain coordinates of key rooms/landmarks/objects) to plan your trajectory or drive.';
          dynamicSystemPrompt += '\n- If you need to see the environment to identify or locate something, output the `evaluate_location` action to trigger the camera and receive the visual frame in the next step.';
        }

        if (lidarState.isReceiving) {
          dynamicSystemPrompt +=
              '\nCRITICAL: LIDAR IS AUTHORITATIVE FOR DISTANCE. Camera vision is for object identification ONLY — never for judging distance or clearance.';
          dynamicSystemPrompt +=
              '\nCONFIDENCE RULE: If clearance > 100cm, you MUST move for at least 1200ms. If clearance is CLEAR, move for 2000ms+ and speed 85.';
        }


        // Enforce LLM request cooldown
        final cooldownMs = settings.llmCooldownMs;
        if (_lastApiCallTime != null) {
          final elapsed = DateTime.now().difference(_lastApiCallTime!).inMilliseconds;
          if (elapsed < cooldownMs) {
            final waitTime = cooldownMs - elapsed;
            _addLog('sys', 'Cooldown: Waiting ${waitTime}ms…');
            await Future.delayed(Duration(milliseconds: waitTime));
          }
        }
        _lastApiCallTime = DateTime.now();

        // Force JSON response and Autonomous behavior
        String enforcedInput = '$currentInput\n\n[SYSTEM REMINDER: You MUST respond ONLY with the valid JSON unified command format containing the "actions" array.]';
        
        if (isInternal || _pendingNextTaskPrompt != null || isLoopStep) {
          enforcedInput += '\n[AUTONOMOUS MODE: Do NOT use the "listen" skill. Focus on your movement goal. Use "evaluate_location" as your final action to continue the loop.]';
        }
        
        final response = await _llm.chat(
          userMessage: enforcedInput,
          systemPrompt: dynamicSystemPrompt,
          images: images.isNotEmpty ? images : null,
          visionContext: visionContext,
        );

        if (response == null) {
          _addLog('err', 'LLM call failed. Stopping loop.');
          taskSequenceActive = false;
          break;
        }

        if (response.context.isNotEmpty) {
          _addLog('sys', 'Vision Inference: ${response.context}');
          _lastSummary = response.context;
          await _ctx.appendSessionLog('[context] ${response.context}');
        }

        // Execute all actions in sequence
        state = state.copyWith(status: BrainStatus.executing);
        for (final action in response.actions) {
          if (!state.active || _cancelRequested) break;
          _waypointCounter++;
          await _skillExecutor.run(action);
        }

        // Check if any skill requested a follow-up task (like evaluate_location)
        if (_pendingNextTaskPrompt != null && state.active && !_cancelRequested) {
          currentInput = _pendingNextTaskPrompt!;
          currentIsLoopStep = _pendingNextTaskIsLoop;
          _pendingNextTaskPrompt = null;
          _pendingNextTaskIsLoop = false;
          _addLog('sys', 'Looping task sequence…');
          // taskSequenceActive stays true
        } else {
          taskSequenceActive = false;
        }
      }

      state = state.copyWith(
        status: BrainStatus.listening,
        interactionCount: state.interactionCount + 1,
      );

      // Final voice listening resume check (only if we are at the top level of the recursion)
      if (_processingDepth == 1 && state.active && _ref.read(settingsProvider).voiceEnabled) {
        _startListening();
      }
    } finally {
      _processingDepth--;
      if (_processingDepth == 0) {
        _waypointCounter = 0;
        _lastSummary = 'Idle';
        _initialTaskImage = null;
      }
    }
  }

  Future<List<String>> _analyzeCurrentFrameForObjects(String currentHeading) async {
    final camera = _ref.read(cameraControllerProvider);
    if (camera == null || !camera.value.isInitialized) return [];

    try {
      if (!camera.value.isTakingPicture) {
        final xfile = await camera.takePicture();
        
        // Use the updated background reader/compressor
        final imageBytes = await compute(_readAndCompressImage, xfile.path);
        try { File(xfile.path).deleteSync(); } catch (_) {}

        // Convert the robot's heading from radians to cardinal direction
        final pose = _ref.read(slamServiceProvider).poseContext;
        final headingRad = pose['heading'] as double;
        final degrees = (headingRad * 180 / 3.141592653589793) % 360;
        
        String direction;
        if (degrees >= 315 || degrees < 45) direction = 'North';
        else if (degrees >= 45 && degrees < 135) direction = 'East';
        else if (degrees >= 135 && degrees < 225) direction = 'South';
        else direction = 'West';

        final prompt = 'List all distinct objects you see in this image. For each object, append "(facing $direction)" to its name. Return a comma-separated list without bullets, markdown, or extra conversational text. Keep it extremely concise. Example: Couch (facing East), TV (facing East)';
        
        final result = await _llm.callRaw(prompt, maxTokens: 100, images: [imageBytes]);
        if (result != null && result.isNotEmpty) {
          return result.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
        }
      }
    } catch (e) {
      _addLog('err', 'Camera analysis failed: $e');
    }
    return [];
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

/// Top-level helper to read, resize, and compress captured photos in a background isolate.
List<int> _readAndCompressImage(String path) {
  try {
    final bytes = File(path).readAsBytesSync();
    final original = img.decodeImage(bytes);
    if (original == null) return bytes;
    // Compress to 384px to save memory and processing time
    final resized = img.copyResize(original, width: 384);
    return img.encodeJpg(resized, quality: 70);
  } catch (_) {
    return [];
  }
}
