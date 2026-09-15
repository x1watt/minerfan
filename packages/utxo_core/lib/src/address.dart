import 'dart:typed_data';

import 'package:crypto_core/crypto_core.dart';

import 'params.dart';

/// Script opcodes used by P2PKH and P2SH outputs.
abstract final class Op {
  static const dup = 0x76;
  static const hash160 = 0xa9;
  static const equal = 0x87;
  static const equalVerify = 0x88;
  static const checkSig = 0xac;
}

/// A decoded Base58Check address of a chain: pay to public key hash or to
/// script hash.
class Address {
  final bool isScript;
  final Uint8List hash; // 20 bytes

  const Address._(this.isScript, this.hash);

  factory Address.p2pkh(List<int> pubKeyHash) => Address._(false, Uint8List.fromList(pubKeyHash));

  /// Parses [text] for [params]; null when invalid or of another chain.
  static Address? parse(String text, ChainParams params) {
    final d = base58CheckDecode(text.trim());
    if (d == null || d.length != 21) return null;
    if (d[0] == params.pubKeyHashVersion) return Address._(false, d.sublist(1));
    if (d[0] == params.scriptHashVersion) return Address._(true, d.sublist(1));
    return null;
  }

  static Address fromPublicKey(List<int> publicKey) => Address.p2pkh(hash160(publicKey));

  String encode(ChainParams params) =>
      base58CheckEncode([isScript ? params.scriptHashVersion : params.pubKeyHashVersion, ...hash]);

  /// The output script that pays this address.
  Uint8List get script => isScript
      ? Uint8List.fromList([Op.hash160, 20, ...hash, Op.equal])
      : Uint8List.fromList([Op.dup, Op.hash160, 20, ...hash, Op.equalVerify, Op.checkSig]);

  /// The address an output script pays, when it is P2PKH or P2SH.
  static Address? fromScript(List<int> s) {
    if (s.length == 25 && s[0] == Op.dup && s[1] == Op.hash160 && s[2] == 20 && s[23] == Op.equalVerify && s[24] == Op.checkSig) {
      return Address._(false, Uint8List.fromList(s.sublist(3, 23)));
    }
    if (s.length == 23 && s[0] == Op.hash160 && s[1] == 20 && s[22] == Op.equal) {
      return Address._(true, Uint8List.fromList(s.sublist(2, 22)));
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is Address && other.isScript == isScript && _eq(other.hash, hash);
  @override
  int get hashCode => Object.hashAll(hash);
  static bool _eq(List<int> a, List<int> b) {
    for (var i = 0; i < 20; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// A private key in WIF (compressed-key flag honoured).
class WifKey {
  final BigInt key;
  final bool compressed;
  const WifKey(this.key, {this.compressed = true});

  static WifKey? parse(String text, ChainParams params) {
    final d = base58CheckDecode(text.trim());
    if (d == null || d[0] != params.wifVersion) return null;
    if (d.length == 33) return WifKey(bytesToBig(d.sublist(1)), compressed: false);
    if (d.length == 34 && d[33] == 1) return WifKey(bytesToBig(d.sublist(1, 33)));
    return null;
  }

  String encode(ChainParams params) =>
      base58CheckEncode([params.wifVersion, ...bigToBytes(key, 32), if (compressed) 1]);

  Uint8List get publicKey => Secp256k1.publicKey(key).encode(compressed: compressed);
}
