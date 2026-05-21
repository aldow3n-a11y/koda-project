import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/koda_theme.dart';
import '../models/models.dart';
import '../providers/providers.dart';
import '../widgets/widgets.dart';
import '../services/lidar_service.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';

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
  int _currentCameraIndex = -1; // -1 means auto-select default (wide angle)
  bool _isInitInProgress = false;
  List<CameraDescription> _allCameras = [];
  bool _isStreaming = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Defer camera init to post-frame so the widget is fully mounted
    // and the app is guaranteed to be in 'resumed' state before we
    // request permissions (which could pause the app via the dialog).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _initCamera();
    });
  }

  Future<void> _initCamera() async {
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

      _allCameras = await availableCameras();
      if (_allCameras.isEmpty) return;
      
      CameraDescription selectedCamera;

      if (_currentCameraIndex == -1) {
        // Auto-select wide angle back camera (usually ID '2' on S21 FE, or the last back camera)
        final backCameras = _allCameras.where((c) => c.lensDirection == CameraLensDirection.back).toList();
        if (backCameras.length > 1) {
          selectedCamera = backCameras.firstWhere((c) => c.name == '2', orElse: () => backCameras.last);
        } else if (backCameras.isNotEmpty) {
          selectedCamera = backCameras.first;
        } else {
          selectedCamera = _allCameras.first;
        }
        _currentCameraIndex = _allCameras.indexOf(selectedCamera);
        // Fallback if not found
        if (_currentCameraIndex == -1) _currentCameraIndex = 0;
      } else {
        selectedCamera = _allCameras[_currentCameraIndex];
      }
      
      // Dispose old controller if switching
      if (_cameraController != null) {
        if (_isStreaming) {
          try {
            await _cameraController!.stopImageStream();
          } catch (_) {}
          _isStreaming = false;
        }
        await _cameraController!.dispose();
      }

      _cameraController = CameraController(
        selectedCamera, 
        ResolutionPreset.medium, 
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid 
            ? ImageFormatGroup.nv21 
            : ImageFormatGroup.bgra8888,
      );
      await _cameraController!.initialize();
      
      // Save to global provider for the Brain to access
      ref.read(cameraControllerProvider.notifier).state = _cameraController;

      if (mounted) {
        setState(() {
          _isCameraReady = true;
        });
        if (ref.read(faceTrackingEnabledProvider)) {
          _startImageStream();
        }
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
    if (_allCameras.isEmpty) return;
    if (_isStreaming) {
      try {
        _cameraController?.stopImageStream();
      } catch (_) {}
      _isStreaming = false;
    }
    setState(() => _isCameraReady = false);
    _currentCameraIndex = (_currentCameraIndex + 1) % _allCameras.length;
    _initCamera();
  }

  void _startImageStream() {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized || _isStreaming) return;

    final tracker = ref.read(objectTrackerServiceProvider);
    final description = controller.description;

    _isStreaming = true;
    controller.startImageStream((image) {
      tracker.processFrame(image, description, (data) {
        if (mounted) {
          ref.read(objectTrackingDataProvider.notifier).state = data;
        }
      });
    });
  }

  void _stopImageStream() {
    final controller = _cameraController;
    if (controller == null || !_isStreaming) return;

    _isStreaming = false;
    try {
      controller.stopImageStream();
    } catch (e) {
      debugPrint('Error stopping image stream: $e');
    }
    ref.read(objectTrackingDataProvider.notifier).state = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      // Free up the camera when app goes to background
      _isStreaming = false;
      _cameraController?.dispose();
      _cameraController = null;
      ref.read(cameraControllerProvider.notifier).state = null;
      ref.read(objectTrackingDataProvider.notifier).state = null;
      if (mounted) setState(() => _isCameraReady = false);
    } else if (state == AppLifecycleState.resumed) {
      // Small delay to allow Android to fully re-enable the camera
      // hardware after returning from permission dialogs or recents.
      Future.delayed(const Duration(milliseconds: 400), () {
        if (mounted && 
            (_cameraController == null || !_cameraController!.value.isInitialized)) {
          _initCamera();
        }
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_isStreaming) {
      try {
        _cameraController?.stopImageStream();
      } catch (_) {}
    }
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
    final brain  = ref.watch(brainProvider);
    final ble    = ref.watch(bleConnectionProvider);
    final lidar  = ref.watch(lidarProvider);
    final slam   = ref.watch(slamServiceProvider);
    final notifier = ref.read(brainProvider.notifier);

    ref.listen<bool>(faceTrackingEnabledProvider, (prev, next) {
      if (next) {
        _startImageStream();
      } else {
        _stopImageStream();
      }
    });

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
              ],

              const SizedBox(height: 12),

              // LiDAR Map card — above camera preview
              LidarMapCard(
                slam:             slam,
                isReceiving:      lidar.isReceiving,
                pointCount:       lidar.pointCount,
                revision:         lidar.revision,
                slamMode:         lidar.slamMode,
                bootstrapSecsLeft: lidar.bootstrapSecsLeft,
                hasSavedMap:      lidar.hasSavedMap,
                onReset: () => ref.read(lidarProvider.notifier).resetMap(),
                onSave:  () => ref.read(lidarProvider.notifier).saveMap(),
              ),

              const SizedBox(height: 12),

              // Camera preview or Custom Canvas Card
              if (_isCameraReady || brain.canvasContent.type != CanvasType.face) ...[
                KodaCard(
                  padding: EdgeInsets.zero,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      height: 260,   // ~30% taller than before
                      width: double.infinity,
                      child: Builder(
                        builder: (context) {
                          if (brain.canvasContent.type != CanvasType.face) {
                            return CanvasDisplay(
                              canvas: brain.canvasContent,
                              onFinished: () {
                                final notifier = ref.read(brainProvider.notifier);
                                notifier.setCanvasContent(const CanvasContent(type: CanvasType.face));
                                notifier.processInput(
                                  "SYSTEM NOTIFICATION: The visual countdown timer has just finished. Please notify the user.",
                                  isInternal: true,
                                );
                              },
                            );
                          }

                          if (!_isCameraReady) {
                            return Container(
                              color: const Color(0xFF070B0E),
                              child: Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation<Color>(KodaColors.amber),
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      'CAMERA INITIALIZING...',
                                      style: monoStyle(size: 10, color: KodaColors.dim, spacing: 1),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }

                          return Stack(
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
                                    'CAM ${_currentCameraIndex} (${_cameraController!.description.lensDirection.name.toUpperCase()})',
                                    style: monoStyle(size: 9, color: KodaColors.green),
                                  ),
                                ),
                              ),
                              Positioned(
                                bottom: 8, left: 8,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.black54,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: TextButton.icon(
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                      minimumSize: Size.zero,
                                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    onPressed: () {
                                      ref.read(faceTrackingEnabledProvider.notifier).update((state) => !state);
                                    },
                                    icon: Icon(
                                      ref.watch(faceTrackingEnabledProvider) ? Icons.face : Icons.face_outlined,
                                      color: ref.watch(faceTrackingEnabledProvider) ? KodaColors.green : Colors.white70,
                                      size: 16,
                                    ),
                                    label: Text(
                                      ref.watch(faceTrackingEnabledProvider) ? 'TRACKING ON' : 'TRACKING OFF',
                                      style: monoStyle(
                                        size: 9,
                                        color: ref.watch(faceTrackingEnabledProvider) ? KodaColors.green : Colors.white70,
                                        weight: FontWeight.bold,
                                      ),
                                    ),
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
                          );
                        },
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

class _StatChip extends StatelessWidget {
  final String label, value;
  final Color color;
  const _StatChip({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: color.withValues(alpha: 0.25)),
          ),
          child: Column(
            children: [
              Text(label, style: monoStyle(size: 8, color: KodaColors.sub, spacing: 2)),
              const SizedBox(height: 3),
              Text(value, style: monoStyle(size: 11, color: color, weight: FontWeight.bold)),
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
    final lidar = ref.watch(lidarProvider);
    final slam  = ref.watch(slamServiceProvider);

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

          // LiDAR Map card — above D-pad
          LidarMapCard(
            slam:             slam,
            isReceiving:      lidar.isReceiving,
            pointCount:       lidar.pointCount,
            revision:         lidar.revision,
            slamMode:         lidar.slamMode,
            bootstrapSecsLeft: lidar.bootstrapSecsLeft,
            hasSavedMap:      lidar.hasSavedMap,
            onReset: () => ref.read(lidarProvider.notifier).resetMap(),
            onSave:  () => ref.read(lidarProvider.notifier).saveMap(),
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
    {'id': 'lidar',   'label': '📡 LiDAR'},
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
            sub: '2026 Cloud Vision models supported',
            child: Builder(builder: (context) {
              const modelItems = [
                DropdownMenuItem(value: 'qwen3.5',
                    child: Text('Qwen 3.5 — Cloud Vision')),
                DropdownMenuItem(value: 'kimi-k2.5',
                    child: Text('Kimi K2.5 — Cloud Vision')),
                DropdownMenuItem(value: 'devstral-small-2',
                    child: Text('Devstral Small 2 — Cloud Vision')),
                DropdownMenuItem(value: 'ministral-3',
                    child: Text('Ministral 3 — Cloud Vision')),
                DropdownMenuItem(value: 'claude-haiku-4-5-20251001',
                    child: Text('Haiku 4.5 — Fast')),
                DropdownMenuItem(value: 'claude-sonnet-4-6',
                    child: Text('Sonnet 4.6 — Balanced')),
                DropdownMenuItem(value: 'gemini-robotics-er-1.6-preview',
                    child: Text('Gemini Robotics ER 1.6')),
                DropdownMenuItem(value: 'gemini-2.0-flash',
                    child: Text('Gemini 2.0 Flash')),
                DropdownMenuItem(value: 'gemini-2.0-pro-exp',
                    child: Text('Gemini 2.0 Pro')),
                DropdownMenuItem(value: 'gemini-2.5-flash',
                    child: Text('Gemini 2.5 Flash')),
                DropdownMenuItem(value: 'gemini-2.5-flash-lite',
                    child: Text('Gemini 2.5 Lite')),
                DropdownMenuItem(value: 'gemma4-native',
                    child: Text('Gemma 4 Native — Local Inference')),
              ];
              final knownValues = modelItems.map((e) => e.value).toList();
              final safeModel = knownValues.contains(s.model)
                  ? s.model
                  : knownValues.first;
              return DropdownButtonFormField<String>(
                value: safeModel,
                dropdownColor: KodaColors.panel2,
                style: monoStyle(size: 11, color: KodaColors.text),
                decoration: const InputDecoration(),
                items: modelItems,
                onChanged: (v) => sN.updateField((s) => s.copyWith(model: v)),
              );
            }),
          ),
          _SettingsTile(
            label: 'API URL',
            sub: 'Custom endpoint (leave empty for native)',
            child: TextFormField(
              initialValue: s.customApiUrl,
              style: monoStyle(size: 12, color: KodaColors.text),
              decoration: const InputDecoration(
                hintText: 'https://api.example.com/v1/chat/completions',
              ),
              onChanged: (v) => sN.updateField((s) => s.copyWith(customApiUrl: v)),
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
          _SliderTile(
            label: 'Thinking Budget',
            sub: 'For Gemini Robotics ER 1.6 only',
            value: s.thinkingBudget.toDouble(),
            min: 0, max: 32000, unit: ' tk', divisions: 32,
            onChanged: (v) => sN.updateField((s) => s.copyWith(thinkingBudget: v.round())),
          ),
          const SizedBox(height: 16),
          _ActionButton(
            label: 'TEST API CONNECTION',
            color: KodaColors.amber,
            onTap: () async {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Testing connection...'), duration: Duration(seconds: 1)),
              );
              final llm = ref.read(llmServiceProvider);
              // Ensure service is configured with latest settings
              llm.configure(
                apiKey: s.apiKey,
                model: s.model,
                customApiUrl: s.customApiUrl,
                maxTokens: 50,
                thinkingBudget: 0, // Disable thinking for quick ping
              );
              final res = await llm.callRaw('Respond with exactly "OK" if you can hear me.');
              if (mounted) {
                showDialog(
                  context: context,
                  builder: (_) => AlertDialog(
                    backgroundColor: KodaColors.panel,
                    title: Text(res != null ? 'Success' : 'Failed', 
                        style: monoStyle(color: res != null ? KodaColors.green : KodaColors.red)),
                    content: Text(res ?? 'Check your API key, model name, and internet connection. Check logs for details.',
                        style: bodyStyle(color: KodaColors.text)),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(context), 
                          child: Text('CLOSE', style: monoStyle(color: KodaColors.amber))),
                    ],
                  ),
                );
              }
            },
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

      case 'lidar':
        return Column(children: [
          // ── Angular offset calibration ──────────────────────────────────
          KodaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('ANGULAR OFFSET', style: monoStyle(size: 11, color: KodaColors.amber, spacing: 2)),
                const SizedBox(height: 6),
                Text(
                  'Rotate the angle map so 0° = robot forward direction.\n'
                  'Point Koda at a wall, note the reported angle, set offset = that angle.',
                  style: monoStyle(size: 10, color: KodaColors.sub),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Text('OFFSET', style: monoStyle(size: 10, color: KodaColors.dim)),
                    const Spacer(),
                    Text(
                      '${s.lidarAngularOffset.toStringAsFixed(1)}°',
                      style: monoStyle(size: 13, color: KodaColors.amber),
                    ),
                  ],
                ),
                Slider(
                  value: s.lidarAngularOffset,
                  min: 0,
                  max: 359,
                  divisions: 359,
                  activeColor: KodaColors.amber,
                  inactiveColor: KodaColors.border,
                  onChanged: (v) => sN.updateField(
                    (s) => s.copyWith(lidarAngularOffset: v),
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('0°', style: monoStyle(size: 9, color: KodaColors.dim)),
                    Text('180°', style: monoStyle(size: 9, color: KodaColors.dim)),
                    Text('359°', style: monoStyle(size: 9, color: KodaColors.dim)),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => sN.updateField((s) => s.copyWith(lidarAngularOffset: 0.0)),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: KodaColors.border),
                          foregroundColor: KodaColors.dim,
                        ),
                        child: Text('RESET TO 0°', style: monoStyle(size: 10)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => sN.updateField((s) => s.copyWith(lidarAngularOffset: 105.0)),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: KodaColors.amber.withValues(alpha: 0.4)),
                          foregroundColor: KodaColors.amber,
                        ),
                        child: Text('RESET TO 105°', style: monoStyle(size: 10, color: KodaColors.amber)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // ── Live scan stats ─────────────────────────────────────────────
          const SizedBox(height: 12),

          // ── Dot decay time ──────────────────────────────────────────────
          KodaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('DOT DECAY', style: monoStyle(size: 11, color: KodaColors.amber, spacing: 2)),
                const SizedBox(height: 6),
                Text(
                  'How long before obstacle dots fade when no longer seen by LiDAR. '
                  '0 = never decay.',
                  style: monoStyle(size: 10, color: KodaColors.sub),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Text('DECAY TIME', style: monoStyle(size: 10, color: KodaColors.dim)),
                    const Spacer(),
                    Text(
                      s.lidarDecaySec == 0
                          ? 'NEVER'
                          : '${s.lidarDecaySec}s',
                      style: monoStyle(size: 13, color: KodaColors.blue),
                    ),
                  ],
                ),
                Slider(
                  value: s.lidarDecaySec.toDouble(),
                  min: 0,
                  max: 60,
                  divisions: 60,
                  activeColor: KodaColors.blue,
                  inactiveColor: KodaColors.border,
                  onChanged: (v) => sN.updateField(
                    (s) => s.copyWith(lidarDecaySec: v.round()),
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Never', style: monoStyle(size: 9, color: KodaColors.dim)),
                    Text('30s', style: monoStyle(size: 9, color: KodaColors.dim)),
                    Text('60s', style: monoStyle(size: 9, color: KodaColors.dim)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          Consumer(builder: (context, ref, _) {
            final lidar = ref.watch(lidarProvider);
            return KodaCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('LIVE SCAN', style: monoStyle(size: 11, color: KodaColors.amber, spacing: 2)),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _StatChip(
                        label: 'STATUS',
                        value: lidar.isReceiving ? 'LIVE' : 'NO SIGNAL',
                        color: lidar.isReceiving ? KodaColors.green : KodaColors.dim,
                      ),
                      const SizedBox(width: 8),
                      _StatChip(
                        label: 'POINTS',
                        value: '${lidar.pointCount}',
                        color: KodaColors.amber,
                      ),
                      const SizedBox(width: 8),
                      _StatChip(
                        label: 'NEAREST',
                        value: lidar.nearestMm != null
                            ? '${(lidar.nearestMm! / 10).round()}cm'
                            : '--',
                        color: KodaColors.blue,
                      ),
                    ],
                  ),
                  if (lidar.isReceiving && lidar.nearestAngleDeg != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Nearest obstacle at ${lidar.nearestAngleDeg!.toStringAsFixed(0)}° '
                      '— if this should be 0° (forward), set offset = ${lidar.nearestAngleDeg!.toStringAsFixed(0)}°',
                      style: monoStyle(size: 10, color: KodaColors.sub),
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () {
                          final angle = lidar.nearestAngleDeg!;
                          sN.updateField((s) => s.copyWith(lidarAngularOffset: angle));
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1A1200),
                          foregroundColor: KodaColors.amber,
                          side: const BorderSide(color: KodaColors.amber),
                          elevation: 0,
                        ),
                        child: Text(
                          'SET FORWARD = ${lidar.nearestAngleDeg!.toStringAsFixed(0)}°',
                          style: monoStyle(size: 11, color: KodaColors.amber),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            );
          }),
          const SizedBox(height: 12),

          // ── Dead Reckoning Calibration ──────────────────────────────────
          KodaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('DEAD RECKONING', style: monoStyle(size: 11, color: KodaColors.amber, spacing: 2)),
                const SizedBox(height: 6),
                Text(
                  'Physical calibration parameters for estimating robot movement from motor commands.',
                  style: monoStyle(size: 10, color: KodaColors.sub),
                ),
                const SizedBox(height: 14),
                
                // Wheelbase
                Row(
                  children: [
                    Text('WHEELBASE', style: monoStyle(size: 10, color: KodaColors.dim)),
                    const Spacer(),
                    Text('${s.wheelbaseMm.toStringAsFixed(1)} mm', style: monoStyle(size: 12, color: KodaColors.blue)),
                  ],
                ),
                Slider(
                  value: s.wheelbaseMm, min: 50, max: 250, divisions: 200,
                  activeColor: KodaColors.blue, inactiveColor: KodaColors.border,
                  onChanged: (v) => sN.updateField((s) => s.copyWith(wheelbaseMm: v)),
                ),

                // Speed Calibration
                Row(
                  children: [
                    Text('100% SPEED =', style: monoStyle(size: 10, color: KodaColors.dim)),
                    const Spacer(),
                    Text('${s.mmPerSecAt100pct.toStringAsFixed(1)} mm/s', style: monoStyle(size: 12, color: KodaColors.blue)),
                  ],
                ),
                Slider(
                  value: s.mmPerSecAt100pct, min: 100, max: 600, divisions: 100,
                  activeColor: KodaColors.blue, inactiveColor: KodaColors.border,
                  onChanged: (v) => sN.updateField((s) => s.copyWith(mmPerSecAt100pct: v)),
                ),

                // Turn Factor
                Row(
                  children: [
                    Text('TURN FACTOR', style: monoStyle(size: 10, color: KodaColors.dim)),
                    const Spacer(),
                    Text('${s.turnCalibrationFactor.toStringAsFixed(2)}x', style: monoStyle(size: 12, color: KodaColors.blue)),
                  ],
                ),
                Slider(
                  value: s.turnCalibrationFactor, min: 0.1, max: 2.5, divisions: 48,
                  activeColor: KodaColors.blue, inactiveColor: KodaColors.border,
                  onChanged: (v) => sN.updateField((s) => s.copyWith(turnCalibrationFactor: v)),
                ),

                const Divider(color: KodaColors.border, height: 24),
                
                // IMU Heading
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('PHONE IMU GYROSCOPE', style: monoStyle(size: 11, color: KodaColors.amber)),
                          const SizedBox(height: 2),
                          Text('Use phone hardware (Gyro+Accel sensor fusion) for true turning.', style: monoStyle(size: 9, color: KodaColors.dim)),
                        ],
                      ),
                    ),
                    Switch(
                      value: s.useImuHeading,
                      activeColor: KodaColors.amber,
                      onChanged: (v) => sN.updateField((s) => s.copyWith(useImuHeading: v)),
                    ),
                  ],
                ),
                if (s.useImuHeading) ...[
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('INVERT TURN DIRECTION', style: monoStyle(size: 10, color: KodaColors.amber)),
                      Switch(
                        value: s.imuInvertTurn,
                        activeColor: KodaColors.amber,
                        onChanged: (v) => sN.updateField((s) => s.copyWith(imuInvertTurn: v)),
                      ),
                    ],
                  ),
                ],
              ],
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
  final String? sub;
  final double value, min, max;
  final int? divisions;
  final void Function(double) onChanged;
  const _SliderTile({
    required this.label, required this.value,
    required this.min, required this.max,
    required this.unit, required this.onChanged,
    this.sub,
    this.divisions,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(label, style: bodyStyle(size: 13)),
                Text('${value.round()}$unit',
                    style: monoStyle(size: 12, color: KodaColors.amber, weight: FontWeight.bold)),
              ],
            ),
            if (sub != null) ...[
              const SizedBox(height: 2),
              Text(sub!, style: monoStyle(size: 10, color: KodaColors.sub)),
            ],
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

