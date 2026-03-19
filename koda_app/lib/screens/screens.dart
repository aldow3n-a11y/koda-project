import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import '../theme/koda_theme.dart';
import '../models/models.dart';
import '../providers/providers.dart';
import '../widgets/widgets.dart';

// ══════════════════════════════════════════════════════════════════════════════
// HOME SCREEN
// ══════════════════════════════════════════════════════════════════════════════
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ble = ref.watch(bleConnectionProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Koda hero card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF0E1820), Color(0xFF0D1117)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: KodaColors.border2),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('🤖', style: TextStyle(fontSize: 48)),
                const SizedBox(height: 8),
                Text('KODA', style: condensedStyle(size: 32, spacing: 3)),
                Text('4WD · TB6612FNG · ESP32-S3 · S21 FE',
                    style: monoStyle(size: 11, color: KodaColors.sub)),
                const SizedBox(height: 14),
                Row(
                  children: [
                    StatusBadge(
                      label: ble.isConnected ? 'WHEELS ONLINE' : 'WHEELS OFFLINE',
                      color: ble.isConnected ? KodaColors.green : KodaColors.dim,
                    ),
                    const SizedBox(width: 8),
                    if (ble.connectedDevice != null)
                      StatusBadge(
                        label: ble.connectedDevice!.name,
                        color: KodaColors.amber,
                      ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // BLE connect / disconnect
          if (!ble.isConnected)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => showModalBottomSheet(
                  context: context,
                  backgroundColor: Colors.transparent,
                  builder: (_) => const BtScannerSheet(),
                ),
                icon: const Icon(Icons.bluetooth_searching, size: 18,
                    color: KodaColors.blue),
                label: Text('SCAN & CONNECT BLUETOOTH',
                    style: condensedStyle(size: 14, color: KodaColors.blue, spacing: 2)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: KodaColors.blue),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            )
          else
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: ref.read(bleConnectionProvider.notifier).disconnect,
                icon: const Icon(Icons.bluetooth_disabled, size: 18,
                    color: KodaColors.red),
                label: Text('DISCONNECT ${ble.connectedDevice?.name ?? ""}',
                    style: condensedStyle(size: 14, color: KodaColors.red, spacing: 2)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: KodaColors.red),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),

          const SizedBox(height: 12),

          // Mode hint cards
          KodaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionLabel('QUICK INFO'),
                const SizedBox(height: 8),
                Text(
                  'Use the tabs below to switch between Brain (autonomous LLM), '
                  'Remote (manual control), and Settings.',
                  style: bodyStyle(size: 12, color: KodaColors.sub),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// BRAIN SCREEN
// ══════════════════════════════════════════════════════════════════════════════
class BrainScreen extends ConsumerStatefulWidget {
  const BrainScreen({super.key});

  @override
  ConsumerState<BrainScreen> createState() => _BrainScreenState();
}

class _BrainScreenState extends ConsumerState<BrainScreen> with WidgetsBindingObserver {
  CameraController? _cameraController;
  bool _isCameraReady = false;
  CameraLensDirection _currentLens = CameraLensDirection.back;
  bool _isInitInProgress = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Defer camera init to post-frame so the widget is fully mounted
    // and the app is guaranteed to be in 'resumed' state before we
    // request permissions (which could pause the app via the dialog).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _initCamera(_currentLens);
    });
  }

  Future<void> _initCamera(CameraLensDirection lens) async {
    if (_isInitInProgress) return;

    // Only attempt camera initialization when the app is in the foreground.
    // The permission dialog puts the app in 'inactive' state on Android
    // (CAMERA_DISABLED error). We guard against that here.
    final appState = WidgetsBinding.instance.lifecycleState;
    if (appState != null &&
        appState != AppLifecycleState.resumed &&
        appState != AppLifecycleState.inactive) {
      // App is paused or detached — bail out; didChangeAppLifecycleState
      // will re-trigger init on resume.
      return;
    }

    _isInitInProgress = true;
    try {
      // Request permissions first
      final status = await Permission.camera.request();
      if (status != PermissionStatus.granted) {
        debugPrint('Camera permission denied');
        return;
      }
      await Permission.microphone.request();

      // After permission dialogs, the app may have been paused.
      // Only proceed if we are back in foreground.
      if (!mounted) return;
      final stateAfterRequest = WidgetsBinding.instance.lifecycleState;
      if (stateAfterRequest == AppLifecycleState.paused ||
          stateAfterRequest == AppLifecycleState.detached) {
        // Will be retried via didChangeAppLifecycleState on resume.
        return;
      }

      final cameras = await availableCameras();
      if (cameras.isEmpty) return;
      
      // Try to find the requested lens, fallback to first available
      final selectedCamera = cameras.firstWhere(
            (c) => c.lensDirection == lens,
            orElse: () => cameras.first);
      
      // Dispose old controller if switching
      if (_cameraController != null) {
        await _cameraController!.dispose();
      }

      _cameraController = CameraController(
        selectedCamera, 
        ResolutionPreset.medium, 
        enableAudio: false,
      );
      await _cameraController!.initialize();
      
      // Save to global provider for the Brain to access
      ref.read(cameraControllerProvider.notifier).state = _cameraController;

      if (mounted) {
        setState(() {
          _isCameraReady = true;
          _currentLens = selectedCamera.lensDirection;
        });
      }
    } on CameraException catch (e) {
      debugPrint('Camera exception: $e');
    } catch (e) {
      debugPrint('Camera init error: $e');
    } finally {
      if (mounted) _isInitInProgress = false;
    }
  }

  void _toggleCamera() {
    setState(() => _isCameraReady = false);
    final newLens = _currentLens == CameraLensDirection.back 
        ? CameraLensDirection.front 
        : CameraLensDirection.back;
    _initCamera(newLens);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      // Free up the camera when app goes to background
      _cameraController?.dispose();
      _cameraController = null;
      ref.read(cameraControllerProvider.notifier).state = null;
      if (mounted) setState(() => _isCameraReady = false);
    } else if (state == AppLifecycleState.resumed) {
      // Small delay to allow Android to fully re-enable the camera
      // hardware after returning from permission dialogs or recents.
      Future.delayed(const Duration(milliseconds: 400), () {
        if (mounted && 
            (_cameraController == null || !_cameraController!.value.isInitialized)) {
          _initCamera(_currentLens);
        }
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    super.dispose();
  }

  bool _isListening = false;

  Future<void> _forceListenOnce() async {
    if (!ref.read(brainProvider).active) return;
    setState(() => _isListening = true);
    ref.read(brainProvider.notifier).forceListenOnce(() {
      if (mounted) setState(() => _isListening = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final brain = ref.watch(brainProvider);
    final ble   = ref.watch(bleConnectionProvider);
    final notifier = ref.read(brainProvider.notifier);

    return Stack(
      children: [
        SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          child: Column(
            children: [
              // Header card
              KodaCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('BRAIN MODE', style: condensedStyle(size: 22, spacing: 1)),
                            Text('LLM-AUTONOMOUS · CLOUD CONNECTED',
                                style: monoStyle(size: 10, color: KodaColors.sub)),
                          ],
                        ),
                        StatusBadge(
                          label: brain.active ? 'ACTIVE' : 'IDLE',
                          color: brain.active ? KodaColors.green : KodaColors.dim,
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // Activate button
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        // Always allow activation, even if BLE is disconnected
                        onPressed: brain.active ? notifier.deactivate : notifier.activate,
                        icon: Icon(brain.active ? Icons.stop : Icons.play_arrow),
                        label: Text(
                          brain.active ? 'DEACTIVATE KODA' : 'ACTIVATE KODA',
                          style: condensedStyle(
                              size: 18,
                              color: brain.active ? KodaColors.red : KodaColors.amber,
                              spacing: 3),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: brain.active
                              ? const Color(0xFF1A0808)
                              : const Color(0xFF1A1200),
                          foregroundColor:
                              brain.active ? KodaColors.red : KodaColors.amber,
                          side: BorderSide(
                              color: brain.active ? KodaColors.red : KodaColors.amber,
                              width: 2),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          elevation: 0,
                        ),
                      ),
                    ),

                    if (!ble.isConnected) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1A1200),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: KodaColors.amber.withValues(alpha: 0.4)),
                        ),
                        child: Text(
                          'ℹ  Bluetooth not connected — Motor commands will be ignored.',
                          style: monoStyle(size: 11, color: KodaColors.amber),
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // Stats row (when active)
              if (brain.active) ...[
                Row(
                  children: [
                    _StatCard(label: 'STATUS', value: brain.status.name.toUpperCase(), color: KodaColors.amber),
                    const SizedBox(width: 8),
                    _StatCard(label: 'MEMORY', value: '${brain.memories.length} items', color: KodaColors.blue),
                    const SizedBox(width: 8),
                    _StatCard(label: 'API CALLS', value: '${brain.interactionCount}', color: KodaColors.green),
                  ],
                ),
                const SizedBox(height: 12),
              ],

              // Camera preview — fills card with BoxFit.cover (no stretch, no bars)
              if (_isCameraReady) ...[
                KodaCard(
                  padding: EdgeInsets.zero,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      height: 260,   // ~30% taller than before
                      width: double.infinity,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // Fill card edge-to-edge, cropping top/bottom — no extra zoom
                          FittedBox(
                            fit: BoxFit.cover,
                            clipBehavior: Clip.hardEdge,
                            child: SizedBox(
                              width: _cameraController!.value.previewSize?.height ?? 720,
                              height: _cameraController!.value.previewSize?.width ?? 1280,
                              child: CameraPreview(_cameraController!),
                            ),
                          ),
                          // Dark dimming layer so the glowing eyes pop
                          Container(color: Colors.black.withValues(alpha: 0.4)),
                          // Robot Eyes HUD overlay
                          Builder(builder: (context) {
                            // Use the emotion decided by the LLM
                            var emotion = brain.currentEmotion;
                            
                            // Override with system statuses when actively processing
                            if (brain.status == BrainStatus.thinking) emotion = RobotEmotion.thinking;
                            if (brain.status == BrainStatus.listening) emotion = RobotEmotion.curious;
                            
                            return RobotFaceOverlay(emotion: emotion);
                          }),
                          Positioned(
                            top: 8, left: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                _currentLens == CameraLensDirection.front ? 'FRONT CAM' : 'REAR CAM',
                                style: monoStyle(size: 9, color: KodaColors.green),
                              ),
                            ),
                          ),
                          Positioned(
                            bottom: 8, right: 8,
                            child: Container(
                              decoration: const BoxDecoration(
                                color: Colors.black54,
                                shape: BoxShape.circle,
                              ),
                              child: IconButton(
                                icon: const Icon(Icons.flip_camera_ios, color: Colors.white, size: 20),
                                onPressed: _toggleCamera,
                                tooltip: 'Toggle Camera',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],

              // Activity log (fixed height, scrollable inside)
              KodaCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const SectionLabel('ACTIVITY LOG'),
                          GestureDetector(
                            onTap: () {},
                            child: Text('CLEAR', style: monoStyle(size: 10, color: KodaColors.dim)),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1, color: KodaColors.border),
                    SizedBox(
                      height: 260,
                      child: ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: brain.log.length,
                        reverse: true,
                        itemBuilder: (_, i) {
                          final entry = brain.log[brain.log.length - 1 - i];
                          final color = {
                            'sys':  KodaColors.sub,
                            'koda': KodaColors.amber,
                            'cmd':  KodaColors.blue,
                            'err':  KodaColors.red,
                            'user': KodaColors.green,
                          }[entry.type] ?? KodaColors.sub;
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(entry.time, style: monoStyle(size: 10, color: KodaColors.dim)),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(entry.message, style: monoStyle(size: 11, color: color)),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // Mic FAB — shows when brain is active
        if (brain.active)
          Positioned(
            bottom: 16, left: 0, right: 0,
            child: Center(
              child: GestureDetector(
                onTap: _forceListenOnce,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: _isListening ? 72 : 60,
                  height: _isListening ? 72 : 60,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isListening ? KodaColors.green.withValues(alpha: 0.18) : const Color(0xFF1A1200),
                    border: Border.all(
                      color: _isListening ? KodaColors.green : KodaColors.amber,
                      width: 2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: (_isListening ? KodaColors.green : KodaColors.amber).withValues(alpha: 0.25),
                        blurRadius: 16, spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: Icon(
                    _isListening ? Icons.mic : Icons.mic_none,
                    color: _isListening ? KodaColors.green : KodaColors.amber,
                    size: 28,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label, value;
  final Color color;
  const _StatCard({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) => Expanded(
        child: KodaCard(
          padding: const EdgeInsets.all(10),
          child: Column(
            children: [
              Text(label, style: monoStyle(size: 9, color: KodaColors.sub, spacing: 2)),
              const SizedBox(height: 4),
              Text(value, style: monoStyle(size: 12, color: color, weight: FontWeight.bold)),
            ],
          ),
        ),
      );
}

// ══════════════════════════════════════════════════════════════════════════════
// REMOTE SCREEN (tab wrapper)
// ══════════════════════════════════════════════════════════════════════════════
class RemoteScreen extends ConsumerStatefulWidget {
  const RemoteScreen({super.key});

  @override
  ConsumerState<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends ConsumerState<RemoteScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Container(
            color: KodaColors.panel,
            child: TabBar(
              controller: _tab,
              labelStyle: monoStyle(size: 10, spacing: 2),
              labelColor: KodaColors.amber,
              unselectedLabelColor: KodaColors.dim,
              indicatorColor: KodaColors.amber,
              indicatorSize: TabBarIndicatorSize.tab,
              tabs: const [
                Tab(text: '2A · JOYSTICK'),
                Tab(text: '2B · PAIRED VIEW'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: const [
                JoystickScreen(),
                PairedScreen(),
              ],
            ),
          ),
        ],
      );
}

// ── Joystick Screen ───────────────────────────────────────────────────────────
class JoystickScreen extends ConsumerWidget {
  const JoystickScreen({super.key});

  Future<void> _sendCmd(WidgetRef ref, KodaCmd cmd, int speed) async {
    final bleNotifier = ref.read(bleConnectionProvider.notifier);
    if (cmd == KodaCmd.stop) {
      await bleNotifier.sendStop();
    } else {
      await bleNotifier.sendCommand(MotorCommand(cmd: cmd, speed: speed, ms: 0));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ble   = ref.watch(bleConnectionProvider);
    final speed = ref.watch(remoteSpeedProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Header
          KodaCard(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('DIRECT CONTROL', style: condensedStyle(size: 18, spacing: 1)),
                    const SizedBox(height: 4),
                    Row(children: [
                      StatusBadge(
                        label: ble.isConnected ? 'BT LIVE' : 'BT OFFLINE',
                        color: ble.isConnected ? KodaColors.green : KodaColors.red,
                      ),
                      const SizedBox(width: 8),
                      Text('SPD:$speed% · PWM:${(speed/100*255).round()}',
                          style: monoStyle(size: 10, color: KodaColors.sub)),
                    ]),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // D-pad
          KodaCard(
            child: Column(
              children: [
                DPadWidget(
                  onPress: (cmd, spd) => _sendCmd(ref, cmd, spd),
                  onRelease: () => ref.read(bleConnectionProvider.notifier).sendStop(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Speed slider
          const SpeedSlider(),
          const SizedBox(height: 12),

          // Motor trim
          const MotorTrimWidget(),
        ],
      ),
    );
  }
}

// ── Paired Screen ─────────────────────────────────────────────────────────────
class PairedScreen extends ConsumerStatefulWidget {
  const PairedScreen({super.key});

  @override
  ConsumerState<PairedScreen> createState() => _PairedScreenState();
}

class _PairedScreenState extends ConsumerState<PairedScreen> {
  bool _paired = false;
  bool _streaming = false;
  bool _pairing = false;
  String _pairCode = '';

  void _startPair() {
    setState(() { _pairing = true; });
    final code = (100000 + DateTime.now().millisecond * 100 % 900000).toString();
    setState(() { _pairCode = code; });
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() { _pairing = false; _paired = true; });
    });
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          KodaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('PAIRED REMOTE VIEW', style: condensedStyle(size: 18, spacing: 1)),
                Text('WiFi peer-to-peer · Koda phone → User phone',
                    style: monoStyle(size: 10, color: KodaColors.sub)),
              ],
            ),
          ),
          const SizedBox(height: 12),

          if (!_paired) ...[
            // Pairing card
            KodaCard(
              child: _pairing
                  ? Column(children: [
                      Text(_pairCode,
                          style: monoStyle(
                              size: 36, color: KodaColors.amber,
                              weight: FontWeight.bold, spacing: 8)),
                      const SizedBox(height: 8),
                      Text('Enter this code on Koda phone…',
                          style: monoStyle(size: 11, color: KodaColors.sub)),
                    ])
                  : Column(children: [
                      const Text('📡', style: TextStyle(fontSize: 40)),
                      const SizedBox(height: 12),
                      Text(
                        'Pair this phone with Koda\'s phone\nto receive live camera feed',
                        textAlign: TextAlign.center,
                        style: bodyStyle(size: 13, color: KodaColors.sub),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: _startPair,
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: KodaColors.blue),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          child: Text('GENERATE PAIR CODE',
                              style: condensedStyle(
                                  size: 16, color: KodaColors.blue, spacing: 2)),
                        ),
                      ),
                    ]),
            ),
          ] else ...[
            // Camera view
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: const Color(0xFF050810),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: KodaColors.border),
              ),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  children: [
                    if (_streaming)
                      Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Color(0xFF050810), Color(0xFF0A1020)],
                          ),
                        ),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('● LIVE FEED',
                                  style: monoStyle(size: 11, color: KodaColors.green)),
                              const SizedBox(height: 4),
                              Text('720p · 24fps',
                                  style: monoStyle(size: 10, color: KodaColors.dim)),
                            ],
                          ),
                        ),
                      )
                    else
                      Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.camera_alt, color: KodaColors.dim, size: 32),
                            const SizedBox(height: 8),
                            Text('FEED OFFLINE',
                                style: monoStyle(size: 11, color: KodaColors.dim)),
                          ],
                        ),
                      ),
                    Positioned(
                      top: 8, right: 8,
                      child: const StatusBadge(label: 'PAIRED', color: KodaColors.green),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),

            // Stream controls
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => setState(() => _streaming = !_streaming),
                    style: OutlinedButton.styleFrom(
                      backgroundColor: _streaming
                          ? const Color(0xFF1A0808)
                          : const Color(0xFF081A10),
                      side: BorderSide(
                          color: _streaming ? KodaColors.red : KodaColors.green),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: Text(
                      _streaming ? '⏹  STOP STREAM' : '▶  START STREAM',
                      style: condensedStyle(
                          size: 15,
                          color: _streaming ? KodaColors.red : KodaColors.green,
                          spacing: 2),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () => setState(() {
                    _paired = false; _streaming = false; _pairCode = '';
                  }),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: KodaColors.border2),
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
                  ),
                  child: Text('UNPAIR',
                      style: monoStyle(size: 11, color: KodaColors.sub)),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Remote joystick — always shown after pairing
            KodaCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SectionLabel('REMOTE CONTROL'),
                  const SizedBox(height: 12),
                  DPadWidget(
                    onPress: (cmd, spd) async {
                      final notifier = ref.read(bleConnectionProvider.notifier);
                      if (cmd == KodaCmd.stop) {
                        await notifier.sendStop();
                      } else {
                        await notifier.sendCommand(
                            MotorCommand(cmd: cmd, speed: spd, ms: 0));
                      }
                    },
                    onRelease: () =>
                        ref.read(bleConnectionProvider.notifier).sendStop(),
                  ),
                  const SizedBox(height: 12),
                  const Divider(color: KodaColors.border, height: 1),
                  const SizedBox(height: 12),
                  const SpeedSlider(),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// SETTINGS SCREEN
// ══════════════════════════════════════════════════════════════════════════════
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  String _section = 'llm';
  bool _obscureKey = true;

  final _sections = const [
    {'id': 'llm',     'label': '🧠 LLM'},
    {'id': 'voice',   'label': '🎙 Voice'},
    {'id': 'motor',   'label': '⚙️ Motor'},
    {'id': 'memory',  'label': '💾 Memory'},
    {'id': 'connect', 'label': '📡 Connect'},
    {'id': 'system',  'label': '🔧 System'},
    {'id': 'context', 'label': '📝 Context'},
  ];

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final motor    = ref.watch(motorConfigProvider);
    final sNotifier = ref.read(settingsProvider.notifier);
    final mNotifier = ref.read(motorConfigProvider.notifier);

    return Column(
      children: [
        // Section pills
        Container(
          color: KodaColors.panel,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: _sections.map((s) {
                final active = _section == s['id'];
                return GestureDetector(
                  onTap: () => setState(() => _section = s['id']!),
                  child: Container(
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      color: active ? const Color(0xFF1A1200) : KodaColors.panel2,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: active ? KodaColors.amber : KodaColors.border2,
                      ),
                    ),
                    child: Text(s['label']!,
                        style: monoStyle(
                            size: 10,
                            color: active ? KodaColors.amber : KodaColors.sub)),
                  ),
                );
              }).toList(),
            ),
          ),
        ),

        // Section content
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: _buildSection(settings, motor, sNotifier, mNotifier),
          ),
        ),
      ],
    );
  }

  Widget _buildSection(AppSettings s, MotorConfig m,
      SettingsNotifier sN, MotorConfigNotifier mN) {
    switch (_section) {
      case 'llm':
        return Column(children: [
          _SettingsTile(
            label: 'API Key',
            sub: 'Stored locally on device',
            child: TextFormField(
              initialValue: s.apiKey,
              obscureText: _obscureKey,
              style: monoStyle(size: 12, color: KodaColors.text),
              decoration: InputDecoration(
                hintText: 'sk-ant-…',
                suffixIcon: IconButton(
                  icon: Icon(_obscureKey ? Icons.visibility : Icons.visibility_off,
                      size: 18, color: KodaColors.dim),
                  onPressed: () => setState(() => _obscureKey = !_obscureKey),
                ),
              ),
              onChanged: (v) => sN.updateField((s) => s.copyWith(apiKey: v)),
            ),
          ),
          _SettingsTile(
            label: 'Model',
            sub: 'Haiku recommended for speed + cost',
            child: DropdownButtonFormField<String>(
              initialValue: s.model,
              dropdownColor: KodaColors.panel2,
              style: monoStyle(size: 11, color: KodaColors.text),
              decoration: const InputDecoration(),
              items: const [
                DropdownMenuItem(value: 'claude-haiku-4-5-20251001',
                    child: Text('Haiku 4.5 — Fast')),
                DropdownMenuItem(value: 'claude-sonnet-4-6',
                    child: Text('Sonnet 4.6 — Balanced')),
                DropdownMenuItem(value: 'claude-opus-4-6',
                    child: Text('Opus 4.6 — Smart')),
                DropdownMenuItem(value: 'gemini-2.0-flash',
                    child: Text('Gemini 2.0 Flash')),
                DropdownMenuItem(value: 'gemini-2.5-flash',
                    child: Text('Gemini 2.5 Flash')),
                DropdownMenuItem(value: 'gemini-3-flash',
                    child: Text('Gemini 3 Flash — Experimental')),
              ],
              onChanged: (v) => sN.updateField((s) => s.copyWith(model: v)),
            ),
          ),
            _SliderTile(
              label: 'Max tokens',
              value: s.maxTokens.toDouble(),
              min: 50, max: 1000, unit: ' tk',
            onChanged: (v) => sN.updateField((s) => s.copyWith(maxTokens: v.round())),
          ),
          _SliderTile(
            label: 'LLM cooldown',
            value: s.llmCooldownMs.toDouble(),
            min: 500, max: 25000, unit: 'ms', divisions: 49,
            onChanged: (v) => sN.updateField((s) => s.copyWith(llmCooldownMs: v.round())),
          ),
          _SliderTile(
            label: 'Max loop iterations',
            value: s.maxLoopIterations.toDouble(),
            min: 1, max: 50, unit: ' steps',
            onChanged: (v) => sN.updateField((s) => s.copyWith(maxLoopIterations: v.round())),
          ),
        ]);

      case 'voice':
        final tts = ref.read(ttsServiceProvider);
        return Column(children: [
          _SwitchTile(
            label: 'Voice interaction',
            value: s.voiceEnabled,
            onChanged: (v) => sN.updateField((s) => s.copyWith(voiceEnabled: v)),
          ),
          _SettingsTile(
            label: 'Wake word',
            child: TextFormField(
              initialValue: s.wakeWord,
              style: monoStyle(size: 12, color: KodaColors.text),
              decoration: const InputDecoration(hintText: 'Hey Koda'),
              onChanged: (v) => sN.updateField((s) => s.copyWith(wakeWord: v)),
            ),
          ),
          _SettingsTile(
            label: 'TTS Voice',
            sub: 'Voices from Google TTS engine on device',
            child: FutureBuilder<List<Map<String, String>>>(
              future: tts.getEnglishVoices(),
              builder: (ctx, snap) {
                if (!snap.hasData) {
                  return const LinearProgressIndicator();
                }
                final voices = snap.data!;
                if (voices.isEmpty) {
                  return Text('No voices found. Install Google TTS.',
                      style: monoStyle(size: 11, color: KodaColors.red));
                }
                // Make sure the current value exists in the list, else fallback
                final currentName = s.ttsVoice;
                final validValue = voices.any((v) => v['name'] == currentName)
                    ? currentName
                    : voices.first['name']!;
                return DropdownButtonFormField<String>(
                  initialValue: validValue,
                  dropdownColor: KodaColors.panel2,
                  isExpanded: true,
                  style: monoStyle(size: 11, color: KodaColors.text),
                  decoration: const InputDecoration(),
                  items: voices.map((v) {
                    final name = v['name']!;
                    final locale = v['locale']!;
                    final quality = name.contains('network')
                        ? '🌐'
                        : name.contains('enhanced')
                            ? '⭐'
                            : '';
                    return DropdownMenuItem(
                      value: name,
                      child: Text('$quality $locale — $name',
                          overflow: TextOverflow.ellipsis),
                    );
                  }).toList(),
                  onChanged: (v) async {
                    if (v == null) return;
                    sN.updateField((s) => s.copyWith(ttsVoice: v));
                    // Apply immediately so user can hear the preview
                    final match = voices.firstWhere((x) => x['name'] == v,
                        orElse: () => {});
                    if (match.isNotEmpty) {
                      await tts.setVoice(match['name']!);
                      await tts.speak('Hi! This is how I sound now.');
                    }
                  },
                );
              },
            ),
          ),
        ]);

      case 'motor':
        return Column(children: [
          const SizedBox(height: 4),
          Text('MOTOR TRIM (100 = no compensation)',
              style: monoStyle(size: 10, color: KodaColors.sub, spacing: 1)),
          const SizedBox(height: 12),
          _SliderTile(label: 'Front Left',  value: m.fl.toDouble(), min: 80, max: 120, unit: '%',
              onChanged: (v) => mN.setTrim(fl: v.round())),
          _SliderTile(label: 'Front Right', value: m.fr.toDouble(), min: 80, max: 120, unit: '%',
              onChanged: (v) => mN.setTrim(fr: v.round())),
          _SliderTile(label: 'Rear Left',   value: m.rl.toDouble(), min: 80, max: 120, unit: '%',
              onChanged: (v) => mN.setTrim(rl: v.round())),
          _SliderTile(label: 'Rear Right',  value: m.rr.toDouble(), min: 80, max: 120, unit: '%',
              onChanged: (v) => mN.setTrim(rr: v.round())),
          const Divider(color: KodaColors.border),
          _SliderTile(label: 'Default speed', value: m.defaultSpeed.toDouble(), min: 0, max: 100, unit: '%',
              onChanged: (v) => mN.update(m.copyWith(defaultSpeed: v.round()))),
          _SliderTile(label: 'Max speed', value: m.maxSpeed.toDouble(), min: 0, max: 100, unit: '%',
              onChanged: (v) => mN.update(m.copyWith(maxSpeed: v.round()))),
          _SliderTile(label: 'Max command duration', value: m.maxDurationMs.toDouble(), min: 200, max: 5000, unit: 'ms',
              onChanged: (v) => mN.update(m.copyWith(maxDurationMs: v.round()))),
          _SwitchTile(
            label: 'Auto-stop on BLE disconnect',
            value: m.autoStopOnDisconnect,
            onChanged: (v) => mN.update(m.copyWith(autoStopOnDisconnect: v)),
          ),
          _SwitchTile(
            label: 'Brake mode on stop',
            value: m.brakeOnStop,
            onChanged: (v) => mN.update(m.copyWith(brakeOnStop: v)),
          ),
        ]);

      case 'memory':
        return Column(children: [
          _SwitchTile(
            label: 'Persistent memory',
            value: s.memoryEnabled,
            onChanged: (v) => sN.updateField((s) => s.copyWith(memoryEnabled: v)),
          ),
          _SwitchTile(
            label: 'Cloud backup',
            value: s.cloudSync,
            onChanged: (v) => sN.updateField((s) => s.copyWith(cloudSync: v)),
          ),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: _ActionButton(label: 'EXPORT MEMORY', color: KodaColors.blue, onTap: () {})),
            const SizedBox(width: 8),
            Expanded(child: _ActionButton(label: 'RESET MEMORY', color: KodaColors.red, onTap: () {})),
          ]),
        ]);

      case 'connect':
        return Column(children: [
          _SettingsTile(
            label: 'BLE Device Name',
            sub: 'Name of ESP32 to scan for',
            child: TextFormField(
              initialValue: s.bleDeviceName,
              style: monoStyle(size: 12, color: KodaColors.text),
              decoration: const InputDecoration(hintText: 'KODA-ESP32'),
              onChanged: (v) => sN.updateField((s) => s.copyWith(bleDeviceName: v)),
            ),
          ),
          _SliderTile(
            label: 'BLE watchdog timeout',
            value: s.bleWatchdogMs.toDouble(),
            min: 500, max: 10000, unit: 'ms',
            onChanged: (v) => sN.updateField((s) => s.copyWith(bleWatchdogMs: v.round())),
          ),
        ]);

      case 'system':
        return Column(children: [
          _SwitchTile(
            label: 'Keep screen awake',
            value: s.keepScreenAwake,
            onChanged: (v) => sN.updateField((s) => s.copyWith(keepScreenAwake: v)),
          ),
          _SwitchTile(
            label: 'Developer mode',
            value: s.devMode,
            onChanged: (v) => sN.updateField((s) => s.copyWith(devMode: v)),
          ),
          const Divider(color: KodaColors.border),
          _SettingsTile(label: 'App version',
              child: Text('0.1.0-alpha', style: monoStyle(size: 11, color: KodaColors.dim))),
          const SizedBox(height: 16),
          _ActionButton(
            label: 'FACTORY RESET',
            color: KodaColors.red,
            onTap: () => showDialog(
              context: context,
              builder: (_) => AlertDialog(
                backgroundColor: KodaColors.panel,
                title: Text('Factory Reset', style: condensedStyle(size: 18, color: KodaColors.red)),
                content: Text('This will clear all settings and memories.',
                    style: bodyStyle(color: KodaColors.sub)),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(context),
                      child: Text('CANCEL', style: monoStyle(color: KodaColors.dim))),
                  TextButton(onPressed: () => Navigator.pop(context),
                      child: Text('RESET', style: monoStyle(color: KodaColors.red))),
                ],
              ),
            ),
          ),
        ]);

      case 'context':
        final ctx = ref.read(contextServiceProvider);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: ctx.contextFileNames.map((fileName) {
            return Card(
              color: KodaColors.panel2,
              margin: const EdgeInsets.only(bottom: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: KodaColors.border2),
              ),
              child: ListTile(
                title: Text(fileName, style: monoStyle(size: 14, color: KodaColors.amber)),
                subtitle: Text('Markdown file', style: monoStyle(size: 11, color: KodaColors.sub)),
                trailing: const Icon(Icons.edit, color: KodaColors.dim, size: 20),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => ContextEditorScreen(fileName: fileName)),
                ),
              ),
            );
          }).toList(),
        );

      default:
        return const SizedBox();
    }
  }
}

