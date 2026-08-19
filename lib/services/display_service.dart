import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Device Display & High Refresh Rate Engine.
///
/// On Android devices with high refresh rate screens (90Hz, 120Hz, 144Hz OLED/AMOLED),
/// this service configures the Android WindowManager to use the highest available
/// display mode for silky smooth animations, high-speed scrolling, and low input latency.
///
/// It also exposes adaptive animation factors so particle effects and canvas painters
/// adapt their complexity based on the device's refresh rate and power profile.
class DisplayService {
  static final DisplayService _instance = DisplayService._internal();
  factory DisplayService() => _instance;
  DisplayService._internal();

  static const MethodChannel _channel = MethodChannel('com.sonicwave.sonic_wave/display');

  double _currentRefreshRate = 60.0;
  List<double> _supportedRefreshRates = const [60.0];
  bool _isHighRefreshRate = false;
  bool _isInitialized = false;

  double get currentRefreshRate => _currentRefreshRate;
  List<double> get supportedRefreshRates => _supportedRefreshRates;
  bool get isHighRefreshRate => _isHighRefreshRate;
  bool get isInitialized => _isInitialized;

  /// Recommended particle density multiplier (1.0 for 60Hz, 1.4 for 90Hz/120Hz)
  double get particleDensityMultiplier => _isHighRefreshRate ? 1.4 : 1.0;

  /// Initialize and request the highest available display refresh rate mode from Android.
  Future<void> initialize() async {
    if (_isInitialized) return;
    _isInitialized = true;

    if (!Platform.isAndroid) return;

    try {
      final success = await _channel.invokeMethod<bool>('enableHighRefreshRate') ?? false;
      final rates = await _channel.invokeListMethod<double>('getSupportedRefreshRates');

      if (rates != null && rates.isNotEmpty) {
        _supportedRefreshRates = rates;
        final maxRate = rates.reduce((a, b) => a > b ? a : b);
        _currentRefreshRate = maxRate;
        _isHighRefreshRate = maxRate >= 85.0;
        debugPrint('[DisplayService] Android Display Modes: $rates (Max: ${_currentRefreshRate.toStringAsFixed(0)}Hz, HighRefreshRate=$success)');
      }
    } catch (e) {
      debugPrint('[DisplayService] Display configuration fallback: $e');
    }
  }
}