// ─── Display Canvas Widgets ──────────────────────────────────────────────────
class CanvasDisplay extends StatelessWidget {
  final CanvasContent canvas;
  final VoidCallback onFinished;

  const CanvasDisplay({
    super.key,
    required this.canvas,
    required this.onFinished,
  });

  @override
  Widget build(BuildContext context) {
    switch (canvas.type) {
      case CanvasType.timer:
        return CanvasTimerWidget(
          seconds: canvas.seconds ?? 60,
          text: canvas.text ?? 'Timer',
          onFinished: onFinished,
        );
      case CanvasType.image:
      case CanvasType.gif:
        return CanvasImageWidget(
          url: canvas.url ?? '',
          text: canvas.text,
        );
      case CanvasType.weather:
        return CanvasWeatherWidget(
          temp: canvas.temp ?? '72°F',
          condition: canvas.condition ?? 'sunny',
          location: canvas.text ?? 'Home',
        );
      case CanvasType.message:
        return CanvasMessageWidget(
          title: canvas.title ?? 'MESSAGE',
          subtitle: canvas.subtitle ?? '',
        );
      case CanvasType.radar:
        return const CanvasRadarWidget();
      case CanvasType.audio:
        return CanvasAudioWidget(
          title: canvas.title ?? 'Audio Stream',
          subtitle: canvas.subtitle ?? 'Koda Companion',
        );
      case CanvasType.youtube:
        return CanvasYoutubeWidget(
          url: canvas.url ?? '',
          caption: canvas.text,
        );
      default:
        return const SizedBox.shrink();
    }
  }
}

