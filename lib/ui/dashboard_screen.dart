import 'package:flutter/material.dart';

import '../features/device/device_session.dart';
import 'components.dart';
import 'theme.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key, required this.session});
  final DeviceSession session;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: session,
      builder: (context, _) {
        final s = session.state;
        return RefreshIndicator(
          onRefresh: session.refreshAll,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              _HeroCard(state: s),
              const SizedBox(height: 16),
              SectionCard(
                title: 'Audio mode',
                icon: Icons.graphic_eq,
                child: PillSelector<AudioMode>(
                  options: AudioMode.values,
                  selected: s.audioMode,
                  labelOf: (m) =>
                      m == AudioMode.userEq ? 'Equalizer' : 'Podcast / speech',
                  onSelected: session.setAudioMode,
                ),
              ),
              const SizedBox(height: 16),
              SectionCard(
                title: 'Sidetone',
                icon: Icons.record_voice_over,
                child: PillSelector<SidetoneState>(
                  options: SidetoneState.values,
                  selected: s.sidetone,
                  labelOf: (v) => v.name[0].toUpperCase() + v.name.substring(1),
                  onSelected: session.setSidetone,
                ),
              ),
              const SizedBox(height: 16),
              _InfoCard(state: s),
            ],
          ),
        );
      },
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.state});
  final DeviceState state;

  @override
  Widget build(BuildContext context) {
    final battery = state.batteryPercent;
    return Card(
      color: context.colors.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            SizedBox(
              height: 150,
              child: Image.asset(
                'assets/images/hd350bt.png',
                fit: BoxFit.contain,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              state.model,
              style: context.texts.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: context.colors.onPrimaryContainer,
              ),
            ),
            Text(
              state.connected ? 'Connected' : 'Disconnected',
              style: context.texts.bodyMedium?.copyWith(
                color: context.colors.onPrimaryContainer.withValues(alpha: .8),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                StatTile(
                  icon: _batteryIcon(battery, state.charging),
                  value: battery == null ? '—' : '$battery%',
                  label: _chargeLabel(state.charging),
                ),
                StatTile(
                  icon: Icons.memory,
                  value: state.firmware ?? '—',
                  label: 'Firmware',
                ),
                StatTile(
                  icon: Icons.wifi,
                  value: state.rssi == null ? '—' : '${state.rssi} dBm',
                  label: 'Signal',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData _batteryIcon(int? pct, ChargingStatus c) {
    if (c == ChargingStatus.charging) return Icons.battery_charging_full;
    if (pct == null) return Icons.battery_unknown;
    if (pct >= 90) return Icons.battery_full;
    if (pct >= 60) return Icons.battery_5_bar;
    if (pct >= 30) return Icons.battery_3_bar;
    return Icons.battery_alert;
  }

  String _chargeLabel(ChargingStatus c) => switch (c) {
    ChargingStatus.charging => 'Charging',
    ChargingStatus.complete => 'Charged',
    ChargingStatus.disconnected => 'Battery',
    ChargingStatus.unknown => 'Battery',
  };
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.state});
  final DeviceState state;

  @override
  Widget build(BuildContext context) {
    final rows = {
      'Model': state.model,
      'Firmware': state.firmware ?? 'reading…',
      'Battery': state.batteryPercent == null
          ? '—'
          : '${state.batteryPercent}%',
      'Custom EQ': state.customEqOn == null
          ? '—'
          : (state.customEqOn! ? 'On' : 'Off'),
    };
    return SectionCard(
      title: 'Device info',
      icon: Icons.info_outline,
      child: Column(
        children: [
          for (final e in rows.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    e.key,
                    style: context.texts.bodyMedium?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                  Text(e.value, style: context.texts.bodyMedium),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
