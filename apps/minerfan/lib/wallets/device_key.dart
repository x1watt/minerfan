import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// A random 32-byte key in the app's data folder (`device.key`, readable by
/// the owner only) that seals the recovery phrases of wallets without a
/// password. It keeps phrases out of `wallets.json` in plain text; a
/// password (optional, per wallet) protects them from anyone who can read
/// the user's files.
abstract final class DeviceKey {
  static Uint8List loadOrCreate(String dataDir) {
    final f = File('$dataDir/device.key');
    try {
      if (f.existsSync()) {
        final b = f.readAsBytesSync();
        if (b.length == 32) return b;
      }
    } catch (_) {}
    final rnd = Random.secure();
    final key = Uint8List.fromList(List.generate(32, (_) => rnd.nextInt(256)));
    Directory(dataDir).createSync(recursive: true);
    // Created empty and restricted before the key is written.
    f.writeAsBytesSync(const []);
    if (Platform.isLinux || Platform.isMacOS) Process.runSync('chmod', ['600', f.path]);
    f.writeAsBytesSync(key, flush: true);
    return key;
  }
}
