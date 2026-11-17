plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.isg32.openhd350b"
    compileSdk = 37 // permission_handler_android requires >= 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.isg32.openhd350b"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Release signing from environment variables (set by the CI release
    // workflow). Over-the-air self-update needs every release signed with the
    // same key. Falls back to debug signing locally when they are unset.
    val keystoreFile = System.getenv("OPENHD_KEYSTORE_FILE")
    val hasReleaseKeystore = keystoreFile != null && file(keystoreFile).exists()
    if (hasReleaseKeystore) {
        signingConfigs {
            create("release") {
                storeFile = file(keystoreFile!!)
                storePassword = System.getenv("OPENHD_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("OPENHD_KEY_ALIAS") ?: "upload"
                keyPassword = System.getenv("OPENHD_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                // Debug keys locally, so `flutter run --release` still works.
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
