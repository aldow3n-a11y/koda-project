import 'package:flutter/material.dart';
import '../theme/koda_theme.dart';
import '../models/models.dart';
import '../providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
export 'robot_face.dart';
export 'map_painter.dart';

// ─── KodaCard ─────────────────────────────────────────────────────────────────
class KodaCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets? padding;
  final Color? borderColor;

  const KodaCard({
    super.key,
    required this.child,
    this.padding,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: padding ?? const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: KodaColors.panel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: borderColor ?? KodaColors.border),
        ),
        child: child,
      );
}

// ─── Section Label ────────────────────────────────────────────────────────────
class SectionLabel extends StatelessWidget {
  final String text;
  final Color? color;

  const SectionLabel(this.text, {super.key, this.color});

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: monoStyle(
          size: 10,
          color: color ?? KodaColors.sub,
          spacing: 2,
        ),
      );
}

// ─── Status Badge ─────────────────────────────────────────────────────────────
class StatusBadge extends StatelessWidget {
  final String label;
  final Color color;

  const StatusBadge({super.key, required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withOpacity(0.4)),
        ),
        child: Text(
          label,
          style: monoStyle(size: 9, color: color, spacing: 2),
        ),
      );
}

// ─── Speed Slider ─────────────────────────────────────────────────────────────
class SpeedSlider extends ConsumerWidget {
  const SpeedSlider({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final speed = ref.watch(remoteSpeedProvider);
    final pwm = (speed / 100.0 * 255).round();

    return KodaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const SectionLabel('SPEED'),
              Row(
                children: [
                  Text(
                    '$speed%',
                    style: monoStyle(
                        size: 20, color: KodaColors.amber, weight: FontWeight.bold),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '= $pwm PWM',
                    style: monoStyle(size: 9, color: KodaColors.dim),
                  ),
                ],
              ),
            ],
          ),
          Slider(
            value: speed.toDouble(),
            min: 0,
            max: 100,
            onChanged: (v) =>
                ref.read(remoteSpeedProvider.notifier).state = v.round(),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: ['0%', '25%', '50%', '75%', '100%']
                .map((l) => Text(l, style: monoStyle(size: 8, color: KodaColors.dim)))
                .toList(),
          ),
          const SizedBox(height: 10),
          // Quick presets
          Row(
            children: [
              _PresetButton(label: 'SLOW', value: 35),
              const SizedBox(width: 6),
              _PresetButton(label: 'NORM', value: 60),
              const SizedBox(width: 6),
              _PresetButton(label: 'FAST', value: 85),
            ],
          ),
        ],
      ),
    );
  }
}

class _PresetButton extends ConsumerWidget {
  final String label;
  final int value;

