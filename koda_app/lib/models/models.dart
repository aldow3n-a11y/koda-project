import 'dart:ui';

// ─── bt_device.dart ───────────────────────────────────────────────────────────
class KodaBtDevice {
  final String id;
  final String name;
  final int rssi;
  final String type;

  const KodaBtDevice({
    required this.id,
    required this.name,
    required this.rssi,
    required this.type,
  });

  double get signalStrength => ((rssi + 100) / 60).clamp(0.0, 1.0);

  String get signalLabel {
    if (rssi > -55) return 'Excellent';
    if (rssi > -70) return 'Good';
    if (rssi > -85) return 'Fair';
    return 'Weak';
  }
}

// ─── motor_config.dart ────────────────────────────────────────────────────────
class MotorConfig {
  final int fl; // Front Left trim  80–120
  final int fr; // Front Right trim
  final int rl; // Rear Left trim
  final int rr; // Rear Right trim
  final int defaultSpeed; // 0–100%
  final int maxSpeed;     // 0–100%
  final int maxDurationMs;
  final bool brakeOnStop;
  final bool autoStopOnDisconnect;

  const MotorConfig({
    this.fl = 100,
    this.fr = 97,
    this.rl = 102,
    this.rr = 99,
    this.defaultSpeed = 60,
    this.maxSpeed = 85,
    this.maxDurationMs = 1500,
    this.brakeOnStop = true,
    this.autoStopOnDisconnect = true,
  });

  MotorConfig copyWith({
    int? fl, int? fr, int? rl, int? rr,
    int? defaultSpeed, int? maxSpeed,
    int? maxDurationMs, bool? brakeOnStop,
    bool? autoStopOnDisconnect,
  }) =>
      MotorConfig(
        fl: fl ?? this.fl,
        fr: fr ?? this.fr,
        rl: rl ?? this.rl,
        rr: rr ?? this.rr,
        defaultSpeed: defaultSpeed ?? this.defaultSpeed,
        maxSpeed: maxSpeed ?? this.maxSpeed,
        maxDurationMs: maxDurationMs ?? this.maxDurationMs,
        brakeOnStop: brakeOnStop ?? this.brakeOnStop,
        autoStopOnDisconnect: autoStopOnDisconnect ?? this.autoStopOnDisconnect,
      );

  Map<String, dynamic> toJson() => {
    'fl': fl, 'fr': fr, 'rl': rl, 'rr': rr,
    'defaultSpeed': defaultSpeed, 'maxSpeed': maxSpeed,
    'maxDurationMs': maxDurationMs, 'brakeOnStop': brakeOnStop,
    'autoStopOnDisconnect': autoStopOnDisconnect,
  };

  factory MotorConfig.fromJson(Map<String, dynamic> j) => MotorConfig(
    fl: j['fl'] ?? 100, fr: j['fr'] ?? 97,
    rl: j['rl'] ?? 102, rr: j['rr'] ?? 99,
    defaultSpeed: j['defaultSpeed'] ?? 60,
    maxSpeed: j['maxSpeed'] ?? 85,
    maxDurationMs: j['maxDurationMs'] ?? 1500,
    brakeOnStop: j['brakeOnStop'] ?? true,
    autoStopOnDisconnect: j['autoStopOnDisconnect'] ?? true,
  );
}

// ─── skill_action.dart ──────────────────────────────────────────────────────
class SkillAction {
  final String skill;
  final Map<String, dynamic> params;

  const SkillAction({required this.skill, this.params = const {}});

  /// Get a string param with fallback
  String param(String key, [String fallback = '']) =>
      (params[key] ?? fallback).toString();

  /// Get an int param with fallback
  int paramInt(String key, [int fallback = 0]) {
    final v = params[key];
    if (v == null) return fallback;
    if (v is int) return v;
    if (v is double) return v.round();
    return int.tryParse(v.toString()) ?? fallback;
  }

