import 'dart:convert';
import 'dart:io';

import 'package:xprs_wire/xprs_wire.dart';

import '../wallets/device_key.dart' show ownerOnly;

/// Who runs the coin rooms' moderation (docs/architecture.md, "Coin
/// rooms"): the admin's station key, which grants the bought moderator
/// terms, and the address each room's rights are bought with.
///
/// The three are built into the app, and the same three are kept in a small
/// file of the user's profile (`~/.config/minerfan/rooms.json`, outside the
/// app's data folder and outside the repo), written on the first start. A
/// file that is there wins, so a device keeps working with the settings it
/// was given even after the app is replaced, and a test can point somewhere
/// else with `MINERFAN_ROOMS`.
///
/// They can also be set at build time:
///   flutter build ... --dart-define=ROOM_ADMIN_NPUB=npub1...
///     --dart-define=MOD_ADDR_MONERO=4... --dart-define=MOD_ADDR_CRYPTOESCUDO=C...
/// While the admin or a room's address is empty, that room has no moderation.
abstract final class ModerationConfig {
  /// The rooms' admin: X1WATT.
  static const builtInAdminNpub = String.fromEnvironment('ROOM_ADMIN_NPUB',
      defaultValue: 'npub1watt585dqju7agda06973etnhyad6n9l6wy2heamr0mxw0nmgl5sdrsnac');

  static const builtInAddresses = {
    'monero': String.fromEnvironment('MOD_ADDR_MONERO',
        defaultValue: '45GVTQ9WkX5UuDXW48EhPxgTYtrj4az7qjR1HqLh8VGHFHhS9A4unxTdruLGHpJCWZ44Q9yhtDnLLXR7T2ZgbhhTK48Yjji'),
    'cryptoescudo':
        String.fromEnvironment('MOD_ADDR_CRYPTOESCUDO', defaultValue: 'CSqd18riXQjBy6vUNcnfi7kwHS7fDGUFE2'),
  };

  /// How long a claim is kept and resent before it is given up.
  static const claimLife = Duration(hours: 48);

  static String _adminNpub = builtInAdminNpub;
  static Map<String, String> _addresses = Map.of(builtInAddresses);

  static String _keyOf = '';
  static String? _keyHex;

  /// The admin's x-only key, from the npub in use.
  static String? get adminKeyHex {
    if (_keyOf != _adminNpub) {
      _keyOf = _adminNpub;
      try {
        _keyHex = _adminNpub.isEmpty ? null : NostrCrypto.decodeNpub(_adminNpub);
      } catch (_) {
        _keyHex = null;
      }
    }
    return _keyHex;
  }

  static String get adminNpub => _adminNpub;

  static String? get adminCallsign => adminKeyHex == null ? null : 'X1${NostrCrypto.deriveCallsign(adminKeyHex!)}';

  /// Where [coinId]'s room rights are bought, or null.
  static String? address(String coinId) {
    final a = _addresses[coinId] ?? '';
    return a.isEmpty ? null : a;
  }

  static bool on(String coinId) => adminKeyHex != null && address(coinId) != null;

  /// What a payment's proof signs: the room and the buyer's callsign, then
  /// the txid (so the proof speaks for that buyer and payment only).
  static String claimMessage(String room, String callsign) => 'minerfan moderator claim|$room|$callsign|';

  /// The file that keeps these settings in the user's profile.
  static String profilePath() {
    final env = Platform.environment;
    final set = env['MINERFAN_ROOMS'];
    if (set != null && set.isNotEmpty) return set;
    final home = env['HOME'] ?? '';
    if (Platform.isWindows) return '${env['APPDATA'] ?? home}\\minerfan\\rooms.json';
    if (Platform.isMacOS) return '$home/Library/Application Support/minerfan/rooms.json';
    return '${env['XDG_CONFIG_HOME'] ?? '$home/.config'}/minerfan/rooms.json';
  }

  /// Reads the profile file (what is in it wins) and writes it when it is
  /// not there yet, so the settings outlive any one copy of the app.
  /// Returns a line for the log, or null when nothing happened.
  ///
  /// File work: call it off the UI isolate, or early at startup.
  static Future<String?> loadProfile({String? path}) async {
    final f = File(path ?? profilePath());
    try {
      if (await f.exists()) {
        final m = (jsonDecode(await f.readAsString()) as Map).cast<String, Object?>();
        final npub = '${m['adminNpub'] ?? ''}'.trim();
        final addresses = (m['addresses'] as Map?)?.cast<String, Object?>() ?? const {};
        final read = <String, String>{
          for (final e in addresses.entries)
            if ('${e.value}'.trim().isNotEmpty) e.key: '${e.value}'.trim(),
        };
        if (npub.isNotEmpty) _adminNpub = npub;
        if (read.isNotEmpty) _addresses = {..._addresses, ...read};
        return 'rooms: settings read from ${f.path}';
      }
      await f.parent.create(recursive: true);
      await f.writeAsString(const JsonEncoder.withIndent('  ').convert({
        'adminNpub': _adminNpub,
        'addresses': _addresses,
      }));
      ownerOnly(f.path);
      return 'rooms: settings kept in ${f.path}';
    } catch (e) {
      return 'rooms: could not use ${f.path}: $e';
    }
  }

  /// Back to what the app was built with (tests).
  static void resetToBuiltIn() {
    _adminNpub = builtInAdminNpub;
    _addresses = Map.of(builtInAddresses);
  }
}
