import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import '../widgets/premium_interaction.dart';

enum WearableDeviceType {
  watch,
  headset,
  speaker,
  car,
  audio,
}

class WearableEvent {
  final String name;
  final WearableDeviceType type;
  final bool isConnected;
  final String? address;
  final DateTime timestamp;

  const WearableEvent({
    required this.name,
    required this.type,
    required this.isConnected,
    this.address,
    required this.timestamp,
  });

  String get iconLabel {
    switch (type) {
      case WearableDeviceType.watch:
        return '⌚';
      case WearableDeviceType.headset:
        return '🎧';
      case WearableDeviceType.speaker:
        return '🔊';
      case WearableDeviceType.car:
        return '🚗';
      case WearableDeviceType.audio:
        return '🎵';
    }
  }

  String get typeTitle {
    switch (type) {
      case WearableDeviceType.watch:
        return 'Smartwatch & Wearable';
      case WearableDeviceType.headset:
        return 'Wireless Headset';
      case WearableDeviceType.speaker:
        return 'Bluetooth Speaker';
      case WearableDeviceType.car:
        return 'Car Audio System';
      case WearableDeviceType.audio:
        return 'Wireless Audio Accessory';
    }
  }
}

/// Service to detect and manage Wearable, Smartwatch, and Bluetooth Audio Device connections.
class WearableService {
  static final WearableService _instance = WearableService._internal();
  factory WearableService() => _instance;
  WearableService._internal();

  static const MethodChannel _channel = MethodChannel('com.sonicwave.sonic_wave/wearable');

  final ValueNotifier<WearableEvent?> activeEventNotifier = ValueNotifier<WearableEvent?>(null);
  final List<WearableEvent> _connectedDevices = [];

  List<WearableEvent> get connectedDevices => List.unmodifiable(_connectedDevices);
  bool get hasConnectedWearable => _connectedDevices.any((d) => d.type == WearableDeviceType.watch);

  bool _isInitialized = false;

  void initialize() {
    if (_isInitialized) return;
    _isInitialized = true;

    _channel.setMethodCallHandler((call) async {
      try {
        if (call.method == 'onDeviceConnected') {
          final args = Map<String, dynamic>.from(call.arguments as Map);
          final name = (args['name'] as String?)?.trim() ?? 'Wireless Audio Accessory';
          final rawType = args['type'] as String? ?? 'headset';
          final address = args['address'] as String?;

          final type = _parseType(rawType, name);
          final event = WearableEvent(
            name: name,
            type: type,
            isConnected: true,
            address: address,
            timestamp: DateTime.now(),
          );

          _connectedDevices.removeWhere((d) => d.name == name);
          _connectedDevices.add(event);

          AppHaptics.medium();
          activeEventNotifier.value = event;
          debugPrint('[WearableService] Connected: $name ($type)');
        } else if (call.method == 'onDeviceDisconnected') {
          final args = Map<String, dynamic>.from(call.arguments as Map);
          final name = (args['name'] as String?)?.trim() ?? 'Wireless Audio Accessory';
          final rawType = args['type'] as String? ?? 'headset';
          final type = _parseType(rawType, name);

          _connectedDevices.clear();
          final event = WearableEvent(
            name: name,
            type: type,
            isConnected: false,
            timestamp: DateTime.now(),
          );

          AppHaptics.light();
          activeEventNotifier.value = event;
          debugPrint('[WearableService] Disconnected: $name ($type)');
        }
      } catch (e) {
        debugPrint('[WearableService] MethodCall error: $e');
      }
    });

    // Check currently connected devices right on startup
    checkConnectedDevices();

    // Re-check automatically whenever app comes to foreground
    AppLifecycleListener(
      onResume: checkConnectedDevices,
    );
  }

  Future<void> checkConnectedDevices() async {
    try {
      await _channel.invokeMethod('checkConnectedDevices');
    } catch (e) {
      debugPrint('[WearableService] checkConnectedDevices error: $e');
    }
  }

  void dismissActiveEvent() {
    activeEventNotifier.value = null;
  }

  WearableDeviceType _parseType(String raw, [String name = '']) {
    final lowerName = name.toLowerCase();
    if (lowerName.contains('watch') ||
        lowerName.contains('band') ||
        lowerName.contains('gear') ||
        lowerName.contains('fit')) {
      return WearableDeviceType.watch;
    }
    if (lowerName.contains('car') || lowerName.contains('auto')) {
      return WearableDeviceType.car;
    }
    if (lowerName.contains('speaker') || lowerName.contains('soundbar')) {
      return WearableDeviceType.speaker;
    }
    if (lowerName.contains('neckband') ||
        lowerName.contains('neck') ||
        lowerName.contains('rockerz') ||
        lowerName.contains('bullets') ||
        lowerName.contains('buds') ||
        lowerName.contains('headset') ||
        lowerName.contains('headphone') ||
        lowerName.contains('ear') ||
        lowerName.contains('wireless')) {
      return WearableDeviceType.headset;
    }

    switch (raw.toLowerCase()) {
      case 'watch':
        return WearableDeviceType.watch;
      case 'headset':
        return WearableDeviceType.headset;
      case 'speaker':
        return WearableDeviceType.speaker;
      case 'car':
        return WearableDeviceType.car;
      default:
        return WearableDeviceType.headset;
    }
  }
}