  factory SkillAction.fromJson(Map<String, dynamic> j) {
    final skill = (j['skill'] as String? ?? '').toLowerCase();
    final params = Map<String, dynamic>.from(j)..remove('skill');
    return SkillAction(skill: skill, params: params);
  }
}

// ─── koda_response.dart ─────────────────────────────────────────────────────
class KodaResponse {
  final List<SkillAction> actions;
  final String context;

  const KodaResponse({required this.actions, required this.context});

  factory KodaResponse.fromJson(Map<String, dynamic> j) {
    final raw = j['actions'] as List? ?? [];
    return KodaResponse(
      actions: raw
          .whereType<Map<String, dynamic>>()
          .map(SkillAction.fromJson)
          .toList(),
      context: (j['context'] as String? ?? '').trim(),
    );
  }
}

// ─── koda_command.dart (kept for BLE sending) ────────────────────────────────
enum KodaCmd { forward, backward, turnCw, turnCcw, stop, express }

class MotorCommand {
  final KodaCmd cmd;
  final int speed;   // 0–100%
  final int ms;
  final String? emotion;

  const MotorCommand({
    required this.cmd,
    this.speed = 60,
    this.ms = 500,
    this.emotion,
  });

  int get pwm => (speed / 100.0 * 255).round();

  Map<String, dynamic> toJson() => {
    'cmd': cmd.name,
    'speed': speed,
    'ms': ms,
    if (emotion != null) 'emotion': emotion,
  };
}

// ─── app_settings.dart ────────────────────────────────────────────────────────
class AppSettings {
  final String apiKey;
  final String model;
  final String ttsVoice;
  final String wakeWord;
  final bool voiceEnabled;
  final bool memoryEnabled;
  final bool cloudSync;
  final bool devMode;
  final String bleDeviceName;
  final int bleWatchdogMs;
  final int maxTokens;
  final int llmCooldownMs;
  final int maxLoopIterations;
  final int thinkingBudget;
  final String customApiUrl;
  final bool keepScreenAwake;
  /// Degrees to subtract from raw LiDAR angle so that 0° = robot forward.
  /// Calibrate by pointing robot at a wall, noting the reported angle,
  /// then setting this offset so that angle reads 0°.
  final double lidarAngularOffset;
  /// Time in seconds before unconfirmed occupied cells begin to decay.
  /// 0 = never decay automatically.
  final int lidarDecaySec;
  /// Dead reckoning: Physical wheelbase in mm.
  final double wheelbaseMm;
  /// Dead reckoning: Linear speed in mm/s when motor is at 100%.
  final double mmPerSecAt100pct;
  /// Dead reckoning: Correction multiplier for rotation.
  final double turnCalibrationFactor;
  /// IMU: Use phone IMU for heading rotation.
  final bool useImuHeading;
  /// IMU: Invert the calculated rotation.
  final bool imuInvertTurn;

  const AppSettings({
    this.apiKey = '',
    this.model = 'gemini-robotics-er-1.6-preview',
    this.customApiUrl = '',
    this.ttsVoice = 'en-US',
    this.wakeWord = 'Hey Koda',
    this.voiceEnabled = true,
    this.memoryEnabled = true,
    this.cloudSync = false,
    this.devMode = false,
    this.bleDeviceName = 'KODA-ESP32',
    this.bleWatchdogMs = 3000,
    this.maxTokens = 1000,
    this.llmCooldownMs = 4000,
    this.maxLoopIterations = 20,
    this.thinkingBudget = 0,
    this.keepScreenAwake = true,
    this.lidarAngularOffset = 105.0,  // calibrated sensor offset (forward = 0° after correction)
    this.lidarDecaySec = 30,         // 30s before dots start to fade
    this.wheelbaseMm = 130.0,
    this.mmPerSecAt100pct = 330.0,
    this.turnCalibrationFactor = 1.0,
    this.useImuHeading = false,
    this.imuInvertTurn = false,
  });

