import 'package:flutter/material.dart';

import '../features/updates/app_updater.dart';
import 'theme.dart';

/// A thin banner shown above the app when an update is available, downloading,
/// ready to install, or failed. Renders nothing when idle / up to date.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key, required this.updater});
  final AppUpdater updater;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: updater,
      builder: (context, _) {
        final s = updater.state;
        final content = switch (s.phase) {
          UpdatePhase.available => _row(
            context,
            icon: Icons.system_update,
            text: 'App update ${s.release?.version} available',
            actions: [_btn('Download', updater.download)],
          ),
          UpdatePhase.downloading => _row(
            context,
            icon: Icons.downloading,
            text:
                'Downloading ${s.release?.version}… '
                '${(s.progress * 100).round()}%',
            progress: s.progress,
          ),
          UpdatePhase.ready => _row(
            context,
            icon: Icons.task_alt,
            text: 'Update ${s.release?.version} ready',
            actions: [_btn('Install', updater.install)],
          ),
          UpdatePhase.needsPermission => _row(
            context,
            icon: Icons.lock_open,
            text: 'Allow installing apps to finish the update',
            actions: [_btn('Allow', updater.allowInstalls)],
          ),
          UpdatePhase.installing => _row(
            context,
            icon: Icons.install_mobile,
            text: s.confirming
                ? 'Confirm the update on screen…'
                : 'Installing…',
          ),
          UpdatePhase.failed => _row(
            context,
            icon: Icons.error_outline,
            text: s.message ?? 'Update failed',
            actions: [_btn('Dismiss', updater.clearFailure)],
          ),
          _ => null,
        };
        if (content == null) return const SizedBox.shrink();
        return Material(
          color: context.colors.secondaryContainer,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              child: content,
            ),
          ),
        );
      },
    );
  }

  Widget _row(
    BuildContext context, {
    required IconData icon,
    required String text,
    List<Widget> actions = const [],
    double? progress,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(icon, size: 20, color: context.colors.onSecondaryContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: context.texts.bodyMedium?.copyWith(
                  color: context.colors.onSecondaryContainer,
                ),
              ),
            ),
            ...actions,
          ],
        ),
        if (progress != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: LinearProgressIndicator(value: progress),
          ),
      ],
    );
  }

  Widget _btn(String label, VoidCallback onTap) =>
      TextButton(onPressed: onTap, child: Text(label));
}