class CanvasTimerWidget extends StatefulWidget {
  final int seconds;
  final String text;
  final VoidCallback onFinished;

  const CanvasTimerWidget({
    super.key,
    required this.seconds,
    required this.text,
    required this.onFinished,
  });

  @override
  State<CanvasTimerWidget> createState() => _CanvasTimerWidgetState();
}

class _CanvasTimerWidgetState extends State<CanvasTimerWidget> {
  late int _timeLeft;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timeLeft = widget.seconds;
    _startTimer();
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_timeLeft > 0) {
        if (mounted) {
          setState(() => _timeLeft--);
        }
      } else {
        _timer?.cancel();
        widget.onFinished();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final minutes = _timeLeft ~/ 60;
    final seconds = _timeLeft % 60;
    final timeStr = '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    final progress = widget.seconds > 0 ? _timeLeft / widget.seconds : 0.0;

    return Container(
      color: const Color(0xFF070B0E),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 130,
                  height: 130,
                  child: CircularProgressIndicator(
                    value: progress,
                    strokeWidth: 6,
                    backgroundColor: KodaColors.border2,
                    valueColor: const AlwaysStoppedAnimation<Color>(KodaColors.amber),
                  ),
                ),
                Text(
                  timeStr,
                  style: GoogleFonts.shareTechMono(
                    fontSize: 32,
                    color: KodaColors.amber,
                    fontWeight: FontWeight.bold,
                    shadows: [
                      const Shadow(
                        blurRadius: 10,
                        color: KodaColors.amber,
                        offset: Offset(0, 0),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              widget.text.toUpperCase(),
              style: monoStyle(size: 11, color: KodaColors.sub, spacing: 2),
            ),
          ],
        ),
      ),
    );
  }
}

