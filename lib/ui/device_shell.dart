import 'package:flutter/material.dart';

import '../core/gaia/gaia_client.dart';
import '../features/device/device_session.dart';
import 'dashboard_screen.dart';
import 'debug_console_screen.dart';
import 'eq_screen.dart';

/// Bottom-nav shell holding the dashboard, EQ, and debug console for one
/// connected device. Owns the [DeviceSession] lifecycle.
class DeviceShell extends StatefulWidget {
  const DeviceShell({
    super.key,
    required this.client,
    required this.title,
    this.firmwareFromGatt,
  });

  final GaiaClient client;
  final String title;
  final String? firmwareFromGatt;

  @override
  State<DeviceShell> createState() => _DeviceShellState();
}

class _DeviceShellState extends State<DeviceShell> {
  late final DeviceSession _session;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _session = DeviceSession(
      widget.client,
      firmwareFromGatt: widget.firmwareFromGatt,
    );
    _session.refreshAll();
  }

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      DashboardScreen(session: _session),
      EqScreen(session: _session),
      DebugConsoleScreen(client: widget.client, title: widget.title),
    ];
    const titles = ['Device', 'Equalizer', 'Console'];
    return Scaffold(
      appBar: _index == 2
          ? null // console has its own app bar
          : AppBar(
              title: Text(titles[_index]),
              actions: [
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: _session.refreshAll,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.headphones_outlined),
            selectedIcon: Icon(Icons.headphones),
            label: 'Device',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune_outlined),
            selectedIcon: Icon(Icons.tune),
            label: 'EQ',
          ),
          NavigationDestination(
            icon: Icon(Icons.terminal_outlined),
            selectedIcon: Icon(Icons.terminal),
            label: 'Console',
          ),
        ],
      ),
    );
  }
}