  AppSettings copyWith({
    String? apiKey, String? model, String? customApiUrl, String? ttsVoice, String? wakeWord,
    bool? voiceEnabled, bool? memoryEnabled, bool? cloudSync, bool? devMode,
    String? bleDeviceName, int? bleWatchdogMs, int? maxTokens, int? llmCooldownMs,
    int? maxLoopIterations, int? thinkingBudget, bool? keepScreenAwake, double? lidarAngularOffset,
    int? lidarDecaySec, double? wheelbaseMm, double? mmPerSecAt100pct,
    double? turnCalibrationFactor, bool? useImuHeading, bool? imuInvertTurn,
  }) =>
      AppSettings(
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
        customApiUrl: customApiUrl ?? this.customApiUrl,
        ttsVoice: ttsVoice ?? this.ttsVoice,
        wakeWord: wakeWord ?? this.wakeWord,
        voiceEnabled: voiceEnabled ?? this.voiceEnabled,
        memoryEnabled: memoryEnabled ?? this.memoryEnabled,
        cloudSync: cloudSync ?? this.cloudSync,
        devMode: devMode ?? this.devMode,
        bleDeviceName: bleDeviceName ?? this.bleDeviceName,
        bleWatchdogMs: bleWatchdogMs ?? this.bleWatchdogMs,
        maxTokens: maxTokens ?? this.maxTokens,
        llmCooldownMs: llmCooldownMs ?? this.llmCooldownMs,
        maxLoopIterations: maxLoopIterations ?? this.maxLoopIterations,
        thinkingBudget: thinkingBudget ?? this.thinkingBudget,
        keepScreenAwake: keepScreenAwake ?? this.keepScreenAwake,
        lidarAngularOffset: lidarAngularOffset ?? this.lidarAngularOffset,
        lidarDecaySec: lidarDecaySec ?? this.lidarDecaySec,
        wheelbaseMm: wheelbaseMm ?? this.wheelbaseMm,
        mmPerSecAt100pct: mmPerSecAt100pct ?? this.mmPerSecAt100pct,
        turnCalibrationFactor: turnCalibrationFactor ?? this.turnCalibrationFactor,
        useImuHeading: useImuHeading ?? this.useImuHeading,
        imuInvertTurn: imuInvertTurn ?? this.imuInvertTurn,
      );

  Map<String, dynamic> toJson() => {
    'apiKey': apiKey, 'model': model, 'customApiUrl': customApiUrl, 'ttsVoice': ttsVoice,
    'wakeWord': wakeWord, 'voiceEnabled': voiceEnabled,
    'memoryEnabled': memoryEnabled, 'cloudSync': cloudSync,
    'devMode': devMode, 'bleDeviceName': bleDeviceName,
    'bleWatchdogMs': bleWatchdogMs, 'maxTokens': maxTokens,
    'llmCooldownMs': llmCooldownMs, 'maxLoopIterations': maxLoopIterations,
    'thinkingBudget': thinkingBudget,
    'keepScreenAwake': keepScreenAwake, 'lidarAngularOffset': lidarAngularOffset,
    'lidarDecaySec': lidarDecaySec, 'wheelbaseMm': wheelbaseMm,
    'mmPerSecAt100pct': mmPerSecAt100pct, 'turnCalibrationFactor': turnCalibrationFactor,
    'useImuHeading': useImuHeading, 'imuInvertTurn': imuInvertTurn,
  };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
    apiKey: j['apiKey'] ?? '',
    model: j['model'] ?? 'gemini-robotics-er-1.6-preview',
    customApiUrl: j['customApiUrl'] ?? '',
    ttsVoice: j['ttsVoice'] ?? 'en-US',
    wakeWord: j['wakeWord'] ?? 'Hey Koda',
    voiceEnabled: j['voiceEnabled'] ?? true,
    memoryEnabled: j['memoryEnabled'] ?? true,
    cloudSync: j['cloudSync'] ?? false,
    devMode: j['devMode'] ?? false,
    bleDeviceName: j['bleDeviceName'] ?? 'KODA-ESP32',
    bleWatchdogMs: j['bleWatchdogMs'] ?? 3000,
    maxTokens: j['maxTokens'] ?? 1000,
    llmCooldownMs: j['llmCooldownMs'] ?? 4000,
    maxLoopIterations: j['maxLoopIterations'] ?? 20,
    thinkingBudget: j['thinkingBudget'] ?? 0,
    keepScreenAwake: j['keepScreenAwake'] ?? true,
    lidarAngularOffset: (j['lidarAngularOffset'] as num?)?.toDouble() ?? 105.0,
    lidarDecaySec: (j['lidarDecaySec'] as num?)?.toInt() ?? 30,
    wheelbaseMm: (j['wheelbaseMm'] as num?)?.toDouble() ?? 130.0,
    mmPerSecAt100pct: (j['mmPerSecAt100pct'] as num?)?.toDouble() ?? 330.0,
    turnCalibrationFactor: (j['turnCalibrationFactor'] as num?)?.toDouble() ?? 1.0,
    useImuHeading: j['useImuHeading'] ?? false,
    imuInvertTurn: j['imuInvertTurn'] ?? false,
  );
}

