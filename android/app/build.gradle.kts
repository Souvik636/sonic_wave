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
//
// That fallback is convenient locally and dangerous when shipping: an APK signed
// with the debug key cannot be installed over one signed with the real key.
// Android reports INSTALL_FAILED_UPDATE_INCOMPATIBLE, which the package
// installer shows as "Install not completed" — the download and checksum both
// pass, so it looks like an installer bug rather than a signing mismatch.
// Set SONICWAVE_REQUIRE_RELEASE_SIGNING=1 (CI does) to turn the fallback into a
// hard failure instead.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseSigning = keystorePropertiesFile.exists()
if (hasReleaseSigning) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
val requireReleaseSigning = System.getenv("SONICWAVE_REQUIRE_RELEASE_SIGNING") == "1"
if (requireReleaseSigning && !hasReleaseSigning) {
    throw GradleException(
        "SONICWAVE_REQUIRE_RELEASE_SIGNING=1 but android/key.properties is missing. " +
            "Refusing to debug-sign a release build: the resulting APK could not be " +
            "installed over an existing SonicWave install."
    )
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

        // Package ONLY 64-bit ARM native libraries. The extractor plugin
        // (yt-dlp) bundles pre-compiled FFmpeg + Python for both arm64-v8a
        // and armeabi-v7a. Without this filter the 32-bit copies (~43 MB)
        // ship inside the APK even with --target-platform=android-arm64,
        // because that flag only controls the Flutter engine, not plugins.
        ndk {
            abiFilters.add("arm64-v8a")
        }
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
                logger.warn(
                    "\n**********************************************************************\n" +
                        "WARNING: building a RELEASE apk with the DEBUG signing key.\n" +
                        "android/key.properties was not found, so this artifact CANNOT be\n" +
                        "installed over a release-signed SonicWave install — Android will\n" +
                        "report \"Install not completed\". Do not publish this build.\n" +
                        "**********************************************************************\n"
                )
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
            excludes.addAll(setOf("**/x86/**", "**/x86_64/**", "**/armeabi-v7a/**", "**/libaria2c*.so"))
        }
    }
}

flutter {
    source = "../.."
}
