import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../features/updates/app_updater.dart';
import 'theme.dart';

/// A short line describing where an update is.
String _updateLine(AppUpdateState s) {
  final r = s.release;
  return switch (s.phase) {
    UpdatePhase.available => '${r?.sizeLabel} · tap to update',
    UpdatePhase.downloading => 'Downloading · ${(s.progress * 100).round()}%',
    UpdatePhase.ready => 'Downloaded · tap to install',
    UpdatePhase.needsPermission => 'Needs your OK to install',
    UpdatePhase.installing =>
      s.confirming ? 'Confirm on the screen Android shows' : 'Installing…',
    UpdatePhase.failed =>
      s.reinstall
          ? 'Reinstall once from GitHub'
          : "Didn't finish · tap to try again",
    _ => '',
  };
}

/// A tappable card shown at the top of the home screen when there's a newer
/// build. Tapping opens the update sheet. Renders nothing when idle / current.
class UpdateCard extends StatelessWidget {
  const UpdateCard({super.key, required this.updater});
  final AppUpdater updater;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: updater,
      builder: (context, _) {
        final s = updater.state;
        final r = s.release;
        final busy =
            s.phase == UpdatePhase.downloading ||
            (s.phase == UpdatePhase.installing && !s.confirming);
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: SizeTransition(sizeFactor: anim, child: child),
          ),
          child: r == null
              ? const SizedBox.shrink()
              : Material(
                  elevation: 6,
                  color: context.colors.secondaryContainer,
                  shadowColor: Colors.black.withValues(alpha: .4),
                  borderRadius: BorderRadius.circular(18),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: () => showUpdateSheet(context, updater),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                      child: Row(
                        children: [
                          SizedBox.square(
                            dimension: 34,
                            child: switch (s.phase) {
                              UpdatePhase.downloading =>
                                CircularProgressIndicator(
                                  value: s.progress,
                                  strokeWidth: 3,
                                ),
                              _ when busy => const CircularProgressIndicator(
                                strokeWidth: 3,
                              ),
                              UpdatePhase.failed => Icon(
                                Icons.error_outline,
                                color: context.colors.onSecondaryContainer,
                              ),
                              _ => Icon(
                                Icons.system_update,
                                color: context.colors.onSecondaryContainer,
                              ),
                            },
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Update ${r.version} available',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: context.texts.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: context.colors.onSecondaryContainer,
                                  ),
                                ),
                                Text(
                                  _updateLine(s),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: context.texts.bodySmall?.copyWith(
                                    color: context.colors.onSecondaryContainer
                                        .withValues(alpha: .8),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            Icons.chevron_right,
                            color: context.colors.onSecondaryContainer,
                          ),
                          const SizedBox(height: 14),
                        ],
                      ),
                    ),
                  ),
                ),
        );
      },
    );
  }
}

/// The update, what's new, and one button that downloads then installs —
/// a bottom sheet whose action animates between states.
Future<void> showUpdateSheet(BuildContext context, AppUpdater updater) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _UpdateSheet(updater: updater),
  );
}

class _UpdateSheet extends StatelessWidget {
  const _UpdateSheet({required this.updater});
  final AppUpdater updater;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: updater,
      builder: (context, _) {
        final s = updater.state;
        final r = s.release;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            4,
            20,
            20 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (r == null)
                Text(
                  s.phase == UpdatePhase.failed
                      ? (s.message ?? 'Update failed')
                      : "You're on the latest version.",
                  style: context.texts.bodyLarge,
                )
              else ...[
                Text(
                  'OpenHD350B ${r.version}',
                  style: context.texts.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  r.sizeLabel,
                  style: context.texts.bodyMedium?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
                if (r.notes.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  Text(
                    "WHAT'S NEW",
                    style: context.texts.labelSmall?.copyWith(
                      letterSpacing: 1.2,
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _Notes(r.notes),
                ],
                const SizedBox(height: 22),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: KeyedSubtree(
                    key: ValueKey('${s.phase}${s.confirming}'),
                    child: _action(context, s),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _action(BuildContext context, AppUpdateState s) {
    final r = s.release!;
    switch (s.phase) {
      case UpdatePhase.available:
        return FilledButton.icon(
          onPressed: () {
            HapticFeedback.selectionClick();
            updater.download();
          },
          icon: const Icon(Icons.download),
          label: Text('Update · ${r.sizeLabel}'),
        );
      case UpdatePhase.downloading:
        return _Progress(
          value: s.progress,
          label:
              '${(s.received / (1024 * 1024)).toStringAsFixed(1)} MB of ${r.sizeLabel}',
        );
      case UpdatePhase.ready:
        return FilledButton.icon(
          onPressed: () {
            HapticFeedback.selectionClick();
            updater.install();
          },
          icon: const Icon(Icons.install_mobile),
          label: const Text('Install'),
        );
      case UpdatePhase.needsPermission:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Android asks once so the app can install its own updates. Turn '
              'on "Allow from this source", then come back.',
              style: context.texts.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: updater.allowInstalls,
              child: const Text('Allow'),
            ),
          ],
        );
      case UpdatePhase.installing:
        return _Progress(
          label: s.confirming
              ? 'Confirm on the screen Android shows'
              : 'Installing… this stays open',
        );
      case UpdatePhase.failed:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              s.message ?? 'Update failed',
              style: context.texts.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            if (s.reinstall)
              FilledButton(
                onPressed: () => launchUrl(
                  Uri.parse(releasesPageUrl),
                  mode: LaunchMode.externalApplication,
                ),
                child: const Text('Open GitHub'),
              )
            else
              FilledButton(
                onPressed: () {
                  updater.clearFailure();
                  updater.download();
                },
                child: const Text('Try again'),
              ),
          ],
        );
      default:
        return const SizedBox.shrink();
    }
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.label, this.value});
  final double? value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          SizedBox.square(
            dimension: 28,
            child: CircularProgressIndicator(value: value, strokeWidth: 3),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(label, style: context.texts.bodyMedium),
                if (value != null) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: value),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Notes extends StatelessWidget {
  const _Notes(this.notes);
  final List<String> notes;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final n in notes)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 7, right: 10),
                      child: Container(
                        width: 4,
                        height: 4,
                        decoration: BoxDecoration(
                          color: context.colors.primary,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    Expanded(child: Text(n, style: context.texts.bodyMedium)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
