import 'package:flutter/material.dart';

import 'ui/home_screen.dart';
import 'ui/theme.dart';

void main() {
  runApp(const OpenHd350bApp());
}

class OpenHd350bApp extends StatelessWidget {
  const OpenHd350bApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenHD350B',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      home: const HomeScreen(),
    );
  }
}
