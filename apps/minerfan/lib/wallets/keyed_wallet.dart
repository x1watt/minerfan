import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto_core/crypto_core.dart';

import 'wallet.dart';

/// A wallet whose keys live on this device, sealed with the device key (no
/// password, the default) or with the user's password (Argon2id). The
/// sealed text is its backup: recovery words, or a view key.
abstract class KeyedWallet extends Wallet {
  Map<String, Object?> secret;

  /// The user confirmed writing the backup down.
  bool backedUp;

  /// Seals the secrets of wallets without a password (not saved with them).
  final Uint8List deviceKey;

  KeyedWallet({required this.secret, required this.deviceKey, this.backedUp = false});

  bool get hasPassword => secret['kdf'] != KeyBox.kdf;

  /// What the backup is called in the UI (recovery words, view key).
  String get backupName => 'recovery words';

  /// Seals [text] with [password], or with the device key when it is null.
  /// Argon2id takes up to a second, so this runs on a helper isolate.
  static Future<Map<String, Object?>> seal(String text, {String? password, required Uint8List deviceKey}) =>
      Isolate.run(() => password == null ? KeyBox.seal(deviceKey, utf8.encode(text)) : PasswordBox.seal(password, utf8.encode(text)));

  /// Opens a sealed box (call on a helper isolate).
  static String? open(Map<String, Object?> box, Uint8List deviceKey, String? password) {
    final b = box['kdf'] == KeyBox.kdf ? KeyBox.open(deviceKey, box) : PasswordBox.open(password ?? '', box);
    return b == null ? null : utf8.decode(b);
  }

  /// The sealed text, or null for a wrong password.
  Future<String?> recoveryPhrase([String? password]) {
    final box = secret, key = deviceKey;
    return Isolate.run(() => open(box, key, password));
  }

  /// Sets, changes or removes ([next] null) the password. False when
  /// [current] is wrong. The caller saves the wallet list.
  Future<bool> setPassword({String? current, String? next}) async {
    final box = secret, key = deviceKey;
    final resealed = await Isolate.run(() {
      final text = open(box, key, current);
      if (text == null) return null;
      final bytes = utf8.encode(text);
      return next == null ? KeyBox.seal(key, bytes) : PasswordBox.seal(next, bytes);
    });
    if (resealed == null) return false;
    secret = resealed;
    notifyListeners();
    return true;
  }
}
