import 'package:flutter/material.dart';

import '../features/device/device_session.dart';
import '../features/firmware/firmware_service.dart';
import 'dashboard_screen.dart';
import 'debug_console_screen.dart';
import 'eq_screen.dart';
import 'firmware_screen.dart';

/// Bottom-nav shell for a connected device: dashboard, EQ, firmware, console.
/// The [session] is owned by the caller (the connection controller).
class DeviceShell extends StatefulWidget {
  const DeviceShell({
    super.key,
    required this.session,
    required this.firmware,
    required this.title,
    this.onDisconnect,
  });

  final DeviceSession session;
  final FirmwareService firmware;
  final String title;
  final VoidCallback? onDisconnect;

  @override
  State<DeviceShell> createState() => _DeviceShellState();
}

class _DeviceShellState extends State<DeviceShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      DashboardScreen(session: widget.session),
      EqScreen(session: widget.session),
      FirmwareScreen(firmware: widget.firmware, session: widget.session),
      DebugConsoleScreen(client: widget.session.client, title: widget.title),
    ];
    const titles = ['Device', 'Equalizer', 'Firmware', 'Console'];
    return Scaffold(
      appBar: _index == 3
          ? null // console has its own app bar
          : AppBar(
              title: Text(titles[_index]),
              actions: [
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: widget.session.refreshAll,
                  icon: const Icon(Icons.refresh),
                ),
                if (widget.onDisconnect != null)
                  IconButton(
                    tooltip: 'Disconnect',
                    onPressed: widget.onDisconnect,
                    icon: const Icon(Icons.bluetooth_disabled),
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
            icon: Icon(Icons.system_update_outlined),
            selectedIcon: Icon(Icons.system_update),
            label: 'Firmware',
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