// ── Settings helpers ──────────────────────────────────────────────────────────
class _SettingsTile extends StatelessWidget {
  final String label;
  final String? sub;
  final Widget child;
  const _SettingsTile({required this.label, this.sub, required this.child});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: bodyStyle(size: 13, weight: FontWeight.w500)),
            if (sub != null) ...[
              const SizedBox(height: 2),
              Text(sub!, style: monoStyle(size: 10, color: KodaColors.sub)),
            ],
            const SizedBox(height: 6),
            child,
          ],
        ),
      );
}

class _SliderTile extends StatelessWidget {
  final String label, unit;
  final double value, min, max;
  final int? divisions;
  final void Function(double) onChanged;
  const _SliderTile({
    required this.label, required this.value,
    required this.min, required this.max,
    required this.unit, required this.onChanged,
    this.divisions,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(label, style: bodyStyle(size: 13)),
                Text('${value.round()}$unit',
                    style: monoStyle(size: 12, color: KodaColors.amber, weight: FontWeight.bold)),
              ],
            ),
            Slider(value: value, min: min, max: max, divisions: divisions, onChanged: onChanged),
          ],
        ),
      );
}

class _SwitchTile extends StatelessWidget {
  final String label;
  final bool value;
  final void Function(bool) onChanged;
  const _SwitchTile({required this.label, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label, style: bodyStyle(size: 13)),
        value: value,
        onChanged: onChanged,
        activeThumbColor: KodaColors.amber,
      );
}

