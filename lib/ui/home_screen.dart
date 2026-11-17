import 'package:flutter/material.dart';

import '../features/device/connection_controller.dart';
import '../features/firmware/firmware_service.dart';
import 'device_shell.dart';
import 'scan_screen.dart';
import 'theme.dart';

/// App home. Auto-connects to a bonded HD 350BT on launch and shows the device
/// shell once connected; otherwise shows a connect prompt.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _conn = ConnectionController();
  final _firmware = FirmwareService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _conn.autoConnect());
  }

  @override
  void dispose() {
    _conn.dispose();
    _firmware.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _conn,
      builder: (context, _) {
        if (_conn.isConnected) {
          return DeviceShell(
            session: _conn.session!,
            firmware: _firmware,
            title: 'HD 350BT',
            onDisconnect: _conn.disconnect,
          );
        }
        return _ConnectView(conn: _conn, firmware: _firmware);
      },
    );
  }
}

class _ConnectView extends StatelessWidget {
  const _ConnectView({required this.conn, required this.firmware});
  final ConnectionController conn;
  final FirmwareService firmware;

  @override
  Widget build(BuildContext context) {
    final busy =
        conn.phase == ConnectionPhase.searching ||
        conn.phase == ConnectionPhase.connecting;
    final label = switch (conn.phase) {
      ConnectionPhase.searching => 'Looking for your HD 350BT…',
      ConnectionPhase.connecting => 'Connecting…',
      ConnectionPhase.needsPermission => 'Bluetooth permission needed',
      ConnectionPhase.failed => conn.error ?? 'Not connected',
      _ => 'Not connected',
    };

    return Scaffold(
      appBar: AppBar(title: const Text('OpenHD350B')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                height: 180,
                child: Opacity(
                  opacity: busy ? 1 : 0.6,
                  child: Image.asset(
                    'assets/images/hd350bt.png',
                    fit: BoxFit.contain,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              if (busy) ...[
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
              ],
              Text(
                label,
                textAlign: TextAlign.center,
                style: context.texts.titleMedium,
              ),
              const SizedBox(height: 24),
              if (!busy) ...[
                FilledButton.icon(
                  onPressed: conn.autoConnect,
                  icon: const Icon(Icons.bluetooth_searching),
                  label: const Text('Connect'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ScanScreen(onPicked: conn.connectTo),
                    ),
                  ),
                  child: const Text('Choose a device manually'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
