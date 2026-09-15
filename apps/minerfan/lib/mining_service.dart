import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:xmr_core/xmr_core.dart';

/// The Android foreground service that keeps the node running with the app
/// closed or the screen off (see MiningService.kt). No-op elsewhere.
class MiningService {
  static const _channel = MethodChannel('minerfan/service');

  static bool get supported => Platform.isAndroid;

  /// [onStopRequested] runs when the notification's Stop action is pressed.
  static void listen(Future<void> Function() onStopRequested) {
    if (!supported) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'stopRequested') await onStopRequested();
    });
  }

  static Future<void> start(String text) => _call('start', {'text': text});
  static Future<void> update(String text) => _call('update', {'text': text});
  static Future<void> stop() => _call('stop');
  static Future<void> requestNotificationPermission() => _call('requestNotificationPermission');

  /// Whether the device offers sustained performance mode (Android 7+ and
  /// the vendor opts in); false elsewhere.
  static Future<bool> sustainedPerformanceSupported() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('sustainedPerformanceSupported') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Whether Android exempts the app from battery optimization (true where
  /// the question does not apply).
  static Future<bool> batteryExempt() async {
    if (!supported) return true;
    try {
      return await _channel.invokeMethod<bool>('batteryExempt') ?? false;
    } on MissingPluginException {
      return true;
    } on PlatformException {
      return false;
    }
  }

  /// Shows Android's dialog to exempt the app from battery optimization,
  /// which lets it keep mining and restart mining after the system killed
  /// it. False when it could not be shown (no activity on screen).
  static Future<bool> requestBatteryExemption() async {
    if (!supported) return true;
    try {
      return await _channel.invokeMethod<bool>('requestBatteryExemption') ?? false;
    } on MissingPluginException {
      return true;
    } on PlatformException {
      return false;
    }
  }

  /// Asks for (or releases) sustained performance mode while the app is on
  /// screen. No effect on devices without it.
  static Future<void> sustainedPerformance(bool on) => _call('sustainedPerformance', {'on': on});

  /// The current thermal state, or null when unavailable.
  static Future<ThermalReading?> thermal() async {
    if (!supported) return null;
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('thermal');
      if (m == null) return null;
      return ThermalReading(
        status: (m['status'] as int?) ?? -1,
        headroom: ((m['headroom'] as num?) ?? -1).toDouble(),
        batteryC: ((m['batteryC'] as num?) ?? double.nan).toDouble(),
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static Future<void> _call(String method, [Map<String, Object?>? args]) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // Running without the Android host (tests, other embedders).
    } on PlatformException {
      // The service is best effort; mining itself runs in Dart.
    }
  }
}
