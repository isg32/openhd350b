import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../features/device/connection_controller.dart';
import '../features/device/device_session.dart';
import '../features/firmware/firmware_service.dart';
import '../features/updates/app_updater.dart';
import 'about_screen.dart';
import 'dashboard_screen.dart';
import 'debug_console_screen.dart';
import 'eq_screen.dart';
import 'update_ui.dart';
import 'firmware_screen.dart';

/// Bottom-nav shell for a connected device: dashboard, EQ, firmware, console.
/// The [session] is owned by the caller (the connection controller).
class DeviceShell extends StatefulWidget {
  const DeviceShell({
    super.key,
    required this.session,
    required this.firmware,
    required this.title,
    this.updater,
    this.conn,
    this.onDisconnect,
  });

  final DeviceSession session;
  final FirmwareService firmware;
  final String title;
  final AppUpdater? updater;
  final ConnectionController? conn;
  final VoidCallback? onDisconnect;

  @override
  State<DeviceShell> createState() => _DeviceShellState();
}

class _DeviceShellState extends State<DeviceShell> {
  int _index = 0;

  /// Back from any other tab returns to the Device tab (the home page); back
  /// from the Device tab asks before leaving the app.
  Future<void> _onBack(bool didPop) async {
    if (didPop) return;
    if (_index != 0) {
      setState(() => _index = 0);
      return;
    }
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Exit OpenHD350B?'),
        content: const Text('Close the app?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Stay'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Exit'),
          ),
        ],
      ),
    );
    if (leave ?? false) await SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      DashboardScreen(session: widget.session),
      EqScreen(session: widget.session),
      FirmwareScreen(
        firmware: widget.firmware,
        session: widget.session,
        conn: widget.conn,
      ),
      DebugConsoleScreen(client: widget.session.client, title: widget.title),
    ];
    const titles = ['OpenHD350B', 'Equalizer', 'Firmware', 'Console'];
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) => _onBack(didPop),
      child: Scaffold(
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
                  IconButton(
                    tooltip: 'About',
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const AboutScreen()),
                    ),
                    icon: const Icon(Icons.info_outline),
                  ),
                  if (widget.updater != null)
                    PopupMenuButton<String>(
                      onSelected: (v) async {
                        if (v == 'update') {
                          await widget.updater!.check(manual: true);
                          if (context.mounted) {
                            showUpdateSheet(context, widget.updater!);
                          }
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'update',
                          child: Text('Check for app updates'),
                        ),
                      ],
                    ),
                ],
              ),
        body: Stack(
          children: [
            IndexedStack(index: _index, children: pages),
            // A floating update pill just above the bottom nav bar (not on
            // the console tab, which has its own input row).
            if (widget.updater != null && _index != 3)
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: UpdateCard(updater: widget.updater!),
              ),
          ],
        ),
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
      ),
    );
  }
}
