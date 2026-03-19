import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'theme/koda_theme.dart';
import 'providers/providers.dart';
import 'screens/screens.dart';
import 'widgets/widgets.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Force portrait
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  // Dark system UI
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: KodaColors.bg,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(const ProviderScope(child: KodaApp()));
}

class KodaApp extends StatelessWidget {
  const KodaApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Koda',
        theme: KodaTheme.theme,
        debugShowCheckedModeBanner: false,
        home: const KodaShell(),
      );
}

// ─── Main Shell with bottom nav ───────────────────────────────────────────────
class KodaShell extends ConsumerStatefulWidget {
  const KodaShell({super.key});

  @override
  ConsumerState<KodaShell> createState() => _KodaShellState();
}

class _KodaShellState extends ConsumerState<KodaShell> {
  int _page = 0;

  static const _pages = [
    HomeScreen(),
    BrainScreen(),
    RemoteScreen(),
    SettingsScreen(),
  ];

  static const _navItems = [
    BottomNavigationBarItem(icon: Icon(Icons.home_outlined),    label: 'HOME'),
    BottomNavigationBarItem(icon: Icon(Icons.psychology),       label: 'BRAIN'),
    BottomNavigationBarItem(icon: Icon(Icons.gamepad_outlined), label: 'REMOTE'),
    BottomNavigationBarItem(icon: Icon(Icons.settings),         label: 'SETTINGS'),
  ];

  @override
  Widget build(BuildContext context) {
    final ble   = ref.watch(bleConnectionProvider);
    final brain = ref.watch(brainProvider);

    final pageLabels = ['HOME', 'BRAIN', 'REMOTE', 'SETTINGS'];

    return Scaffold(
      backgroundColor: KodaColors.bg,
      appBar: AppBar(
        backgroundColor: KodaColors.panel,
        elevation: 0,
        title: Row(
          children: [
            const Text('🤖 '),
            Text('KODA', style: Theme.of(context).appBarTheme.titleTextStyle),
          ],
        ),
        actions: [
          // BLE status chip
          GestureDetector(
            onTap: () {
              if (ble.isConnected) {
                ref.read(bleConnectionProvider.notifier).disconnect();
              } else {
                showModalBottomSheet(
                  context: context,
                  backgroundColor: Colors.transparent,
                  isScrollControlled: true,
                  builder: (_) => const BtScannerSheet(),
                );
              }
            },
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: ble.isConnected
                    ? KodaColors.green.withValues(alpha: 0.12)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: ble.isConnected ? KodaColors.green : KodaColors.dim),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    ble.isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
                    size: 12,
                    color: ble.isConnected ? KodaColors.green : KodaColors.dim,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    ble.isConnected
                        ? (ble.connectedDevice?.name ?? 'BT')
                        : 'BT',
                    style: monoStyle(
                        size: 10,
                        color: ble.isConnected ? KodaColors.green : KodaColors.dim),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
        // Status strip below app bar
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: Container(
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: const BoxDecoration(
              color: KodaColors.bg,
              border: Border(bottom: BorderSide(color: KodaColors.border)),
            ),
            child: Row(
              children: [
                _StatusDot(
                  color: ble.isConnected ? KodaColors.green : KodaColors.dim,
                  label: ble.isConnected ? 'BT CONNECTED' : 'BT OFFLINE',
                ),
                const SizedBox(width: 16),
                _StatusDot(
                  color: brain.active ? KodaColors.amber : KodaColors.dim,
                  label: brain.active ? 'BRAIN ACTIVE' : 'BRAIN IDLE',
                ),
                const Spacer(),
                Text('KODA v0.1',
                    style: monoStyle(size: 9, color: KodaColors.amber, spacing: 2)),
                const SizedBox(width: 8),
                Text(pageLabels[_page],
                    style: monoStyle(size: 9, color: KodaColors.dim)),
              ],
            ),
          ),
        ),
      ),
      body: IndexedStack(
        index: _page,
        children: _pages,
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: KodaColors.border)),
        ),
        child: BottomNavigationBar(
          currentIndex: _page,
          onTap: (i) => setState(() => _page = i),
          items: _navItems,
          selectedLabelStyle: monoStyle(size: 9, color: KodaColors.amber, spacing: 1),
          unselectedLabelStyle: monoStyle(size: 9, color: KodaColors.dim),
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  final Color color;
  final String label;
  const _StatusDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Container(
              width: 5, height: 5,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text(label, style: monoStyle(size: 9, color: color)),
        ],
      );
}
