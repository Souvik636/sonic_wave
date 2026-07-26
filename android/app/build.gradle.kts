import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Load signing config from android/key.properties when present.
// This file is git-ignored and, in CI, is generated from repository secrets.
// When it is absent (e.g. a fresh local checkout) the release build falls back
// to debug signing so `flutter run --release` keeps working.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseSigning = keystorePropertiesFile.exists()
if (hasReleaseSigning) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.sonicwave.sonic_wave"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.sonicwave.sonic_wave"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // Only wire up the real release keystore when key.properties is present.
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = keystoreProperties["storeFile"]?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Use the real upload/release keystore in CI (key.properties present),
            // otherwise fall back to debug keys so local release runs still work.
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }

    packaging {
        jniLibs {
            // youtubedl-android (extractor plugin) requires its native payloads
            // (libpython.zip.so / libffmpeg.zip.so) to be EXTRACTED to disk at install time
            // and kept unstripped because they are zip archives, not ELF object binaries.
            useLegacyPackaging = true
            keepDebugSymbols.add("**/libpython.zip.so")
            keepDebugSymbols.add("**/libffmpeg.zip.so")
            keepDebugSymbols.add("**/*.zip.so")
            excludes.addAll(setOf("**/x86/**", "**/x86_64/**", "**/libaria2c*.so"))
        }
    }
}

flutter {
    source = "../.."
}