class _ActionButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ActionButton({required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: color.withValues(alpha: 0.4)),
          ),
          child: Center(
            child: Text(label,
                style: monoStyle(size: 10, color: color, spacing: 1)),
          ),
        ),
      );
}

// ── Context Editor Screen ───────────────────────────────────────────────────

class ContextEditorScreen extends ConsumerStatefulWidget {
  final String fileName;
  const ContextEditorScreen({super.key, required this.fileName});

  @override
  ConsumerState<ContextEditorScreen> createState() => _ContextEditorScreenState();
}

class _ContextEditorScreenState extends ConsumerState<ContextEditorScreen> {
  final _controller = TextEditingController();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ctx = ref.read(contextServiceProvider);
    final content = await ctx.readFile(widget.fileName);
    _controller.text = content;
    setState(() => _loading = false);
  }

  Future<void> _save() async {
    final ctx = ref.read(contextServiceProvider);
    await ctx.writeFile(widget.fileName, _controller.text);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KodaColors.bg,
      appBar: AppBar(
        title: Text('Edit ${widget.fileName}', style: monoStyle(size: 16)),
        backgroundColor: KodaColors.panel,
        iconTheme: const IconThemeData(color: KodaColors.dim),
        actions: [
          IconButton(
            icon: const Icon(Icons.save, color: KodaColors.amber),
            onPressed: _loading ? null : _save,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: KodaColors.amber))
          : Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: _controller,
                maxLines: null,
                style: monoStyle(size: 13, color: KodaColors.text),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  hintText: 'Enter markdown...',
                  hintStyle: monoStyle(color: KodaColors.dim),
                ),
              ),
            ),
    );
  }
}
