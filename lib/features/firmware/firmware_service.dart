import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/gaia/gaia_constants.dart';
import 'firmware_crypto.dart';
import 'firmware_models.dart';

/// Talks to the Sennheiser firmware cloud and manages locally-saved images.
///
/// Cloud endpoint and parameters were recovered from Smart Control 4.7.0:
///   GET {base}/updates/{articleNumber}/{currentVersion}
///       ?os_type=Android&os_version=..&app_ver=4.7.0&app_flavor=prod[&hw_revision=..]
/// No API key is attached for firmware functions. Only the client's own name
/// is sent; no user data leaves the device.
class FirmwareService extends ChangeNotifier {
  FirmwareService({http.Client? client}) : _http = client ?? http.Client();

  static const _base = 'https://api.s-consumer-cloud.com/firmware/api/v2';
  static const _appVersion = '4.7.0';
  final http.Client _http;

  List<SavedFirmware> _saved = [];
  List<SavedFirmware> get saved => List.unmodifiable(_saved);

  FirmwarePackage? _latest;
  FirmwarePackage? get latest => _latest;

  /// All firmware versions the cloud lists for the device (newest first).
  List<String> _available = [];
  List<String> get available => List.unmodifiable(_available);

  bool _checking = false;
  bool get checking => _checking;

  /// Common query parameters the firmware API expects.
  Map<String, String> _params({String? hwRevision}) => {
    'os_type': 'Android',
    'os_version': Platform.operatingSystemVersion.split(' ').first,
    'app_ver': _appVersion,
    'app_flavor': 'prod',
    if (hwRevision != null && hwRevision.isNotEmpty) 'hw_revision': hwRevision,
  };

  String? _error;
  String? get error => _error;

  FirmwareProgress? _progress;
  FirmwareProgress? get progress => _progress;

  String? _dirPath;

  /// The folder downloaded firmware is saved in: the phone's public
  /// `Downloads/OpenHD350B/Firmwares` on Android (browsable in Files),
  /// falling back to private storage. Exposed so the UI can show it.
  String? get storageDirPath => _dirPath;

  bool _storageGranted = false;
  bool get hasStoragePermission => _storageGranted;

  /// Requests "All files access" so firmware can be written to the public
  /// Downloads folder. On Android 11+ this opens the system settings screen;
  /// the grant is picked up when the user returns.
  Future<bool> ensureStoragePermission() async {
    if (!Platform.isAndroid) {
      _storageGranted = true;
      return true;
    }
    var status = await Permission.manageExternalStorage.status;
    if (!status.isGranted) {
      status = await Permission.manageExternalStorage.request();
    }
    _storageGranted = status.isGranted;
    notifyListeners();
    return _storageGranted;
  }

  Future<Directory> _dir() async {
    Directory target;
    if (Platform.isAndroid) {
      // Derive the storage root (e.g. /storage/emulated/0) from the
      // app-specific external dir, then the public Downloads subfolder.
      var root = '/storage/emulated/0';
      try {
        final ext = await getExternalStorageDirectory();
        if (ext != null && ext.path.contains('/Android/')) {
          root = ext.path.split('/Android/').first;
        }
      } catch (_) {}
      target = Directory('$root/Download/OpenHD350B/Firmwares');
    } else {
      final base = await getApplicationDocumentsDirectory();
      target = Directory('${base.path}/firmware');
    }
    try {
      if (!await target.exists()) await target.create(recursive: true);
    } catch (_) {
      // Not writable yet (permission not granted): fall back to private
      // storage so the index can still be read.
      final base = await getApplicationDocumentsDirectory();
      target = Directory('${base.path}/firmware');
      if (!await target.exists()) await target.create(recursive: true);
    }
    _dirPath = target.path;
    return target;
  }

  File _indexFile(Directory d) => File('${d.path}/index.json');

  /// Loads the saved-firmware index from disk.
  Future<void> loadSaved() async {
    try {
      final f = _indexFile(await _dir());
      if (await f.exists()) {
        final list = jsonDecode(await f.readAsString()) as List;
        _saved =
            list
                .map((e) => SavedFirmware.fromJson(e as Map<String, dynamic>))
                .toList()
              ..sort((a, b) => b.downloadedAt.compareTo(a.downloadedAt));
      }
    } catch (e) {
      debugPrint('[firmware] loadSaved failed: $e');
    }
    notifyListeners();
  }

  Future<void> _writeIndex() async {
    final f = _indexFile(await _dir());
    await f.writeAsString(jsonEncode(_saved.map((s) => s.toJson()).toList()));
  }

