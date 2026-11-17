import 'package:flutter/foundation.dart';

/// A firmware package advertised by the Sennheiser cloud.
@immutable
class FirmwarePackage {
  const FirmwarePackage({
    required this.version,
    required this.url,
    required this.sizeBytes,
    required this.type,
    required this.identifier,
    this.releaseNotes,
    this.timestamp,
  });

  final String version;
  final String url;
  final int sizeBytes;
  final String type; // e.g. FW_FULL
  final String identifier; // e.g. 0x0000
  final String? releaseNotes;
  final DateTime? timestamp;

  String get filename => url.split('/').last;

  factory FirmwarePackage.fromJson(
    Map<String, dynamic> pkg,
    String? releaseNotes,
  ) {
    return FirmwarePackage(
      version: pkg['version'] as String? ?? '?',
      url: pkg['url'] as String? ?? '',
      sizeBytes: int.tryParse('${pkg['size']}') ?? 0,
      type: pkg['type'] as String? ?? '',
      identifier: pkg['identifier'] as String? ?? '',
      releaseNotes: releaseNotes,
      timestamp: pkg['ts'] is int
          ? DateTime.fromMillisecondsSinceEpoch(pkg['ts'] as int)
          : null,
    );
  }
}

/// A firmware image saved on this device.
@immutable
class SavedFirmware {
  const SavedFirmware({
    required this.version,
    required this.imagePath,
    required this.sizeBytes,
    required this.downloadedAt,
    required this.md5,
    this.md5Verified = false,
    this.releaseNotes,
  });

  final String version;
  final String imagePath;
  final int sizeBytes;
  final DateTime downloadedAt;
  final String md5;
  final bool md5Verified;
  final String? releaseNotes;

  Map<String, dynamic> toJson() => {
    'version': version,
    'imagePath': imagePath,
    'sizeBytes': sizeBytes,
    'downloadedAt': downloadedAt.toIso8601String(),
    'md5': md5,
    'md5Verified': md5Verified,
    'releaseNotes': releaseNotes,
  };

  factory SavedFirmware.fromJson(Map<String, dynamic> j) => SavedFirmware(
    version: j['version'] as String,
    imagePath: j['imagePath'] as String,
    sizeBytes: j['sizeBytes'] as int,
    downloadedAt: DateTime.parse(j['downloadedAt'] as String),
    md5: j['md5'] as String? ?? '',
    md5Verified: j['md5Verified'] as bool? ?? false,
    releaseNotes: j['releaseNotes'] as String?,
  );
}

/// Progress of a download+decrypt operation.
@immutable
class FirmwareProgress {
  const FirmwareProgress(this.phase, {this.received = 0, this.total = 0});
  final String phase; // downloading / decrypting / unzipping / verifying / done
  final int received;
  final int total;

  double? get fraction => total > 0 ? received / total : null;
}
