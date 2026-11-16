import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/gaia/gaia_client.dart';
import '../core/gaia/gaia_constants.dart';
import '../core/transport/ble_transport.dart';
import 'device_shell.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  List<ScanResult> _results = [];
  List<BluetoothDevice> _system = [];
  bool _scanning = false;
  bool _showAll = false;
  String? _error;
  String? _connectingId;
  StreamSubscription<List<ScanResult>>? _resultsSub;
  StreamSubscription<bool>? _scanningSub;

  @override
  void initState() {
    super.initState();
    _resultsSub = FlutterBluePlus.scanResults.listen(
      (r) => setState(() => _results = r),
    );
    _scanningSub = FlutterBluePlus.isScanning.listen(
      (s) => setState(() => _scanning = s),
    );
  }

  @override
  void dispose() {
    _resultsSub?.cancel();
    _scanningSub?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  Future<bool> _ensurePermissions() async {
    if (!Platform.isAndroid) return true;
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse, // only needed on Android <= 11
    ].request();
    final modern =
        statuses[Permission.bluetoothScan]!.isGranted &&
        statuses[Permission.bluetoothConnect]!.isGranted;
    final legacy = statuses[Permission.locationWhenInUse]!.isGranted;
    return modern || legacy;
  }

  Future<void> _scan() async {
    setState(() => _error = null);
    if (!await _ensurePermissions()) {
      setState(() => _error = 'Bluetooth permissions denied');
      return;
    }
    // adapterStateNow is `unknown` until the plugin reports the first state,
    // so wait for a real value instead of reading it immediately.
    final adapter = await FlutterBluePlus.adapterState
        .firstWhere((s) => s != BluetoothAdapterState.unknown)
        .timeout(
          const Duration(seconds: 3),
          onTimeout: () => BluetoothAdapterState.unknown,
        );
    if (adapter != BluetoothAdapterState.on) {
      setState(() => _error = 'Bluetooth adapter state: ${adapter.name}');
      return;
    }
    try {
      // Headphones already connected over classic BT may not advertise LE;
      // the OS can still hand us the LE link if it exposes the GAIA service.
      final system = await FlutterBluePlus.systemDevices([
        Guid(GaiaUuids.service),
      ]);
      setState(() => _system = system);
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  bool _isHd350(String name) =>
      hd350NamePrefixes.any((p) => name.startsWith(p));

  Future<void> _open(BluetoothDevice device) async {
    await FlutterBluePlus.stopScan();
    setState(() {
      _connectingId = device.remoteId.str;
      _error = null;
    });
    final transport = BleGaiaTransport(device);
    try {
      await transport.connect();
      if (!mounted) return;
      final client = GaiaClient(transport);
      // The transport reads the standard GATT firmware string on connect.
      final fw = transport.discoveryReport
          .where((l) => l.startsWith('Firmware revision:'))
          .map((l) => l.split(':').last.trim())
          .where((v) => v.isNotEmpty)
          .firstOrNull;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => DeviceShell(
            client: client,
            firmwareFromGatt: fw,
            title: device.platformName.isEmpty
                ? device.remoteId.str
                : device.platformName,
          ),
        ),
      );
      await client.dispose();
      await transport.disconnect();
    } catch (e) {
      setState(() => _error = 'Connect failed: $e');
    } finally {
      if (mounted) setState(() => _connectingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scanned = _results.where((r) {
      final name = r.advertisementData.advName.isNotEmpty
          ? r.advertisementData.advName
          : r.device.platformName;
      return _showAll ? name.isNotEmpty : _isHd350(name);
    }).toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
    final systemIds = _system.map((d) => d.remoteId).toSet();

    return Scaffold(
      appBar: AppBar(
        title: const Text('OpenSennheiser'),
        actions: [
          Row(
            children: [
              const Text('All'),
              Switch(
                value: _showAll,
                onChanged: (v) => setState(() => _showAll = v),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _scanning ? FlutterBluePlus.stopScan : _scan,
        icon: Icon(_scanning ? Icons.stop : Icons.bluetooth_searching),
        label: Text(_scanning ? 'Stop' : 'Scan'),
      ),
      body: ListView(
        children: [
          if (_scanning) const LinearProgressIndicator(),
          if (_error != null)
            ListTile(
              leading: const Icon(Icons.error_outline, color: Colors.red),
              title: Text(_error!),
            ),
          if (_system.isNotEmpty) const _Header('Connected to this phone'),
          for (final d in _system)
            _DeviceTile(
              name: d.platformName,
              id: d.remoteId.str,
              subtitle: 'exposes GAIA service',
              busy: _connectingId == d.remoteId.str,
              onTap: () => _open(d),
            ),
          const _Header('Nearby'),
          for (final r in scanned.where(
            (r) => !systemIds.contains(r.device.remoteId),
          ))
            _DeviceTile(
              name: r.advertisementData.advName.isNotEmpty
                  ? r.advertisementData.advName
                  : r.device.platformName,
              id: r.device.remoteId.str,
              subtitle: '${r.rssi} dBm',
              busy: _connectingId == r.device.remoteId.str,
              onTap: () => _open(r.device),
            ),
          if (scanned.isEmpty && _system.isEmpty && !_scanning)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Tap Scan. Put the HD 350BT in pairing mode if it does not '
                'show up, or turn on "All" to see every named device.',
              ),
            ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.name,
    required this.id,
    required this.subtitle,
    required this.busy,
    required this.onTap,
  });
  final String name, id, subtitle;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.headphones),
    title: Text(name.isEmpty ? id : name),
    subtitle: Text('$id · $subtitle'),
    trailing: busy
        ? const SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.chevron_right),
    onTap: busy ? null : onTap,
  );
}