  Future<Map<String, dynamic>> _getJson(
    String path, {
    Map<String, String>? params,
  }) async {
    final uri = Uri.parse('$_base/$path')
        .replace(queryParameters: params ?? _params());
    final r = await _http.get(
      uri,
      headers: {'Content-Type': 'application/json'},
    );
    if (r.statusCode != 200) throw 'HTTP ${r.statusCode}';
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Asks the cloud whether an update exists for [currentVersion]. The result
  /// (the latest package, if any) is stored in [latest]. `success:true` with
  /// null data means the device is already current. Also refreshes the full
  /// [available] version list so current and previous versions can be fetched.
  Future<FirmwarePackage?> checkForUpdate(
    String currentVersion, {
    String? hwRevision,
    String articleNumber = Hd350Params.articleNumber,
  }) async {
    _checking = true;
    _error = null;
    _latest = null;
    notifyListeners();
    try {
      await listVersions(articleNumber: articleNumber);
      final j = await _getJson(
        'updates/$articleNumber/$currentVersion',
        params: _params(hwRevision: hwRevision),
      );
      final data = j['data'];
      if (j['success'] != true || data == null) return null; // up to date
      final packages = (data['packages'] as List?) ?? const [];
      if (packages.isEmpty) return null;
      final notes =
          (((data['extras'] as Map?)?['release_notes']) as Map?)?['en']
              as String?;
      _latest = FirmwarePackage.fromJson(
        packages.first as Map<String, dynamic>,
        notes,
      );
      return _latest;
    } catch (e) {
      _error = '$e';
      return null;
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  /// Lists every firmware version the cloud offers for the device (newest
  /// first), stored in [available].
  Future<List<String>> listVersions({
    String articleNumber = Hd350Params.articleNumber,
  }) async {
    try {
      final j = await _getJson('availableSystemReleases/$articleNumber');
      if (j['success'] == true && j['data'] is List) {
        _available = (j['data'] as List)
            .map((e) => '$e')
            .toList(growable: false);
      }
    } catch (e) {
      debugPrint('[firmware] listVersions failed: $e');
    }
    notifyListeners();
    return _available;
  }

  /// Fetches the package for a specific [version] (current or previous), via
  /// the systemRelease endpoint, so any listed version can be downloaded.
  Future<FirmwarePackage?> getPackage(
    String version, {
    String? hwRevision,
    String articleNumber = Hd350Params.articleNumber,
  }) async {
    try {
      final j = await _getJson(
        'systemRelease/$articleNumber/$version',
        params: _params(hwRevision: hwRevision),
      );
      final data = j['data'];
      if (j['success'] != true || data == null) return null;
      final packages = (data['packages'] as List?) ?? const [];
      if (packages.isEmpty) return null;
      final notes =
          (((data['extras'] as Map?)?['release_notes']) as Map?)?['en']
              as String?;
      return FirmwarePackage.fromJson(
        packages.first as Map<String, dynamic>,
        notes,
      );
    } catch (e) {
      _error = '$e';
      notifyListeners();
      return null;
    }
  }

  /// Fetches a version's package and downloads+saves it in one step.
  Future<SavedFirmware?> downloadVersion(
    String version, {
    String? hwRevision,
  }) async {
    final pkg = await getPackage(version, hwRevision: hwRevision);
    if (pkg == null) {
      _error = 'No package for $version';
      notifyListeners();
      return null;
    }
    return downloadAndSave(pkg);
  }

  /// Downloads, decrypts, unzips, md5-verifies and saves a package locally.
  Future<SavedFirmware?> downloadAndSave(FirmwarePackage pkg) async {
    _error = null;
    if (!await ensureStoragePermission()) {
      _error =
          'Storage access is needed to save to Downloads. Grant '
          '"All files access", then try again.';
      notifyListeners();
      return null;
    }
    try {
      _emit(const FirmwareProgress('downloading'));
      final req = http.Request('GET', Uri.parse(pkg.url));
      final resp = await _http.send(req);
      final total = resp.contentLength ?? pkg.sizeBytes;
      final bytes = <int>[];
      await for (final chunk in resp.stream) {
        bytes.addAll(chunk);
        _emit(
          FirmwareProgress('downloading', received: bytes.length, total: total),
        );
      }
      if (resp.statusCode != 200) throw 'HTTP ${resp.statusCode}';

      _emit(const FirmwareProgress('decrypting'));
      final zipBytes = FirmwareCrypto.decrypt(Uint8List.fromList(bytes));

      _emit(const FirmwareProgress('unzipping'));
      final archive = ZipDecoder().decodeBytes(zipBytes);
      final imageEntry = archive.files.firstWhere(
        (f) => f.isFile && !f.name.endsWith('.md5'),
        orElse: () => throw 'no firmware image in package',
      );
      final md5Entry = archive.files
          .where((f) => f.name.endsWith('.md5'))
          .firstOrNull;
      final imageBytes = imageEntry.content as List<int>;

      _emit(const FirmwareProgress('verifying'));
      final digest = md5.convert(imageBytes).toString();
      var verified = false;
      if (md5Entry != null) {
        final expected = utf8
            .decode(md5Entry.content as List<int>)
            .trim()
            .toLowerCase();
        verified = expected == digest;
      }

      final dir = await _dir();
      final verDir = Directory('${dir.path}/${pkg.version}');
      if (!await verDir.exists()) await verDir.create(recursive: true);
      final imagePath = '${verDir.path}/${imageEntry.name}';
      await File(imagePath).writeAsBytes(imageBytes);

      final saved = SavedFirmware(
        version: pkg.version,
        imagePath: imagePath,
        sizeBytes: imageBytes.length,
        downloadedAt: DateTime.now(),
        md5: digest,
        md5Verified: verified,
        releaseNotes: pkg.releaseNotes,
      );
      _saved.removeWhere((s) => s.version == pkg.version);
      _saved.insert(0, saved);
      await _writeIndex();
      _emit(const FirmwareProgress('done'));
      return saved;
    } catch (e) {
      _error = '$e';
      _emit(null);
      return null;
    } finally {
      _emit(null);
    }
  }

  Future<void> deleteSaved(SavedFirmware fw) async {
    try {
      final f = File(fw.imagePath);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    _saved.removeWhere((s) => s.version == fw.version);
    await _writeIndex();
    notifyListeners();
  }

  void _emit(FirmwareProgress? p) {
    _progress = p;
    notifyListeners();
  }

  @override
  void dispose() {
    _http.close();
    super.dispose();
  }
}
