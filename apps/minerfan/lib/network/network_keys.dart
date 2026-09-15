import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto_core/crypto_core.dart' show KeyBox;
import 'package:hex/hex.dart';
import 'package:i2p/i2p.dart' show I2pIdentity;
import 'package:xprs_wire/xprs_wire.dart';

import '../wallets/device_key.dart';

/// This device's XPRS station: a secp256k1 key, shown as an npub and a
/// callsign (docs XPRS.md section 3), that signs and seals the packets it
/// sends to other clients.
class XprsStation {
  final String privateKeyHex;
  final String publicKeyHex;
  XprsStation(this.privateKeyHex) : publicKeyHex = NostrCrypto.derivePublicKey(privateKeyHex);

  BigInt get scalar => BigInt.parse(privateKeyHex, radix: 16);
  Uint8List get publicKey => Uint8List.fromList(HEX.decode(publicKeyHex));
  String get npub => NostrCrypto.encodeNpub(publicKeyHex);
  String get callsign => 'X1${NostrCrypto.deriveCallsign(publicKeyHex)}';
}

/// The two lasting identities of the private network, made on first use and
/// kept sealed with the device key (like wallets without a password):
/// `xprs/identity.key` (the station key) and `i2p/identity.key` (the I2P
/// destination and router seeds, so the `.b32.i2p` address stays the same).
///
/// File reads and curve math: load it off the UI isolate.
class NetworkKeys {
  final XprsStation station;
  final Uint8List i2p;
  final List<String> notes;
  NetworkKeys(this.station, this.i2p, this.notes);

  I2pIdentity get i2pIdentity => I2pIdentity.fromBytes(i2p)!;

  static NetworkKeys loadOrCreate(String dataDir) {
    final notes = <String>[];
    final key = DeviceKey.loadOrCreate(dataDir);
    final station = _sealed(dataDir, 'xprs/identity.key', key, notes, (b) => b.length == 32, () {
      return Uint8List.fromList(HEX.decode(NostrCrypto.generateKeyPair().privateKeyHex));
    });
    final i2p = _sealed(dataDir, 'i2p/identity.key', key, notes, (b) => I2pIdentity.fromBytes(b) != null,
        () => I2pIdentity.generate().toBytes());
    return NetworkKeys(XprsStation(HEX.encode(station)), i2p, notes);
  }

  /// The secret in [name], or a new one from [create] when there is none.
  /// A file this device cannot open is kept aside (`.unreadable`), never
  /// overwritten.
  static Uint8List _sealed(String dataDir, String name, Uint8List key, List<String> notes,
      bool Function(Uint8List) valid, Uint8List Function() create) {
    final f = File('$dataDir/$name');
    if (f.existsSync()) {
      try {
        final box = (jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>();
        final secret = KeyBox.open(key, box);
        if (secret != null && valid(secret)) return secret;
      } catch (_) {}
      final aside = '${f.path}.unreadable-${DateTime.now().millisecondsSinceEpoch}';
      f.renameSync(aside);
      notes.add('$name could not be opened with this device key; kept as $aside, made a new one');
    }
    final secret = create();
    f.parent.createSync(recursive: true);
    final tmp = File('${f.path}.${Random.secure().nextInt(1 << 30)}.tmp');
    tmp.writeAsStringSync(jsonEncode(KeyBox.seal(key, secret)), flush: true);
    if (Platform.isLinux || Platform.isMacOS) Process.runSync('chmod', ['600', tmp.path]);
    tmp.renameSync(f.path);
    notes.add('made a new $name');
    return secret;
  }
}
