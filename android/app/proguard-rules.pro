# Keep Flutter engine and plugin registrants
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.internal.** { *; }
-keep class io.flutter.provider.** { *; }

# Keep AudioService and JustAudio
-keep class com.ryanheise.audioservice.** { *; }
-keep class com.ryanheise.just_audio.** { *; }

# Keep Extractor / YoutubeDL native JNI classes and methods
-keep class com.ashishpipaliya.extractor.** { *; }
-keep class com.ashishpipaliya.** { *; }
-keep class com.ya2s.youtubedl_android.** { *; }
-keep class com.junkfood.extractor.** { *; }
-keep class io.github.junkfood02.** { *; }
-dontwarn com.ashishpipaliya.**
-dontwarn com.ya2s.youtubedl_android.**
-dontwarn com.junkfood.extractor.**
-dontwarn io.github.junkfood02.**

# Keep Media3 / ExoPlayer
-keep class androidx.media3.** { *; }
-keep class com.google.android.exoplayer2.** { *; }
-dontwarn androidx.media3.**
-dontwarn com.google.android.exoplayer2.**