  const _PresetButton({required this.label, required this.value});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final speed = ref.watch(remoteSpeedProvider);
    final active = speed == value;
    return Expanded(
      child: GestureDetector(
        onTap: () => ref.read(remoteSpeedProvider.notifier).state = value,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: active ? const Color(0xFF1A1200) : KodaColors.panel2,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: active ? KodaColors.amber : KodaColors.border2,
            ),
          ),
          child: Column(
            children: [
              Text(label,
                  style: condensedStyle(
                      size: 11,
                      color: active ? KodaColors.amber : KodaColors.sub,
                      spacing: 2)),
              Text('$value%',
                  style: monoStyle(
                      size: 9,
                      color: active ? KodaColors.amber : KodaColors.dim)),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── D-Pad Widget ─────────────────────────────────────────────────────────────
class DPadWidget extends ConsumerStatefulWidget {
  final void Function(KodaCmd cmd, int speed) onPress;
  final void Function() onRelease;

  const DPadWidget({
    super.key,
    required this.onPress,
    required this.onRelease,
  });

  @override
  ConsumerState<DPadWidget> createState() => _DPadWidgetState();
}

class _DPadWidgetState extends ConsumerState<DPadWidget> {
  KodaCmd? _pressed;

  static const _buttons = [
    _DBtn(KodaCmd.forward,  '▲', '',     0, 1),
    _DBtn(KodaCmd.turnCcw,  '↺', 'CCW', 1, 0),
    _DBtn(KodaCmd.stop,     '■', 'STOP', 1, 1),
    _DBtn(KodaCmd.turnCw,   '↻', 'CW',  1, 2),
    _DBtn(KodaCmd.backward, '▼', '',     2, 1),
  ];

  @override
  Widget build(BuildContext context) {
    final speed = ref.watch(remoteSpeedProvider);
    // Build 3x3 grid
    final grid = List<List<_DBtn?>>.generate(3, (_) => List.filled(3, null));
    for (final b in _buttons) grid[b.row][b.col] = b;

    return Column(
      children: List.generate(3, (ri) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(3, (ci) {
            final btn = grid[ri][ci];
            if (btn == null) return const SizedBox(width: 68);
            final isPressed = _pressed == btn.cmd;
            final isStop = btn.cmd == KodaCmd.stop;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: GestureDetector(
                onTapDown: (_) {
                  setState(() => _pressed = btn.cmd);
                  widget.onPress(btn.cmd, speed);
                },
                onTapUp: (_) {
                  setState(() => _pressed = null);
                  widget.onRelease();
                },
                onTapCancel: () {
                  setState(() => _pressed = null);
                  widget.onRelease();
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 80),
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: isPressed
                        ? const Color(0xFF2D1800)
                        : isStop
                            ? const Color(0xFF1A0808)
                            : KodaColors.panel2,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isPressed ? KodaColors.amber : KodaColors.border2,
                      width: 2,
                    ),
                    boxShadow: isPressed
                        ? [BoxShadow(color: KodaColors.amber.withOpacity(0.3), blurRadius: 12)]
                        : null,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        btn.icon,
                        style: TextStyle(
                          fontSize: isStop ? 18 : 24,
                          color: isPressed
                              ? KodaColors.amber
                              : isStop
                                  ? KodaColors.red
                                  : KodaColors.text,
                        ),
                      ),
                      if (btn.sub.isNotEmpty)
                        Text(
                          btn.sub,
                          style: monoStyle(
                            size: 8,
                            color: isPressed ? KodaColors.amber : KodaColors.dim,
                            spacing: 1,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ),
      )),
    );
  }
}

class _DBtn {
  final KodaCmd cmd;
  final String icon;
  final String sub;
  final int row, col;
  const _DBtn(this.cmd, this.icon, this.sub, this.row, this.col);
}

// ─── Motor Trim Widget ────────────────────────────────────────────────────────
class MotorTrimWidget extends ConsumerStatefulWidget {
  const MotorTrimWidget({super.key});

  @override
  ConsumerState<MotorTrimWidget> createState() => _MotorTrimWidgetState();
}

class _MotorTrimWidgetState extends ConsumerState<MotorTrimWidget> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(motorConfigProvider);
    final notifier = ref.read(motorConfigProvider.notifier);
    final trims = {'FL': config.fl, 'FR': config.fr, 'RL': config.rl, 'RR': config.rr};
    final allNominal = trims.values.every((v) => v == 100);

    return KodaCard(
      child: Column(
        children: [
          // Header row
          GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Row(
              children: [
                const SectionLabel('MOTOR TRIM'),
                if (!allNominal) ...[
                  const SizedBox(width: 8),
                  Container(
                    width: 6, height: 6,
                    decoration: const BoxDecoration(
                        color: KodaColors.amber, shape: BoxShape.circle),
                  ),
                ],
                const Spacer(),
                // Mini badges
                ...trims.entries.map((e) => Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: KodaColors.panel2,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: e.value == 100
                                ? KodaColors.border
                                : KodaColors.amber.withOpacity(0.4),
                          ),
                        ),
                        child: Text(
                          '${e.key}:${e.value}',
                          style: monoStyle(
                              size: 9,
                              color: e.value == 100 ? KodaColors.dim : KodaColors.amber),
                        ),
                      ),
                    )),
                const SizedBox(width: 8),
                Icon(
                  _expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                  color: KodaColors.dim, size: 18,
                ),
              ],
            ),
          ),

          // Expanded sliders
          if (_expanded) ...[
            const SizedBox(height: 12),
            const Divider(color: KodaColors.border, height: 1),
            const SizedBox(height: 10),
            ...trims.entries.map((e) => _TrimRow(
                  label: e.key,
                  value: e.value,
                  onChanged: (v) {
                    switch (e.key) {
                      case 'FL': notifier.setTrim(fl: v); break;
                      case 'FR': notifier.setTrim(fr: v); break;
                      case 'RL': notifier.setTrim(rl: v); break;
                      case 'RR': notifier.setTrim(rr: v); break;
                    }
                  },
                )),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _KodaButton(
                    label: 'RESET ALL → 100%',
                    color: KodaColors.blue,
                    onTap: notifier.resetTrim,
                  ),
                ),
                const SizedBox(width: 8),
                _KodaButton(
                  label: 'DONE',
                  color: KodaColors.sub,
                  onTap: () => setState(() => _expanded = false),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _TrimRow extends StatelessWidget {
  final String label;
  final int value;
  final void Function(int) onChanged;

  const _TrimRow({required this.label, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(label, style: monoStyle(size: 11, color: KodaColors.sub)),
                Row(
                  children: [
                    _SmallBtn('−', () => onChanged((value - 1).clamp(80, 120))),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 44,
                      child: Text(
                        '$value%',
                        textAlign: TextAlign.center,
                        style: monoStyle(
                          size: 13,
                          color: value == 100 ? KodaColors.text : KodaColors.amber,
                          weight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _SmallBtn('+', () => onChanged((value + 1).clamp(80, 120))),
                  ],
                ),
              ],
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor:
                    value == 100 ? KodaColors.dim : KodaColors.amber,
              ),
              child: Slider(
                value: value.toDouble(),
                min: 80,
                max: 120,
                onChanged: (v) => onChanged(v.round()),
              ),
            ),
          ],
        ),
      );
}

class _SmallBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _SmallBtn(this.label, this.onTap);

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 24, height: 24,
          decoration: BoxDecoration(
            color: KodaColors.panel2,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: KodaColors.border2),
          ),
          child: Center(
            child: Text(label, style: bodyStyle(size: 14, color: KodaColors.text)),
          ),
        ),
      );
}

