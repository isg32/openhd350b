import 'package:flutter/material.dart';

import 'ui/scan_screen.dart';
import 'ui/theme.dart';

void main() {
  runApp(const OpenSennheiserApp());
}

class OpenSennheiserApp extends StatelessWidget {
  const OpenSennheiserApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenSennheiser',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      home: const ScanScreen(),
    );
  }
}