// ─── Robot Emotions ────────────────────────────────────────────────────────
enum RobotEmotion {
  neutral,
  happy,
  sad,
  curious,
  surprised,
  thinking,
  excited,
  playing,
  wink,
  angry,
  love,
  dizzy,
}

// ─── Display Canvas content ──────────────────────────────────────────────────
enum CanvasType { face, timer, image, gif, weather, message, radar, audio, youtube }

class CanvasContent {
  final CanvasType type;
  final String? url;      // For image or gif
  final int? seconds;     // For timer countdown
  final String? text;     // Caption or message overlay
  final String? title;    // Header, message title, or audio track
  final String? subtitle; // Sub-header, message body, or audio artist
  final String? temp;     // Weather temperature
  final String? condition; // Weather condition key (sunny, rainy, cloudy, snowy)

  const CanvasContent({
    required this.type,
    this.url,
    this.seconds,
    this.text,
    this.title,
    this.subtitle,
    this.temp,
    this.condition,
  });

  factory CanvasContent.face() => const CanvasContent(type: CanvasType.face);

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'url': url,
    'seconds': seconds,
    'text': text,
    'title': title,
    'subtitle': subtitle,
    'temp': temp,
    'condition': condition,
  };

  factory CanvasContent.fromJson(Map<String, dynamic> j) {
    return CanvasContent(
      type: CanvasType.values.firstWhere((e) => e.name == j['type'], orElse: () => CanvasType.face),
      url: j['url'],
      seconds: j['seconds'],
      text: j['text'],
      title: j['title'],
      subtitle: j['subtitle'],
      temp: j['temp'],
      condition: j['condition'],
    );
  }
}

// ─── Object Tracking ─────────────────────────────────────────────────────────

class ObjectTrackingData {
  final Offset offset;
  final double areaRatio;

  const ObjectTrackingData(this.offset, this.areaRatio);
}

// ─── Koda Body State ─────────────────────────────────────────────────────────

class KodaBodyState {
  final int mood;
  final int arousal;
  final int frontCm;
  final int leftCm;
  final int rightCm;
  final int flags;

  const KodaBodyState({
    required this.mood,
    required this.arousal,
    required this.frontCm,
    required this.leftCm,
    required this.rightCm,
    required this.flags,
  });

  bool get isMoving => (flags & 0x01) != 0;
  bool get obstacleFront => (flags & 0x02) != 0;
  bool get obstacleLeft => (flags & 0x04) != 0;
  bool get obstacleRight => (flags & 0x08) != 0;

  @override
  String toString() =>
      'BodyState(mood: $mood, arousal: $arousal, front: ${frontCm}cm, left: ${leftCm}cm, right: ${rightCm}cm, flags: $flags)';
}