class CanvasImageWidget extends StatelessWidget {
  final String url;
  final String? text;

  const CanvasImageWidget({
    super.key,
    required this.url,
    this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF070B0E),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.network(
            url,
            fit: BoxFit.contain,
            loadingBuilder: (context, child, loadingProgress) {
              if (loadingProgress == null) return child;
              return const Center(
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  valueColor: AlwaysStoppedAnimation<Color>(KodaColors.amber),
                ),
              );
            },
            errorBuilder: (context, error, stackTrace) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.broken_image, color: KodaColors.red, size: 40),
                    const SizedBox(height: 8),
                    Text(
                      'FAILED TO LOAD MEDIA',
                      style: monoStyle(size: 10, color: KodaColors.red, spacing: 1),
                    ),
                  ],
                ),
              );
            },
          ),
          if (text != null && text!.isNotEmpty)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.transparent, Colors.black87],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
                child: Text(
                  text!.toUpperCase(),
                  textAlign: TextAlign.center,
                  style: monoStyle(size: 10, color: KodaColors.amber, spacing: 1),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class CanvasWeatherWidget extends StatelessWidget {
  final String temp;
  final String condition;
  final String location;

  const CanvasWeatherWidget({
    super.key,
    required this.temp,
    required this.condition,
    required this.location,
  });

  IconData _getIcon() {
    final cond = condition.toLowerCase();
    if (cond.contains('sun') || cond.contains('clear')) return Icons.wb_sunny_rounded;
    if (cond.contains('rain') || cond.contains('drizzle') || cond.contains('shower')) return Icons.cloudy_snowing;
    if (cond.contains('snow') || cond.contains('ice') || cond.contains('freeze')) return Icons.ac_unit_rounded;
    return Icons.cloud_rounded; // default to cloudy
  }

  Color _getIconColor() {
    final cond = condition.toLowerCase();
    if (cond.contains('sun') || cond.contains('clear')) return const Color(0xFFFFD54F); // Amber-gold
    if (cond.contains('rain')) return const Color(0xFF64B5F6); // Blue
    if (cond.contains('snow')) return const Color(0xFF80DEEA); // Ice cyan
    return const Color(0xFFCFD8DC); // Grey-blue
  }

  List<Color> _getBackgroundGradient() {
    final cond = condition.toLowerCase();
    if (cond.contains('sun') || cond.contains('clear')) {
      return [const Color(0xFF1E1202), const Color(0xFF0F0B06)];
    }
    if (cond.contains('rain')) {
      return [const Color(0xFF0D1B2A), const Color(0xFF080F18)];
    }
    if (cond.contains('snow')) {
      return [const Color(0xFF142429), const Color(0xFF0B1214)];
    }
    return [const Color(0xFF15181C), const Color(0xFF0D0F12)];
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: _getBackgroundGradient(),
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            right: -30,
            top: -20,
            child: Icon(
              _getIcon(),
              size: 160,
              color: _getIconColor().withValues(alpha: 0.05),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          location.toUpperCase(),
                          style: monoStyle(size: 11, color: KodaColors.sub, spacing: 2),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          condition.toUpperCase(),
                          style: condensedStyle(size: 18, color: KodaColors.text, weight: FontWeight.w600),
                        ),
                      ],
                    ),
                    Icon(
                      _getIcon(),
                      size: 44,
                      color: _getIconColor(),
                      shadows: [
                        Shadow(
                          color: _getIconColor().withValues(alpha: 0.4),
                          blurRadius: 15,
                        ),
                      ],
                    ),
                  ],
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      temp.replaceAll(RegExp(r'[^0-9\-]'), ''),
                      style: GoogleFonts.shareTechMono(
                        fontSize: 68,
                        fontWeight: FontWeight.bold,
                        color: KodaColors.text,
                        height: 0.9,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      temp.contains('C') || temp.contains('c') ? '°C' : '°F',
                      style: GoogleFonts.shareTechMono(
                        fontSize: 28,
                        color: KodaColors.amber,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class CanvasMessageWidget extends StatefulWidget {
  final String title;
  final String subtitle;

  const CanvasMessageWidget({
    super.key,
    required this.title,
    required this.subtitle,
  });

  @override
  State<CanvasMessageWidget> createState() => _CanvasMessageWidgetState();
}

class _CanvasMessageWidgetState extends State<CanvasMessageWidget> {
  bool _cursorVisible = true;
  Timer? _cursorTimer;

  @override
  void initState() {
    super.initState();
    _cursorTimer = Timer.periodic(const Duration(milliseconds: 500), (t) {
      if (mounted) setState(() => _cursorVisible = !_cursorVisible);
    });
  }

  @override
  void dispose() {
    _cursorTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isAlert = widget.title.toUpperCase().contains('ALERT') ||
        widget.title.toUpperCase().contains('WARN') ||
        widget.title.toUpperCase().contains('ERR');

    final color = isAlert ? KodaColors.red : KodaColors.amber;

    return Container(
      color: const Color(0xFF06090C),
      padding: const EdgeInsets.all(16),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF0A0F14),
          border: Border.all(color: color.withValues(alpha: 0.3), width: 1.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.06),
                border: Border(bottom: BorderSide(color: color.withValues(alpha: 0.2))),
              ),
              child: Row(
                children: [
                  Icon(
                    isAlert ? Icons.warning_amber_rounded : Icons.terminal_rounded,
                    size: 14,
                    color: color,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    widget.title.toUpperCase(),
                    style: monoStyle(size: 11, color: color, weight: FontWeight.bold, spacing: 1.5),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: RichText(
                  text: TextSpan(
                    style: GoogleFonts.shareTechMono(
                      fontSize: 12,
                      color: KodaColors.text,
                      height: 1.4,
                    ),
                    children: [
                      TextSpan(text: widget.subtitle),
                      TextSpan(
                        text: _cursorVisible ? ' █' : '  ',
                        style: monoStyle(size: 12, color: color),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CanvasRadarWidget extends StatefulWidget {
  const CanvasRadarWidget({super.key});

  @override
  State<CanvasRadarWidget> createState() => _CanvasRadarWidgetState();
}

class _CanvasRadarWidgetState extends State<CanvasRadarWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF040608),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Consumer(
            builder: (context, ref, _) {
              final lidar = ref.watch(lidarProvider);
              return AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  return CustomPaint(
                    painter: _RadarPainter(
                      sweepAngle: _controller.value * 2.0 * math.pi,
                      points: lidar.points,
                    ),
                  );
                },
              );
            },
          ),
          Positioned(
            left: 12,
            top: 12,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'LIDAR ACTIVE SWEEP',
                  style: monoStyle(size: 9, color: KodaColors.green, spacing: 1.5, weight: FontWeight.bold),
                ),
                Text(
                  'RADAR RANGE: 4.0M',
                  style: monoStyle(size: 8, color: KodaColors.dim),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  final double sweepAngle;
  final List<LidarPoint> points;

  _RadarPainter({required this.sweepAngle, required this.points});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 10;

    final gridPaint = Paint()
      ..color = KodaColors.green.withValues(alpha: 0.15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    canvas.drawCircle(center, radius, gridPaint);
    canvas.drawCircle(center, radius * 0.66, gridPaint);
    canvas.drawCircle(center, radius * 0.33, gridPaint);

    canvas.drawLine(Offset(center.dx - radius, center.dy), Offset(center.dx + radius, center.dy), gridPaint);
    canvas.drawLine(Offset(center.dx, center.dy - radius), Offset(center.dx, center.dy + radius), gridPaint);

    final sweepPaint = Paint()
      ..shader = RadialGradient(
        colors: [KodaColors.green.withValues(alpha: 0.15), Colors.transparent],
      ).createShader(Rect.fromCircle(center: center, radius: radius))
      ..style = PaintingStyle.fill;

    final path = Path()
      ..moveTo(center.dx, center.dy)
      ..arcTo(
        Rect.fromCircle(center: center, radius: radius),
        sweepAngle - 0.4,
        0.4,
        false,
      )
      ..close();
    canvas.drawPath(path, sweepPaint);

    final linePaint = Paint()
      ..color = KodaColors.green.withValues(alpha: 0.6)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      center,
      Offset(
        center.dx + radius * math.cos(sweepAngle),
        center.dy + radius * math.sin(sweepAngle),
      ),
      linePaint,
    );

    final pointPaint = Paint()
      ..color = KodaColors.green
      ..style = PaintingStyle.fill;

    const maxRadarRangeMm = 4000.0;

    for (final pt in points) {
      if (pt.distanceMm < 50) continue;

      final angleRad = (pt.angleDeg - 90.0) * math.pi / 180.0;
      final distPct = (pt.distanceMm / maxRadarRangeMm).clamp(0.0, 1.0);
      final r = distPct * radius;

      final px = center.dx + r * math.cos(angleRad);
      final py = center.dy + r * math.sin(angleRad);

      canvas.drawCircle(Offset(px, py), 2.0, pointPaint);

      final glowPaint = Paint()
        ..color = KodaColors.green.withValues(alpha: 0.1)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(px, py), 4.5, glowPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _RadarPainter oldDelegate) => true;
}

class CanvasAudioWidget extends StatefulWidget {
  final String title;
  final String subtitle;

  const CanvasAudioWidget({
    super.key,
    required this.title,
    required this.subtitle,
  });

  @override
  State<CanvasAudioWidget> createState() => _CanvasAudioWidgetState();
}

class _CanvasAudioWidgetState extends State<CanvasAudioWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _rotationController;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();
  }

  @override
  void dispose() {
    _rotationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF080C0F),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Center(
              child: AnimatedBuilder(
                animation: _rotationController,
                builder: (context, child) {
                  return Transform.rotate(
                    angle: _rotationController.value * 2.0 * math.pi,
                    child: child,
                  );
                },
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 140,
                      height: 140,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: const Color(0xFF0F1215),
                        border: Border.all(color: const Color(0xFF282D35), width: 2),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.4),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Center(
                        child: Container(
                          width: 110,
                          height: 110,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: const Color(0xFF191D23), width: 3),
                          ),
                        ),
                      ),
                    ),
                    Container(
                      width: 48,
                      height: 48,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: KodaColors.amber,
                      ),
                      child: const Center(
                        child: Icon(
                          Icons.music_note_rounded,
                          color: Color(0xFF0F1215),
                          size: 22,
                        ),
                      ),
                    ),
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(0xFF0F1215),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'NOW PLAYING',
                  style: monoStyle(size: 9, color: KodaColors.amber, spacing: 1.5, weight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  widget.title.toUpperCase(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: condensedStyle(size: 16, color: KodaColors.text, weight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                Text(
                  widget.subtitle.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: monoStyle(size: 10, color: KodaColors.sub),
                ),
                const SizedBox(height: 16),
                const _WaveformVisualizer(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WaveformVisualizer extends StatefulWidget {
  const _WaveformVisualizer();

  @override
  State<_WaveformVisualizer> createState() => _WaveformVisualizerState();
}

class _WaveformVisualizerState extends State<_WaveformVisualizer>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  final _random = math.Random();

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          children: List.generate(10, (idx) {
            final h = 4.0 + _random.nextDouble() * 20.0;
            return Container(
              width: 3,
              height: h,
              margin: const EdgeInsets.only(right: 3),
              decoration: BoxDecoration(
                color: KodaColors.amber.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(1.5),
              ),
            );
          }),
        );
      },
    );
  }
}

class CanvasYoutubeWidget extends StatefulWidget {
  final String url;
  final String? caption;

  const CanvasYoutubeWidget({
    super.key,
    required this.url,
    this.caption,
  });

  @override
  State<CanvasYoutubeWidget> createState() => _CanvasYoutubeWidgetState();
}

class _CanvasYoutubeWidgetState extends State<CanvasYoutubeWidget> {
  late YoutubePlayerController _controller;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _initController();
  }

  @override
  void didUpdateWidget(CanvasYoutubeWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      if (_initialized) {
        _controller.dispose();
        _initialized = false;
      }
      _initController();
    }
  }

  void _initController() {
    final videoId = YoutubePlayer.convertUrlToId(widget.url);
    if (videoId != null) {
      _controller = YoutubePlayerController(
        initialVideoId: videoId,
        flags: const YoutubePlayerFlags(
          autoPlay: true,
          mute: false,
          loop: true,
          isLive: false,
          forceHD: false,
          enableCaption: true,
        ),
      );
      _initialized = true;
    }
  }

  @override
  void deactivate() {
    if (_initialized) {
      _controller.pause();
    }
    super.deactivate();
  }

  @override
  void dispose() {
    if (_initialized) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return Container(
        color: const Color(0xFF040608),
        alignment: Alignment.center,
        child: Text(
          'INVALID YOUTUBE URL',
          style: monoStyle(size: 12, color: KodaColors.red),
        ),
      );
    }

    return Container(
      color: const Color(0xFF040608),
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: KodaColors.border, width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: KodaColors.amber.withValues(alpha: 0.15),
                    blurRadius: 20,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: YoutubePlayer(
                  controller: _controller,
                  showVideoProgressIndicator: true,
                  progressIndicatorColor: KodaColors.amber,
                  progressColors: const ProgressBarColors(
                    playedColor: KodaColors.amber,
                    handleColor: KodaColors.amberL,
                  ),
                ),
              ),
            ),
          ),
          if (widget.caption != null && widget.caption!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              widget.caption!,
              style: monoStyle(size: 11, color: KodaColors.text),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }
}