class _KodaButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _KodaButton({required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
          decoration: BoxDecoration(
            color: color.withOpacity(0.08),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: color.withOpacity(0.4)),
          ),
          child: Center(
            child: Text(label, style: monoStyle(size: 10, color: color, spacing: 1)),
          ),
        ),
      );
}

// ─── BT Scanner Bottom Sheet ──────────────────────────────────────────────────
class BtScannerSheet extends ConsumerWidget {
  const BtScannerSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ble = ref.watch(bleConnectionProvider);
    final notifier = ref.read(bleConnectionProvider.notifier);

    return Container(
      decoration: const BoxDecoration(
        color: KodaColors.panel,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle
          Center(
            child: Container(
              width: 36, height: 4,
              decoration: BoxDecoration(
                color: KodaColors.border2,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('BLUETOOTH DEVICES', style: condensedStyle(size: 20, spacing: 1)),
          const SizedBox(height: 4),
          Text('Select your ESP32 to connect',
              style: monoStyle(size: 10, color: KodaColors.sub)),
          const SizedBox(height: 14),

          // Scan button
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: ble.isScanning ? null : notifier.scan,
              icon: ble.isScanning
                  ? const SizedBox(
                      width: 14, height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2, color: KodaColors.blue))
                  : const Icon(Icons.refresh, size: 16),
              label: Text(ble.isScanning ? 'SCANNING…' : '⟳  SCAN FOR DEVICES',
                  style: condensedStyle(
                      size: 14,
                      color: ble.isScanning ? KodaColors.dim : KodaColors.blue,
                      spacing: 2)),
              style: OutlinedButton.styleFrom(
                side: BorderSide(
                    color: ble.isScanning ? KodaColors.dim : KodaColors.blue),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Device list
          if (ble.scannedDevices.isEmpty && !ble.isScanning)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text('No devices found. Tap scan to search.',
                    style: monoStyle(size: 11, color: KodaColors.dim)),
              ),
            ),

          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: ble.scannedDevices.length,
              itemBuilder: (context, index) {
                final device = ble.scannedDevices[index];
                return _DeviceRow(
                  device: device,
                  onTap: () async {
                    Navigator.of(context).pop();
                    await notifier.connect(device);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  final KodaBtDevice device;
  final VoidCallback onTap;

  const _DeviceRow({required this.device, required this.onTap});

  Color get _signalColor {
    if (device.rssi > -55) return KodaColors.green;
    if (device.rssi > -70) return KodaColors.amber;
    return KodaColors.red;
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: KodaColors.panel2,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: KodaColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.bluetooth, color: KodaColors.blue, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(device.name,
                            style: monoStyle(
                                size: 13, color: KodaColors.white,
                                weight: FontWeight.bold)),
                        Text('${device.type} · ${device.rssi} dBm · ${device.signalLabel}',
                            style: monoStyle(size: 9, color: KodaColors.dim)),
                      ],
                    ),
                  ),
                  StatusBadge(label: 'CONNECT', color: KodaColors.blue),
                ],
              ),
              const SizedBox(height: 8),
              // Signal bar
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: device.signalStrength,
                  backgroundColor: KodaColors.border,
                  valueColor: AlwaysStoppedAnimation(_signalColor),
                  minHeight: 3,
                ),
              ),
            ],
          ),
        ),
      );
}
