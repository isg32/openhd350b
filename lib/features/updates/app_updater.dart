import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'updater_channel.dart';

/// Where each release's `update.json` lives: the latest GitHub release of the
/// repo. Overridable with --dart-define=OPENHD_UPDATE_URL for a test server.
const updateManifestUrl = String.fromEnvironment(
  'OPENHD_UPDATE_URL',
  defaultValue: 'https://github.com/isg32/openhd350b/releases/latest/download/update.json',
);

/// The releases page, for a phone that must reinstall once by hand.
const releasesPageUrl = String.fromEnvironment(
  'OPENHD_RELEASES_URL',
  defaultValue: 'https://github.com/isg32/openhd350b/releases/latest',
);

/// A newer build, for this phone's ABI.
@immutable
class UpdateRelease {
  const UpdateRelease({
    required this.version,
    required this.notes,
    required this.url,
    required this.sha256,
    required this.size,
    required this.versionCode,
  });

  final String version;
  final List<String> notes;
  final String url;
  final String sha256;
  final int size;
  final int versionCode;

  String get sizeLabel {
    final mb = size / (1024 * 1024);
    return mb >= 10 ? '${mb.round()} MB' : '${mb.toStringAsFixed(1)} MB';
  }

  /// The release in an `update.json` for [abi], or null when it has no APK for
  /// it (or isn't readable).
  static UpdateRelease? fromManifest(Map<String, Object?> j, String? abi) {
    final apks = j['apks'];
    if (apks is! Map) return null;
    final apk = apks[abi ?? 'arm64-v8a'] ?? apks['arm64-v8a'];
    if (apk is! Map) return null;
    final url = apk['url'], sha = apk['sha256'];
    final size = apk['size'], code = apk['versionCode'];
    if (url is! String || sha is! String || size is! num || code is! num) {
      return null;
    }
    return UpdateRelease(
      version: (j['version'] as String?) ?? '',
      notes: [
        for (final n in (j['notes'] as List?) ?? const [])
          if (n is String && n.trim().isNotEmpty) n.trim(),
      ],
      url: url,
      sha256: sha.toLowerCase(),
      size: size.toInt(),
      versionCode: code.toInt(),
    );
  }
}

enum UpdatePhase {
  unsupported,
  idle,
  checking,
  upToDate,
  available,
  downloading,
  ready,
  needsPermission,
  installing,
  failed,
}

@immutable
class AppUpdateState {
  const AppUpdateState(
    this.phase, {
    this.release,
    this.received = 0,
    this.apkPath,
    this.message,
    this.confirming = false,
    this.reinstall = false,
  });

  final UpdatePhase phase;
  final UpdateRelease? release;
  final int received;
  final String? apkPath;
  final String? message;
  final bool confirming;

  /// This build can't update in place (signed differently): reinstall once.
  final bool reinstall;

  double get progress => (release == null || release!.size == 0)
      ? 0
      : (received / release!.size).clamp(0.0, 1.0);
}

/// Over-the-air updates: checks GitHub for a newer build, downloads it
/// (resuming if the connection drops), verifies it, and hands it to Android to
/// install. Ported from the Moose updater to this app's ChangeNotifier style.
class AppUpdater extends ChangeNotifier {
  AppUpdater({UpdatePlatform? platform, http.Client? client})
    : _platform = platform ?? _defaultPlatform(),
      _client = client ?? http.Client() {
    if (_platform == null) {
      _state = const AppUpdateState(UpdatePhase.unsupported);
    } else {
      _results = _platform.results.listen(_onResult);
    }
  }

  static UpdatePlatform? _defaultPlatform() =>
      Platform.isAndroid ? ChannelUpdatePlatform() : null;

  final UpdatePlatform? _platform;
  final http.Client _client;
  StreamSubscription<InstallResult>? _results;
  bool _downloading = false;
  Directory? _dir;

  AppUpdateState _state = const AppUpdateState(UpdatePhase.idle);
  AppUpdateState get state => _state;
  bool get supported => _platform != null;

  void _set(AppUpdateState s) {
    _state = s;
    notifyListeners();
  }

