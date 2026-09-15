import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'base58check.dart';
import 'bip39_english.dart';
import 'mac.dart';
import 'secp256k1.dart';
import 'sha256.dart';

/// BIP39 mnemonics (English list).
abstract final class Bip39 {
  /// A new mnemonic of [words] words (12, 15, 18, 21 or 24) from a secure
  /// random source.
  static String generate({int words = 12, Random? random}) {
    final bytes = words * 4 ~/ 3;
    final rnd = random ?? Random.secure();
    return fromEntropy(List.generate(bytes, (_) => rnd.nextInt(256)));
  }

  static String fromEntropy(List<int> entropy) {
    if (entropy.length < 16 || entropy.length > 32 || entropy.length % 4 != 0) {
      throw ArgumentError('entropy must be 16 to 32 bytes, a multiple of 4');
    }
    final checksumBits = entropy.length * 8 ~/ 32;
    final hash = Sha256.hash(entropy);
    final bits = StringBuffer();
    for (final b in entropy) {
      bits.write(b.toRadixString(2).padLeft(8, '0'));
    }
    bits.write(hash[0].toRadixString(2).padLeft(8, '0').substring(0, checksumBits));
    final s = bits.toString();
    return [for (var i = 0; i < s.length; i += 11) bip39English[int.parse(s.substring(i, i + 11), radix: 2)]].join(' ');
  }

  /// The entropy, or null when a word is unknown or the checksum is wrong.
  static Uint8List? toEntropy(String mnemonic) {
    final words = mnemonic.trim().toLowerCase().split(RegExp(r'\s+'));
    if (words.length % 3 != 0 || words.length < 12 || words.length > 24) return null;
    final bits = StringBuffer();
    for (final w in words) {
      final i = bip39English.indexOf(w);
      if (i < 0) return null;
      bits.write(i.toRadixString(2).padLeft(11, '0'));
    }
    final s = bits.toString();
    final entBits = s.length * 32 ~/ 33;
    final entropy = Uint8List(entBits ~/ 8);
    for (var i = 0; i < entropy.length; i++) {
      entropy[i] = int.parse(s.substring(i * 8, i * 8 + 8), radix: 2);
    }
    final want = Sha256.hash(entropy)[0].toRadixString(2).padLeft(8, '0').substring(0, s.length - entBits);
    return want == s.substring(entBits) ? entropy : null;
  }

  static bool valid(String mnemonic) => toEntropy(mnemonic) != null;

  /// The 64-byte seed (PBKDF2-HMAC-SHA512, 2048 rounds).
  static Uint8List seed(String mnemonic, {String passphrase = ''}) => pbkdf2(
        HashFunction.sha512,
        utf8.encode(mnemonic.trim().split(RegExp(r'\s+')).join(' ')),
        utf8.encode('mnemonic$passphrase'),
        2048,
        64,
      );
}

/// A BIP32 extended key (private when [key] is set).
class HdKey {
  final BigInt? key;
  final EcPoint publicPoint;
  final Uint8List chainCode;
  final int depth;
  final int index;
  final int parentFingerprint;

  HdKey._(this.key, this.publicPoint, this.chainCode, this.depth, this.index, this.parentFingerprint);

  static const hardened = 0x80000000;

  factory HdKey.master(List<int> seed) {
    final i = hmacSha512(utf8.encode('Bitcoin seed'), seed);
    final k = bytesToBig(i.sublist(0, 32));
    if (!Secp256k1.validPrivateKey(k)) throw StateError('invalid master key');
    return HdKey._(k, Secp256k1.publicKey(k), i.sublist(32), 0, 0, 0);
  }

  bool get isPrivate => key != null;
  Uint8List get publicKey => publicPoint.encode();
  Uint8List get identifier => hash160(publicKey);
  int get fingerprint => ByteData.sublistView(identifier).getUint32(0);

  HdKey child(int i) {
    final hard = i >= hardened;
    if (hard && key == null) throw StateError('hardened child of a public key');
    final data = hard ? [0, ...bigToBytes(key!, 32)] : publicKey.toList();
    final idx = ByteData(4)..setUint32(0, i);
    final l = hmacSha512(chainCode, [...data, ...idx.buffer.asUint8List()]);
    final il = bytesToBig(l.sublist(0, 32));
    if (il >= Secp256k1.n) throw StateError('invalid child (retry the next index)');
    if (key != null) {
      final k = (il + key!) % Secp256k1.n;
      if (k == BigInt.zero) throw StateError('invalid child (retry the next index)');
      return HdKey._(k, Secp256k1.publicKey(k), l.sublist(32), depth + 1, i, fingerprint);
    }
    final pt = Secp256k1.add(Secp256k1.publicKey(il), publicPoint);
    return HdKey._(null, pt, l.sublist(32), depth + 1, i, fingerprint);
  }

  /// Derives a path such as `m/44'/111'/0'/0/0`.
  HdKey derive(String path) {
    var k = this;
    for (final part in path.split('/')) {
      if (part == 'm' || part.isEmpty) continue;
      final hard = part.endsWith("'") || part.endsWith('h');
      final n = int.parse(hard ? part.substring(0, part.length - 1) : part);
      k = k.child(hard ? n + hardened : n);
    }
    return k;
  }

  HdKey neutered() => HdKey._(null, publicPoint, chainCode, depth, index, parentFingerprint);

  /// Reads a key written by [serialize] (any version bytes); null when it
  /// is not a valid extended key.
  static HdKey? parse(String text) {
    final raw = base58CheckDecode(text);
    if (raw == null || raw.length != 78) return null;
    final b = ByteData.sublistView(raw);
    final chainCode = raw.sublist(13, 45);
    try {
      if (raw[45] == 0) {
        final k = bytesToBig(raw.sublist(46, 78));
        if (!Secp256k1.validPrivateKey(k)) return null;
        return HdKey._(k, Secp256k1.publicKey(k), chainCode, raw[4], b.getUint32(9), b.getUint32(5));
      }
      final pt = EcPoint.decode(raw.sublist(45, 78));
      if (pt == null) return null;
      return HdKey._(null, pt, chainCode, raw[4], b.getUint32(9), b.getUint32(5));
    } catch (_) {
      return null;
    }
  }

  /// xprv/xpub style serialization with the given 4-byte version.
  String serialize({int? version}) {
    final b = ByteData(78);
    b.setUint32(0, version ?? (isPrivate ? 0x0488ade4 : 0x0488b21e));
    b.setUint8(4, depth);
    b.setUint32(5, parentFingerprint);
    b.setUint32(9, index);
    final out = b.buffer.asUint8List();
    out.setRange(13, 45, chainCode);
    out.setRange(45, 78, isPrivate ? [0, ...bigToBytes(key!, 32)] : publicKey);
    return base58CheckEncode(out);
  }
}
