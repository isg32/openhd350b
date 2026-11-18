import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../features/device/connection_controller.dart';
import '../features/device/device_session.dart';
import '../features/firmware/firmware_models.dart';
import '../features/firmware/firmware_service.dart';
import 'components.dart';
import 'theme.dart';

class FirmwareScreen extends StatefulWidget {
  const FirmwareScreen({
    super.key,
    required this.firmware,
    required this.session,
    this.conn,
  });
  final FirmwareService firmware;
  final DeviceSession session;
  final ConnectionController? conn;

  @override
  State<FirmwareScreen> createState() => _FirmwareScreenState();
}

class _FirmwareScreenState extends State<FirmwareScreen> {
  String? _downloadingVersion;

  @override
  void initState() {
    super.initState();
    widget.firmware.loadSaved();
    widget.firmware.listVersions();
  }

  String _size(int bytes) => bytes >= 1 << 20
      ? '${(bytes / (1 << 20)).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).toStringAsFixed(0)} KB';

  Future<void> _check() async {
    final current = widget.session.state.firmware ?? '0.0.0';
    await widget.firmware.checkForUpdate(current);
  }

  Future<void> _download(String version) async {
    setState(() => _downloadingVersion = version);
    await widget.firmware.downloadVersion(version);
    if (mounted) setState(() => _downloadingVersion = null);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([widget.firmware, widget.session]),
      builder: (context, _) {
        final fw = widget.firmware;
        final current = widget.session.state.firmware;
        final savedVersions = {for (final s in fw.saved) s.version};
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            SectionCard(
              title: 'Firmware',
              icon: Icons.memory,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Installed', style: context.texts.bodyMedium),
                      Text(
                        current ?? '—',
                        style: context.texts.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      onPressed: fw.checking ? null : _check,
                      icon: fw.checking
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.cloud_sync),
                      label: Text(
                        fw.checking ? 'Checking…' : 'Check for updates',
                      ),
                    ),
                  ),
                  if (fw.latest != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Update available: ${fw.latest!.version}',
                        style: context.texts.bodyMedium?.copyWith(
                          color: context.colors.primary,
                        ),
                      ),
                    ),
                  if (fw.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        fw.error!,
                        style: context.texts.bodySmall?.copyWith(
                          color: context.colors.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (fw.progress != null) _ProgressCard(fw: fw, sizeOf: _size),
            if (fw.available.isNotEmpty)
              SectionCard(
                title: 'All firmware versions',
                icon: Icons.history,
                child: Column(
                  children: [
                    for (final v in fw.available)
                      _VersionTile(
                        version: v,
                        isInstalled: v == current,
                        isLatest: v == fw.available.first,
                        isSaved: savedVersions.contains(v),
                        isDownloading: _downloadingVersion == v,
                        busy:
                            _downloadingVersion != null || fw.progress != null,
                        onDownload: () => _download(v),
                      ),
                  ],
                ),
              ),
            if (fw.saved.isNotEmpty) ...[
              const SizedBox(height: 16),
              SectionCard(
                title: 'Saved on this device',
                icon: Icons.save_alt,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final s in fw.saved)
                      _SavedTile(
                        fw: s,
                        sizeOf: _size,
                        onInstall: s.md5Verified
                            ? () => _explainInstallUnavailable(context)
                            : null,
                        onShare: () => SharePlus.instance.share(
                          ShareParams(
                            files: [XFile(s.imagePath)],
                            text: 'HD 350BT firmware v${s.version}',
                          ),
                        ),
                        onDelete: () => fw.deleteSaved(s),
                      ),
                    if (fw.storageDirPath != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'Stored in: ${fw.storageDirPath}',
                          style: context.texts.bodySmall?.copyWith(
                            color: context.colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            const _InstallNote(),
          ],
        );
      },
    );
  }
}

void _explainInstallUnavailable(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.bluetooth_disabled),
      title: const Text('Flashing not available over Bluetooth LE'),
      content: const Text(
        'The HD 350BT only accepts a firmware update over a Classic '
        'Bluetooth (RFCOMM) link, which this app does not support yet.\n\n'
        'Over Bluetooth LE the device caps packets far below what its '
        'firmware updater needs and rejects the transfer, so flashing cannot '
        'complete. Downloading, decrypting and verifying firmware already '
        'works for study and backup, and nothing here can harm the '
        'headphones.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

class _VersionTile extends StatelessWidget {
  const _VersionTile({
    required this.version,
    required this.isInstalled,
    required this.isLatest,
    required this.isSaved,
    required this.isDownloading,
    required this.busy,
    required this.onDownload,
  });
  final String version;
  final bool isInstalled, isLatest, isSaved, isDownloading, busy;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Row(
        children: [
          Text('v$version'),
          const SizedBox(width: 8),
          if (isLatest) _chip(context, 'Latest', context.colors.primary),
          if (isInstalled) _chip(context, 'Installed', context.colors.tertiary),
        ],
      ),
      subtitle: isSaved ? const Text('Saved locally') : null,
      trailing: isDownloading
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : IconButton(
              tooltip: isSaved ? 'Re-download' : 'Download',
              icon: Icon(isSaved ? Icons.download_done : Icons.download),
              onPressed: busy ? null : onDownload,
            ),
    );
  }

  Widget _chip(BuildContext context, String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .18),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(text, style: context.texts.labelSmall?.copyWith(color: color)),
  );
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.fw, required this.sizeOf});
  final FirmwareService fw;
  final String Function(int) sizeOf;

  @override
  Widget build(BuildContext context) {
    final p = fw.progress!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: SectionCard(
        title: 'Downloading',
        icon: Icons.downloading,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(value: p.fraction),
            const SizedBox(height: 8),
            Text(
              p.total > 0
                  ? '${p.phase} · ${sizeOf(p.received)} / ${sizeOf(p.total)}'
                  : p.phase,
              style: context.texts.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _SavedTile extends StatelessWidget {
  const _SavedTile({
    required this.fw,
    required this.sizeOf,
    required this.onShare,
    required this.onDelete,
    this.onInstall,
  });
  final SavedFirmware fw;
  final String Function(int) sizeOf;
  final VoidCallback onShare;
  final VoidCallback onDelete;
  final VoidCallback? onInstall;

  @override
  Widget build(BuildContext context) {
    final d = fw.downloadedAt;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        fw.md5Verified ? Icons.verified_user : Icons.insert_drive_file,
        color: fw.md5Verified ? context.colors.primary : null,
      ),
      title: Text('v${fw.version}'),
      subtitle: Text(
        '${sizeOf(fw.sizeBytes)} · '
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}'
        '${fw.md5Verified ? ' · md5 ✓' : ''}',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onInstall != null)
            IconButton(
              tooltip: 'Install (why unavailable)',
              icon: const Icon(Icons.system_update),
              color: context.colors.onSurfaceVariant,
              onPressed: onInstall,
            ),
          IconButton(
            tooltip: 'Export / share',
            icon: const Icon(Icons.ios_share),
            onPressed: onShare,
          ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

class _InstallNote extends StatelessWidget {
  const _InstallNote();
  @override
  Widget build(BuildContext context) {
    return Card(
      color: context.colors.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.info_outline, color: context.colors.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Any version can be downloaded, decrypted and md5-verified for '
                'study or backup. Installing (flashing) is not available: the '
                'HD 350BT only accepts firmware over a Classic Bluetooth '
                '(RFCOMM) connection, which this app does not support yet.',
                style: context.texts.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
