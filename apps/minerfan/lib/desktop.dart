import 'dart:io';

import 'package:flutter/services.dart';

/// Desktop integration (Linux today): the dock launcher and icon, starting
/// with the computer, and the window channel of the GTK runner (the close
/// button only minimizes; quitting is explicit).
abstract final class Desktop {
  static const _window = MethodChannel('minerfan/window');
  static const appId = 'app.minerfan';

  static bool get supported => Platform.isLinux;

  static String get _home => Platform.environment['HOME'] ?? '';
  static String get _dataHome => Platform.environment['XDG_DATA_HOME'] ?? '$_home/.local/share';
  static String get _configHome => Platform.environment['XDG_CONFIG_HOME'] ?? '$_home/.config';

  static File get _launcher => File('$_dataHome/applications/$appId.desktop');
  static File get _autostart => File('$_configHome/autostart/$appId.desktop');
  static File get _icon => File('$_dataHome/icons/hicolor/scalable/apps/$appId.svg');

  static String _entry({required bool autostart}) {
    final exe = Platform.resolvedExecutable;
    return [
      '[Desktop Entry]',
      'Type=Application',
      'Name=minerfan',
      'Comment=Mines in idle time and keeps your wallets',
      'Exec="$exe"${autostart ? ' --minimized' : ''}',
      'Icon=$appId',
      'Terminal=false',
      'Categories=Utility;Finance;',
      'StartupWMClass=$appId',
      'StartupNotify=true',
      if (autostart) 'X-GNOME-Autostart-enabled=true',
      '',
    ].join('\n');
  }

  /// Installs (or refreshes) the launcher and the icon, so the dock and the
  /// app menu show minerfan, and writes or removes the autostart entry.
  static void integrate({required bool startWithComputer}) {
    if (!supported) return;
    try {
      final bundled = File('${File(Platform.resolvedExecutable).parent.path}/data/flutter_assets/assets/icon/minerfan.svg');
      if (bundled.existsSync()) {
        _icon.parent.createSync(recursive: true);
        if (!_icon.existsSync() || _icon.readAsStringSync() != bundled.readAsStringSync()) bundled.copySync(_icon.path);
      }
      _write(_launcher, _entry(autostart: false));
      setStartWithComputer(startWithComputer);
      // Entries from before the app id became app.minerfan.
      for (final f in [
        File('$_dataHome/applications/dev.xmrdart.xmr_miner.desktop'),
        File('$_configHome/autostart/dev.xmrdart.xmr_miner.desktop'),
        File('$_dataHome/icons/hicolor/scalable/apps/dev.xmrdart.xmr_miner.svg'),
      ]) {
        if (f.existsSync()) f.deleteSync();
      }
    } catch (_) {}
  }

  static void setStartWithComputer(bool on) {
    if (!supported) return;
    try {
      if (on) {
        _write(_autostart, _entry(autostart: true));
      } else if (_autostart.existsSync()) {
        _autostart.deleteSync();
      }
    } catch (_) {}
  }

  static void _write(File f, String content) {
    f.parent.createSync(recursive: true);
    if (!f.existsSync() || f.readAsStringSync() != content) f.writeAsStringSync(content);
  }

  /// Ends the app (the caller stops the miners first).
  static Future<void> quit() async {
    try {
      await _window.invokeMethod<void>('quit');
    } on MissingPluginException {
      exit(0);
    }
  }

  static Future<void> minimize() async {
    try {
      await _window.invokeMethod<void>('minimize');
    } on MissingPluginException {
      // Not the GTK runner.
    }
  }
}