  Future<Directory> _folder() async {
    final d = _dir ??= Directory(
      '${(await getApplicationSupportDirectory()).path}/updates',
    );
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<String> _apkPath(UpdateRelease r) async =>
      '${(await _folder()).path}/${r.versionCode}.apk';

  /// Looks for a newer build. [manual] reports errors; otherwise it fails
  /// quietly.
  Future<void> check({bool manual = false}) async {
    if (!supported) return;
    final s = _state.phase;
    if (s == UpdatePhase.downloading || s == UpdatePhase.installing) return;
    if (manual || s == UpdatePhase.idle || s == UpdatePhase.upToDate) {
      _set(const AppUpdateState(UpdatePhase.checking));
    }
    try {
      final me = await _platform!.info();
      final res = await _client
          .get(
            Uri.parse(updateManifestUrl),
            headers: {'cache-control': 'no-cache'},
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 404) {
        _set(const AppUpdateState(UpdatePhase.upToDate));
        return;
      }
      if (res.statusCode != 200) throw HttpException('${res.statusCode}');
      final release = UpdateRelease.fromManifest(
        jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, Object?>,
        me.abi,
      );
      if (release == null || release.versionCode <= me.versionCode) {
        _set(const AppUpdateState(UpdatePhase.upToDate));
        return;
      }
      final done = File(await _apkPath(release));
      if (await done.exists() && await done.length() == release.size) {
        _set(
          AppUpdateState(
            UpdatePhase.ready,
            release: release,
            apkPath: done.path,
          ),
        );
      } else {
        _set(AppUpdateState(UpdatePhase.available, release: release));
      }
    } catch (e) {
      if (manual) {
        _set(
          const AppUpdateState(
            UpdatePhase.failed,
            message: "Couldn't reach GitHub. Check your connection.",
          ),
        );
      } else if (_state.phase == UpdatePhase.checking) {
        _set(const AppUpdateState(UpdatePhase.idle));
      }
    }
  }

  /// Downloads the available release (resuming a partial download), then
  /// verifies its size, hash, package and signer.
  Future<void> download() async {
    final release = _state.release;
    if (release == null || _downloading) return;
    _downloading = true;
    final path = await _apkPath(release);
    final part = File('$path.part');
    var have = await part.exists() ? await part.length() : 0;
    if (have > release.size) {
      await part.delete();
      have = 0;
    }
    _set(
      AppUpdateState(UpdatePhase.downloading, release: release, received: have),
    );
    IOSink? sink;
    try {
      final res = await _get(Uri.parse(release.url), from: have);
      if (res.statusCode == 200) {
        have = 0;
        sink = part.openWrite();
      } else if (res.statusCode == 206) {
        sink = part.openWrite(mode: FileMode.append);
      } else if (res.statusCode == 416 && have == release.size) {
        // already complete
      } else {
        throw HttpException('${res.statusCode}');
      }
      if (sink != null) {
        var shown = DateTime.fromMillisecondsSinceEpoch(0);
        await for (final chunk in res.stream.timeout(
          const Duration(seconds: 30),
        )) {
          sink.add(chunk);
          have += chunk.length;
          final now = DateTime.now();
          if (now.difference(shown) > const Duration(milliseconds: 120)) {
            shown = now;
            _set(
              AppUpdateState(
                UpdatePhase.downloading,
                release: release,
                received: have,
              ),
            );
          }
        }
        await sink.flush();
        await sink.close();
        sink = null;
      }
      if (await part.length() != release.size) throw const _Damaged();
      if (await _sha256(part) != release.sha256) {
        await part.delete();
        throw const _Damaged();
      }
      final apk = await part.rename(path);
      final me = await _platform!.info();
      final c = await _platform.check(apk.path);
      if (!c.valid || c.package != 'com.isg32.openhd350b') {
        await apk.delete();
        throw const _Damaged();
      }
      if (!c.sameSigner) {
        await apk.delete();
        _set(
          AppUpdateState(
            UpdatePhase.failed,
            release: release,
            reinstall: true,
            message:
                'This copy was installed another way, so it can\'t '
                'update itself. Reinstall the latest from GitHub once; after '
                'that, updates come from here.',
          ),
        );
        return;
      }
      if (c.versionCode <= me.versionCode) {
        await apk.delete();
        _set(const AppUpdateState(UpdatePhase.upToDate));
        return;
      }
      _set(
        AppUpdateState(UpdatePhase.ready, release: release, apkPath: apk.path),
      );
    } on _Damaged {
      _set(
        AppUpdateState(
          UpdatePhase.failed,
          release: release,
          message: 'The download was damaged. Try again.',
        ),
      );
    } catch (e) {
      _set(
        AppUpdateState(
          UpdatePhase.failed,
          release: release,
          message: 'The download stopped. Try again to carry on.',
        ),
      );
    } finally {
      await sink?.close();
      _downloading = false;
    }
  }

  /// Follows GitHub's redirects by hand, so the Range header goes along.
  Future<http.StreamedResponse> _get(Uri url, {required int from}) async {
    var at = url;
    for (var hop = 0; hop < 6; hop++) {
      final req = http.Request('GET', at)..followRedirects = false;
      if (from > 0) req.headers['range'] = 'bytes=$from-';
      final res = await _client.send(req).timeout(const Duration(seconds: 30));
      if (res.isRedirect || (res.statusCode >= 300 && res.statusCode < 400)) {
        final next = res.headers['location'];
        await res.stream.drain<void>();
        if (next == null) break;
        at = at.resolve(next);
        continue;
      }
      return res;
    }
    throw const HttpException('too many redirects');
  }

  static Future<String> _sha256(File f) async {
    final digest = await sha256.bind(f.openRead()).first;
    return digest.toString();
  }

  /// Installs the downloaded release, asking for "Install unknown apps" first
  /// if the app doesn't have it yet.
  Future<void> install() async {
    final release = _state.release;
    final path = _state.apkPath;
    if (release == null || path == null) return;
    try {
      if (!await File(path).exists()) {
        _set(AppUpdateState(UpdatePhase.available, release: release));
        return;
      }
      if (!(await _platform!.info()).canInstall) {
        _set(
          AppUpdateState(
            UpdatePhase.needsPermission,
            release: release,
            apkPath: path,
          ),
        );
        return;
      }
      _set(
        AppUpdateState(UpdatePhase.installing, release: release, apkPath: path),
      );
      await _platform.install(path);
    } catch (e) {
      _set(
        AppUpdateState(
          UpdatePhase.failed,
          release: release,
          message: "Android couldn't start the install. Try again.",
        ),
      );
    }
  }

  /// Carries on an install that was waiting for "Install unknown apps".
  Future<void> resumed() async {
    if (!supported) return;
    if (_state.phase == UpdatePhase.needsPermission) {
      try {
        if ((await _platform!.info()).canInstall) {
          await install();
          return;
        }
      } catch (_) {}
    }
    if (_state.phase == UpdatePhase.installing && !_state.confirming) return;
    await check();
  }

  Future<void> allowInstalls() async {
    try {
      await _platform?.openInstallSettings();
    } catch (_) {}
  }

  void clearFailure() {
    if (_state.phase != UpdatePhase.failed) return;
    _set(
      _state.release != null
          ? AppUpdateState(UpdatePhase.available, release: _state.release)
          : const AppUpdateState(UpdatePhase.idle),
    );
  }

  void _onResult(InstallResult r) {
    if (_state.phase != UpdatePhase.installing) return;
    switch (r.code) {
      case InstallResult.pendingUser:
        _set(
          AppUpdateState(
            UpdatePhase.installing,
            release: _state.release,
            apkPath: _state.apkPath,
            confirming: true,
          ),
        );
      case InstallResult.success:
        // The app is being replaced and will close.
        break;
      case InstallResult.aborted:
        _set(
          AppUpdateState(
            UpdatePhase.ready,
            release: _state.release,
            apkPath: _state.apkPath,
          ),
        );
      default:
        _set(
          AppUpdateState(
            UpdatePhase.failed,
            release: _state.release,
            message: r.code == 7
                ? "This update doesn't fit this phone."
                : r.code == 6
                ? 'Not enough space to install it.'
                : "Android couldn't install it. Try again.",
          ),
        );
    }
  }

  @override
  void dispose() {
    _results?.cancel();
    _client.close();
    super.dispose();
  }
}

class _Damaged implements Exception {
  const _Damaged();
}
