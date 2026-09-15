import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../monero/light_chain.dart';
import '../util/bytes.dart';

/// A payout received from a P2Pool-found Monero block.
class Payout {
  final int moneroHeight;
  final int timestamp;
  final int amount; // atomic units (1e-12 XMR)
  final String blockId;
  const Payout(this.moneroHeight, this.timestamp, this.amount, this.blockId);

  Map<String, Object?> toJson() => {'h': moneroHeight, 't': timestamp, 'a': amount, 'id': blockId};
  static Payout fromJson(Map<String, Object?> m) =>
      Payout(m['h']! as int, m['t']! as int, m['a']! as int, m['id']! as String);
}

/// A share this node found.
class FoundShare {
  final int sideHeight;
  final int moneroHeight;
  final int timestamp;
  final String templateId;
  const FoundShare(this.sideHeight, this.moneroHeight, this.timestamp, this.templateId);

  Map<String, Object?> toJson() => {'s': sideHeight, 'h': moneroHeight, 't': timestamp, 'id': templateId};
  static FoundShare fromJson(Map<String, Object?> m) =>
      FoundShare(m['s']! as int, m['h']! as int, m['t']! as int, m['id']! as String);
}

/// Node state on disk: the Monero header window, known peers, payouts and
/// found shares. Everything is optional; a missing or corrupt file just
/// means starting from the built-in checkpoint.
class NodeStore {
  final Directory dir;
  NodeStore(String path) : dir = Directory(path) {
    dir.createSync(recursive: true);
  }

  File _f(String name) => File('${dir.path}/$name');

  void saveChain(MoneroLightChain chain) {
    final hs = chain.export();
    final b = BytesBuilder(copy: false);
    for (final h in hs) {
      final row = Uint8List(8 + 32 + 8 + 16 + 16 + 1 + 1);
      writeU64LE(row, 0, h.height);
      row.setRange(8, 40, h.id);
      writeU64LE(row, 40, h.timestamp);
      _write128(row, 48, h.cumulativeDifficulty);
      _write128(row, 64, h.difficulty);
      row[80] = h.majorVersion;
      row[81] = h.powVerified ? 1 : 0;
      b.add(row);
    }
    _atomicWrite('monero_chain.bin', b.takeBytes());
  }

  MoneroLightChain? loadChain() {
    try {
      final data = _f('monero_chain.bin').readAsBytesSync();
      const rowLen = 82;
      if (data.isEmpty || data.length % rowLen != 0) return null;
      final hs = <LightHeader>[];
      for (var o = 0; o < data.length; o += rowLen) {
        hs.add(LightHeader(
          readU64LE(data, o),
          Uint8List.fromList(data.sublist(o + 8, o + 40)),
          readU64LE(data, o + 40),
          _read128(data, o + 48),
          _read128(data, o + 64),
          data[o + 80],
          powVerified: data[o + 81] == 1,
        ));
      }
      for (var i = 1; i < hs.length; i++) {
        if (hs[i].height != hs[i - 1].height + 1) return null;
      }
      return hs.length >= 735 ? MoneroLightChain.restore(hs) : null;
    } catch (_) {
      return null;
    }
  }

  static final BigInt _m64 = (BigInt.one << 64) - BigInt.one;
  static void _write128(Uint8List b, int o, BigInt v) {
    writeU64LE(b, o, (v & _m64).toSigned(64).toInt());
    writeU64LE(b, o + 8, ((v >> 64) & _m64).toSigned(64).toInt());
  }

  static BigInt _read128(Uint8List b, int o) =>
      (BigInt.from(readU64LE(b, o + 8)).toUnsigned(64) << 64) | BigInt.from(readU64LE(b, o)).toUnsigned(64);

  List<(String, int)> loadPeers(String name) {
    try {
      return [
        for (final l in _f(name).readAsLinesSync())
          if (l.contains(':')) (l.substring(0, l.lastIndexOf(':')), int.parse(l.substring(l.lastIndexOf(':') + 1)))
      ];
    } catch (_) {
      return const [];
    }
  }

  void savePeers(String name, Iterable<(String, int)> peers) =>
      _atomicWrite(name, utf8.encode(peers.take(500).map((p) => '${p.$1}:${p.$2}').join('\n')));

  /// Verified shares, so a restart does not fetch the whole window again.
  void saveShareCache(String name, Iterable<Uint8List> blobs) {
    final b = BytesBuilder(copy: false);
    final len = Uint8List(4);
    for (final blob in blobs) {
      writeU32LE(len, 0, blob.length);
      b.add(Uint8List.fromList(len));
      b.add(blob);
    }
    _atomicWrite(name, b.takeBytes());
  }

  List<Uint8List> loadShareCache(String name) {
    try {
      final data = _f(name).readAsBytesSync();
      final out = <Uint8List>[];
      var o = 0;
      while (o + 4 <= data.length) {
        final n = readU32LE(data, o);
        o += 4;
        if (o + n > data.length) break;
        out.add(Uint8List.sublistView(data, o, o + n));
        o += n;
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  void remove(String name) {
    try {
      final f = _f(name);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  List<Payout> loadPayouts() => _loadList('payouts.json', Payout.fromJson);
  void savePayouts(List<Payout> p) => _atomicWrite('payouts.json', utf8.encode(jsonEncode([for (final x in p) x.toJson()])));

  List<FoundShare> loadShares() => _loadList('shares.json', FoundShare.fromJson);
  void saveShares(List<FoundShare> s) =>
      _atomicWrite('shares.json', utf8.encode(jsonEncode([for (final x in s.length > 1000 ? s.sublist(s.length - 1000) : s) x.toJson()])));

  List<T> _loadList<T>(String name, T Function(Map<String, Object?>) f) {
    try {
      return [for (final e in jsonDecode(_f(name).readAsStringSync()) as List) f(e as Map<String, Object?>)];
    } catch (_) {
      return [];
    }
  }

  void _atomicWrite(String name, List<int> bytes) {
    final tmp = _f('$name.tmp');
    tmp.writeAsBytesSync(bytes, flush: true);
    tmp.renameSync(_f(name).path);
  }
}
