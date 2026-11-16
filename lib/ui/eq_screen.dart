import 'dart:async';

import 'package:flutter/material.dart';

import '../features/device/device_session.dart';
import '../features/equalizer/eq_engine.dart';
import 'components.dart';
import 'theme.dart';

class EqScreen extends StatefulWidget {
  const EqScreen({super.key, required this.session});
  final DeviceSession session;

  @override
  State<EqScreen> createState() => _EqScreenState();
}

class _EqScreenState extends State<EqScreen> {
  late List<double> _bands;
  late bool _bassBoost;
  Timer? _debounce;

  DeviceSession get session => widget.session;

  @override
  void initState() {
    super.initState();
    _bands = [...session.state.eqBands];
    _bassBoost = session.state.bassBoost;
    session.addListener(_syncFromDevice);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    session.removeListener(_syncFromDevice);
    super.dispose();
  }

  /// Pull values the device reported (e.g. on first refresh) into the sliders,
  /// unless the user is mid-drag.
  void _syncFromDevice() {
    if (_debounce?.isActive ?? false) return;
    final s = session.state;
    if (!_listEq(s.eqBands, _bands) || s.bassBoost != _bassBoost) {
      setState(() {
        _bands = [...s.eqBands];
        _bassBoost = s.bassBoost;
      });
    }
  }

  bool _listEq(List<double> a, List<double> b) =>
      a.length == b.length &&
      List.generate(
        a.length,
        (i) => (a[i] - b[i]).abs() < 0.05,
      ).every((x) => x);

  /// Debounced apply — the app waits ~300 ms before pushing EQ changes.
  void _scheduleApply() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      session.applyEq(_bands, bassBoost: _bassBoost);
    });
  }

  void _reset() {
    setState(() {
      _bands = [0, 0, 0];
      _bassBoost = false;
    });
    session.applyEq(_bands, bassBoost: false);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: session,
      builder: (context, _) {
        final on = session.state.customEqOn ?? true;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            SectionCard(
              title: 'Custom equalizer',
              icon: Icons.tune,
              trailing: Switch(value: on, onChanged: session.setCustomEqOn),
              child: Column(
                children: [
                  _EqCurve(bands: _bands, enabled: on),
                  const SizedBox(height: 8),
                  AnimatedOpacity(
                    opacity: on ? 1 : 0.4,
                    duration: const Duration(milliseconds: 200),
                    child: IgnorePointer(
                      ignoring: !on,
                      child: Column(
                        children: [
                          for (var i = 0; i < 3; i++)
                            LabeledSlider(
                              label: eqBandLabels[i],
                              subtitle: '${eqBandFrequencies[i]} Hz',
                              value: _bands[i],
                              min: session.eq.params.minGain,
                              max: session.eq.params.maxGain,
                              divisions: 24,
                              valueLabel:
                                  '${_bands[i] > 0 ? '+' : ''}'
                                  '${_bands[i].toStringAsFixed(1)} dB',
                              onChanged: (v) => setState(() {
                                _bands[i] = v;
                                _scheduleApply();
                              }),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SectionCard(
              title: 'Bass boost',
              icon: Icons.speaker,
              trailing: Switch(
                value: _bassBoost,
                onChanged: on
                    ? (v) {
                        setState(() => _bassBoost = v);
                        _scheduleApply();
                      }
                    : null,
              ),
              child: Text(
                'Adds a low-shelf lift centred near 150 Hz, matching the '
                'official app.',
                style: context.texts.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: TextButton.icon(
                onPressed: on ? _reset : null,
                icon: const Icon(Icons.restart_alt),
                label: const Text('Reset to neutral'),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A simple filled curve preview of the three band gains.
class _EqCurve extends StatelessWidget {
  const _EqCurve({required this.bands, required this.enabled});
  final List<double> bands;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 90,
      width: double.infinity,
      child: CustomPaint(
        painter: _CurvePainter(
          bands: bands,
          color: enabled
              ? context.colors.primary
              : context.colors.onSurfaceVariant,
          grid: context.colors.outlineVariant,
        ),
      ),
    );
  }
}

class _CurvePainter extends CustomPainter {
  _CurvePainter({required this.bands, required this.color, required this.grid});
  final List<double> bands;
  final Color color;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, mid), Offset(size.width, mid), gridPaint);

    // Map 3 bands (-6..6 dB) to y, spread across width at 1/6, 1/2, 5/6.
    double y(double db) => mid - (db / 6) * (size.height / 2 - 6);
    final xs = [size.width / 6, size.width / 2, size.width * 5 / 6];
    final pts = [
      Offset(0, y(bands[0])),
      for (var i = 0; i < 3; i++) Offset(xs[i], y(bands[i])),
      Offset(size.width, y(bands[2])),
    ];

    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length; i++) {
      final prev = pts[i - 1], cur = pts[i];
      final cx = (prev.dx + cur.dx) / 2;
      path.cubicTo(cx, prev.dy, cx, cur.dy, cur.dx, cur.dy);
    }

    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: .35), color.withValues(alpha: 0)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_CurvePainter old) =>
      old.bands != bands || old.color != color;
}
