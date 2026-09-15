import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../crypto/ec_ops.dart';
import '../crypto/ed25519.dart';
import '../crypto/keccak.dart';
import '../monero/address.dart';
import '../util/bytes.dart';
import 'english_words.g.dart';

/// Monero's 25-word mnemonic (src/mnemonics/electrum-words.cpp, BSD-3):
/// every 4 bytes of the 32-byte seed become 3 words of the 1626-word list,
/// and a 25th word repeats the word the CRC32 of the 3-letter prefixes
/// picks.
abstract final class MoneroMnemonic {
  static const _n = 1626;
  static const _prefix = 3;
  static final Map<String, int> _index = {for (var i = 0; i < _n; i++) moneroEnglishWords[i]: i};
  static final Map<String, int> _byPrefix = {
    for (var i = 0; i < _n; i++) _cut(moneroEnglishWords[i]): i,
  };

  static String _cut(String w) => w.length > _prefix ? w.substring(0, _prefix) : w;

  static String fromSeed(List<int> seed) {
    if (seed.length != 32) throw ArgumentError('the seed has 32 bytes');
    final d = ByteData.sublistView(Uint8List.fromList(seed));
    final words = <String>[];
    for (var i = 0; i < 8; i++) {
      final x = d.getUint32(i * 4, Endian.little);
      final w1 = x % _n;
      final w2 = (x ~/ _n + w1) % _n;
      final w3 = (x ~/ _n ~/ _n + w2) % _n;
      words.addAll([moneroEnglishWords[w1], moneroEnglishWords[w2], moneroEnglishWords[w3]]);
    }
    words.add(words[_checksumIndex(words)]);
    return words.join(' ');
  }

  static int _checksumIndex(List<String> words) => _crc32(utf8.encode(words.map(_cut).join())) % words.length;

  /// The seed of a 25-word (or 24-word, no checksum) phrase, or null when
  /// a word is unknown or the checksum word is wrong. Words may be given
  /// by their first 3 letters, as in Monero.
  static Uint8List? toSeed(String phrase) {
    final words = phrase.trim().toLowerCase().split(RegExp(r'\s+'));
    if (words.length != 24 && words.length != 25) return null;
    final idx = <int>[];
    for (final w in words.take(24)) {
      final i = _index[w] ?? _byPrefix[_cut(w)];
      if (i == null) return null;
      idx.add(i);
    }
    if (words.length == 25) {
      final full = [for (final i in idx) moneroEnglishWords[i]];
      if (_cut(full[_checksumIndex(full)]) != _cut(words[24])) return null;
    }
    final out = ByteData(32);
    for (var i = 0; i < 8; i++) {
      final w1 = idx[i * 3], w2 = idx[i * 3 + 1], w3 = idx[i * 3 + 2];
      final x = w1 + _n * ((_n - w1 + w2) % _n) + _n * _n * ((_n - w2 + w3) % _n);
      if (x % _n != w1 || x >= 1 << 32) return null;
      out.setUint32(i * 4, x, Endian.little);
    }
    return out.buffer.asUint8List();
  }

  static final List<int> _crcTable = List.generate(256, (n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    return c;
  });

  static int _crc32(List<int> data) {
    var c = 0xffffffff;
    for (final b in data) {
      c = _crcTable[(c ^ b) & 0xff] ^ (c >>> 8);
    }
    return (c ^ 0xffffffff) & 0xffffffff;
  }
}

/// A Monero account: the secret spend and view keys and what follows from
/// them (addresses, subaddresses). A view-only account has no spend key.
class MoneroAccount {
  final MoneroNetwork network;
  final Uint8List? spendSecret;
  final Uint8List viewSecret;
  final Uint8List spendPublic;
  final Uint8List viewPublic;

  MoneroAccount._(this.network, this.spendSecret, this.viewSecret, this.spendPublic, this.viewPublic);

  /// From the 32-byte seed of a mnemonic: spend = seed mod l, view =
  /// Keccak(spend) mod l.
  factory MoneroAccount.fromSeed(List<int> seed, {MoneroNetwork network = MoneroNetwork.mainnet}) {
    final spend = scReduce32(seed);
    final view = scReduce32(Keccak.hash256(spend));
    return MoneroAccount._(network, spend, view, scalarMultBase(spend).encode(), scalarMultBase(view).encode());
  }

  /// A new account from 32 secure random bytes; returns it with its seed.
  static (MoneroAccount, Uint8List) generate({MoneroNetwork network = MoneroNetwork.mainnet}) {
    final rnd = Random.secure();
    final seed = scReduce32(List.generate(32, (_) => rnd.nextInt(256)));
    return (MoneroAccount.fromSeed(seed, network: network), seed);
  }

  /// View-only: the address and its private view key. Null when the key
  /// does not match the address.
  static MoneroAccount? viewOnly(MoneroAddress address, List<int> viewSecret) {
    if (!scCheck(viewSecret) || address.kind != AddressKind.standard) return null;
    final v = Uint8List.fromList(viewSecret);
    if (!bytesEqual(scalarMultBase(v).encode(), address.viewKey)) return null;
    return MoneroAccount._(address.network, null, v, address.spendKey, address.viewKey);
  }

  bool get canSpend => spendSecret != null;

  MoneroAddress get address => MoneroAddress(network, AddressKind.standard, spendPublic, viewPublic);

  static final List<int> _subAddrSalt = [...utf8.encode('SubAddr'), 0];

  /// m = Hs("SubAddr\0" || a || major || minor), the subaddress offset.
  Uint8List subaddressScalar(int major, int minor) {
    final idx = ByteData(8)
      ..setUint32(0, major, Endian.little)
      ..setUint32(4, minor, Endian.little);
    return hashToScalarBytes([..._subAddrSalt, ...viewSecret, ...idx.buffer.asUint8List()]);
  }

  /// Subaddress (major, minor): D = B + mG, C = aD. (0, 0) is the main
  /// address.
  MoneroAddress subaddress(int major, int minor) {
    if (major == 0 && minor == 0) return address;
    final d = pointSum(decodePoint(spendPublic), scalarMultBase(subaddressScalar(major, minor)));
    final c = scalarMult(viewSecret, d);
    return MoneroAddress(network, AddressKind.subaddress, d.encode(), c.encode());
  }

  /// Spend public key of each subaddress up to [minors] in account 0, for
  /// matching outputs (D -> (major, minor)).
  Map<String, (int, int)> subaddressTable({int majors = 1, int minors = 50}) => {
        for (var a = 0; a < majors; a++)
          for (var i = 0; i < minors; i++) toHex(subaddress(a, i).spendKey): (a, i),
      };
}
