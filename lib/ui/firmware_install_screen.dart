import 'dart:async';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';

import '../features/device/connection_controller.dart';
import '../features/firmware/gaia_upgrade_transport.dart';
import '../features/firmware/upgrade_machine.dart';
import 'components.dart';
import 'theme.dart';

/// The firmware-flash flow: pre-flight checks, a dry run, then the real
/// install over GAIA VM-Upgrade. Driven by [UpgradeMachine]; the device rolls
/// back automatically if anything goes wrong.
class FirmwareInstallScreen extends StatefulWidget {
  const FirmwareInstallScreen({
    super.key,
    required this.conn,
    required this.imagePath,
    required this.version,
  });

  final ConnectionController conn;
  final String imagePath;
  final String version;

  @override
  State<FirmwareInstallScreen> createState() => _FirmwareInstallScreenState();
}

enum _Stage { preflight, running, done, failed }

class _FirmwareInstallScreenState extends State<FirmwareInstallScreen> {
  _Stage _stage = _Stage.preflight;
  UpgradeProgress? _progress;
  String? _error;
  bool _dryRun = false;

  Future<int?> _phoneBattery() async {
    try {
      return await Battery().batteryLevel;
    } catch (_) {
      return null;
    }
  }

  Future<void> _start({required bool dryRun}) async {
    setState(() {
      _stage = _Stage.running;
      _dryRun = dryRun;
      _error = null;
    });
    var ok = false;
    // A guarded zone so a stray async error from a best-effort GAIA ack can
    // never surface as an unhandled exception during the long flash.
    final done = Completer<void>();
    runZonedGuarded(() async {
      try {
        final image = await File(widget.imagePath).readAsBytes();
        await widget.conn.runExclusive((device) async {
          final transport = GaiaUpgradeTransport(device);
          final machine = UpgradeMachine(
            transport: transport,
            image: image,
            phoneBatteryPercent: _phoneBattery,
            dryRun: dryRun,
          );
          final sub = machine.progress.listen((p) {
            if (mounted) setState(() => _progress = p);
          });
          try {
            ok = await machine.run();
          } finally {
            await sub.cancel();
            await machine.dispose();
            await transport.dispose();
          }
        });
      } catch (e) {
        _error = '$e';
      } finally {
        if (!done.isCompleted) done.complete();
      }
    }, (e, _) => debugPrint('[upgrade] stray async error ignored: $e'));
    await done.future;
    if (!mounted) return;
    setState(
      () =>
          _stage = (ok || (dryRun && _progress?.phase == UpgradePhase.aborted))
          ? _Stage.done
          : _Stage.failed,
    );
  }

  @override
  Widget build(BuildContext context) {
    final busy = _stage == _Stage.running;
    return PopScope(
      canPop: !busy, // never leave mid-flash
      child: Scaffold(
        appBar: AppBar(
          title: Text(busy ? 'Installing…' : 'Install firmware'),
          automaticallyImplyLeading: !busy,
        ),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: switch (_stage) {
            _Stage.preflight => _preflight(context),
            _Stage.running => _runningView(context),
            _Stage.done => _result(context, true),
            _Stage.failed => _result(context, false),
          },
        ),
      ),
    );
  }

  Widget _preflight(BuildContext context) {
    return ListView(
      children: [
        SectionCard(
          title: 'Before you flash',
          icon: Icons.warning_amber,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Installing firmware v${widget.version}.',
                style: context.texts.titleMedium,
              ),
              const SizedBox(height: 12),
              for (final line in const [
                'Keep the headphones on and nearby for the whole process (~20 min over BLE).',
                'Keep both the phone and headphones charged (needs ≥ 20%).',
                'Don\'t turn Bluetooth off, close the app, or lock-and-walk-away.',
                'The chip verifies the signed image and rolls back if anything fails — it is not left bricked.',
              ])
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('•  '),
                      Expanded(
                        child: Text(line, style: context.texts.bodyMedium),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.tonalIcon(
          onPressed: () => _start(dryRun: true),
          icon: const Icon(Icons.science_outlined),
          label: const Text('Dry run (handshake only, writes nothing)'),
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: context.colors.error,
            foregroundColor: context.colors.onError,
          ),
          onPressed: () => _confirmFlash(context),
          icon: const Icon(Icons.system_update),
          label: Text('Flash v${widget.version} for real'),
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Future<void> _confirmFlash(BuildContext context) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Flash firmware?'),
        content: Text(
          'This writes firmware v${widget.version} to your headphones over '
          'the next ~20 minutes. Do not disconnect or close the app. Proceed?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.colors.error,
              foregroundColor: context.colors.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Flash'),
          ),
        ],
      ),
    );
    if (go ?? false) _start(dryRun: false);
  }

  Widget _runningView(BuildContext context) {
    final p = _progress;
    final pct = p?.phase == UpgradePhase.transferring ? p!.percent : null;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 72,
            height: 72,
            child: CircularProgressIndicator(value: pct, strokeWidth: 5),
          ),
          const SizedBox(height: 24),
          Text(
            _phaseLabel(p?.phase),
            style: context.texts.titleMedium,
            textAlign: TextAlign.center,
          ),
          if (pct != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '${(pct * 100).toStringAsFixed(1)}%',
                style: context.texts.bodyMedium,
              ),
            ),
          if (p?.message != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                p!.message!,
                style: context.texts.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: 24),
          Text(
            _dryRun
                ? 'Dry run — no firmware is being written.'
                : 'Keep the headphones on and nearby. Do not disconnect.',
            textAlign: TextAlign.center,
            style: context.texts.bodySmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  String _phaseLabel(UpgradePhase? phase) => switch (phase) {
    UpgradePhase.preconditions => 'Checking battery…',
    UpgradePhase.connecting => 'Connecting…',
    UpgradePhase.syncing => 'Syncing…',
    UpgradePhase.starting => 'Starting…',
    UpgradePhase.transferring => 'Transferring firmware…',
    UpgradePhase.validating => 'Validating…',
    UpgradePhase.rebooting => 'Rebooting headphones…',
    UpgradePhase.committing => 'Committing…',
    UpgradePhase.done => 'Done',
    UpgradePhase.aborted => 'Stopping…',
    _ => 'Working…',
  };

  Widget _result(BuildContext context, bool success) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            success ? Icons.check_circle : Icons.error,
            size: 72,
            color: success ? context.colors.primary : context.colors.error,
          ),
          const SizedBox(height: 16),
          Text(
            success
                ? (_dryRun
                      ? 'Dry run completed — the handshake works.'
                      : 'Firmware installed.')
                : 'Install did not complete.',
            style: context.texts.titleMedium,
            textAlign: TextAlign.center,
          ),
          if (_error != null || _progress?.message != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error ?? _progress!.message!,
                textAlign: TextAlign.center,
                style: context.texts.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}
