package com.isg32.openhd350b

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Over-the-air app updates from GitHub Releases
        // (lib/features/updates/app_updater.dart).
        Updater.register(this, flutterEngine.dartExecutor.binaryMessenger)
    }
}
