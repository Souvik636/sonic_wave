import 'package:audio_service/audio_service.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'providers/home_provider.dart';
import 'providers/player_provider.dart';
import 'providers/search_provider.dart';
import 'providers/settings_provider.dart';
import 'screens/splash_screen.dart';
import 'services/app_messenger.dart';
import 'services/audio_handler.dart';
import 'services/display_service.dart';
import 'services/jamendo_service.dart';
import 'services/wearable_service.dart';
import 'services/ytdlp_runtime.dart';
import 'theme/app_theme.dart';
import 'widgets/wearable_connection_banner.dart';

SonicWaveAudioHandler? _audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Set Jamendo Client ID
  JamendoService().clientId = '3dce8b55';

  // Lock orientation to Portrait mode only (prevents landscape rotation)
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Set system UI style
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF0D0D1A),
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  // Initialize audio service (non-blocking — app starts even if this fails)
  try {
    _audioHandler = await AudioService.init(
      builder: () => SonicWaveAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.sonicwave.sonic_wave.audio',
        androidNotificationChannelName: 'SonicWave Audio',
        androidNotificationOngoing: false,
        androidStopForegroundOnPause: true,
        androidNotificationIcon: 'mipmap/ic_launcher',
      ),
    );
  } catch (e) {
    debugPrint('AudioService init failed: $e');
    _audioHandler = SonicWaveAudioHandler();
  }

  runApp(const SonicWaveApp());

  // Warm the yt-dlp runtime, high refresh rate, and wearable accessory engine
  WidgetsBinding.instance.addPostFrameCallback((_) {
    YtDlpRuntime.ensureInitialized();
    DisplayService().initialize();
    WearableService().initialize();
  });
}

class SonicWaveApp extends StatelessWidget {
  const SonicWaveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => SettingsProvider(),
        ),
        ChangeNotifierProxyProvider<SettingsProvider, PlayerProvider>(
          create: (context) => PlayerProvider(_audioHandler!),
          update: (context, settings, player) => player!..updateSettings(settings),
        ),
        ChangeNotifierProvider(
          create: (_) => SearchProvider(),
        ),
        ChangeNotifierProvider(
          create: (_) => HomeProvider(),
        ),
      ],
      child: Consumer<SettingsProvider>(
        builder: (context, settings, child) {
          return DynamicColorBuilder(
            builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
              // Material You: use the wallpaper-derived palette when the user
              // enabled it and the platform provides one (Android 12+).
              final dynamicScheme =
                  settings.useMaterialYou ? darkDynamic : null;
              return MaterialApp(
                title: 'SonicWave',
                debugShowCheckedModeBanner: false,
                // Lets non-widget code (e.g. a YouTube link shared into the
                // app) surface a snackbar without a BuildContext.
                scaffoldMessengerKey: AppMessenger.key,
                theme: AppTheme.darkTheme(
                  settings.accentColor,
                  dynamicScheme: dynamicScheme,
                ),
                // builder wraps the Navigator, so HUD banners and cards float
                // above every route (Settings, Player, Home, Library) without
                // disappearing when the user navigates between screens.
                builder: (context, child) {
                  return Stack(
                    children: [
                      ?child,
                      const WearableConnectionBanner(),
                    ],
                  );
                },
                home: const SplashScreen(),
              );
            },
          );
        },
      ),
    );
  }
}
