import 'dart:typed_data';

import '../crypto/keccak.dart';
import '../util/reader.dart';
import '../util/varint.dart';

/// Monero transactions (src/cryptonote_basic/cryptonote_basic.h and
/// src/ringct/rctTypes.h, BSD-3): the prefix, the RingCT base and, when
/// present, the prunable part (Bulletproofs+, CLSAGs, pseudo outputs).

sealed class TxInput {}

/// Coinbase input.
class TxInGen extends TxInput {
  final int height;
  TxInGen(this.height);
}

/// A ring input: relative global indices of the ring members and the key
/// image of the real one.
class TxInToKey extends TxInput {
  final int amount;
  final List<int> keyOffsets;
  final Uint8List keyImage;
  TxInToKey(this.amount, this.keyOffsets, this.keyImage);

  /// Absolute global output indices of the ring.
  List<int> get ringIndices {
    var acc = 0;
    return [for (final o in keyOffsets) acc += o];
  }
}

class TxOut {
  final int amount;
  final Uint8List key;
  final int? viewTag;
  TxOut(this.amount, this.key, [this.viewTag]);
}

class BulletproofPlus {
  final Uint8List a, a1, b, r1, s1, d1;
  final List<Uint8List> l, r;
  BulletproofPlus(this.a, this.a1, this.b, this.r1, this.s1, this.d1, this.l, this.r);
}

class Clsag {
  final List<Uint8List> s;
  final Uint8List c1, d;
  Clsag(this.s, this.c1, this.d);
}

class RctTypes {
  static const nullType = 0, clsag = 5, bulletproofPlus = 6;
}

class MoneroTx {
  final int version;
  final int unlockTime;
  final List<TxInput> inputs;
  final List<TxOut> outputs;
  final Uint8List extra;

  final int rctType;
  final int fee;

  /// 8-byte encrypted amounts (compact ECDH, RingCT types 4 to 6).
  final List<Uint8List> ecdhAmounts;

  /// Output commitments.
  final List<Uint8List> outPk;

  /// Prunable part, null for a pruned transaction or a coinbase.
  final List<BulletproofPlus>? bulletproofsPlus;
  final List<Clsag>? clsags;
  final List<Uint8List>? pseudoOuts;

  /// Keccak of the prunable part (given with pruned blobs).
  final Uint8List? prunableHash;

  /// Byte ranges of the parts, for hashing.
  final Uint8List prefixBytes;
  final Uint8List baseBytes;
  final Uint8List? prunableBytes;

  MoneroTx._(this.version, this.unlockTime, this.inputs, this.outputs, this.extra, this.rctType, this.fee,
      this.ecdhAmounts, this.outPk, this.bulletproofsPlus, this.clsags, this.pseudoOuts, this.prunableHash,
      this.prefixBytes, this.baseBytes, this.prunableBytes);

  bool get isCoinbase => inputs.length == 1 && inputs.first is TxInGen;

  /// Parses a transaction blob. With [pruned] the blob stops after the
  /// RingCT base and [prunableHash] (from the peer) completes the hash.
  static MoneroTx parse(Uint8List blob, {bool pruned = false, Uint8List? prunableHash}) {
    final r = ByteReader(blob);
    final version = r.varint();
    final unlockTime = r.varint();
    final inputs = <TxInput>[];
    for (var i = r.varint(); i > 0; i--) {
      final tag = r.byte();
      if (tag == 0xff) {
        inputs.add(TxInGen(r.varint()));
      } else if (tag == 0x02) {
        final amount = r.varint();
        final n = r.varint();
        if (n > 1024) throw FormatError('ring too large');
        final offsets = [for (var k = 0; k < n; k++) r.varint()];
        inputs.add(TxInToKey(amount, offsets, r.bytes(32)));
      } else {
        throw FormatError('unsupported input type $tag');
      }
    }
    final outputs = <TxOut>[];
    for (var i = r.varint(); i > 0; i--) {
      final amount = r.varint();
      final tag = r.byte();
      if (tag == 0x02) {
        outputs.add(TxOut(amount, r.bytes(32)));
      } else if (tag == 0x03) {
        outputs.add(TxOut(amount, r.bytes(32), r.byte()));
      } else {
        throw FormatError('unsupported output type $tag');
      }
    }
    final extra = r.bytes(r.varint());
    final prefixEnd = r.pos;
    var rctType = 0, fee = 0;
    final ecdh = <Uint8List>[], outPk = <Uint8List>[];
    List<BulletproofPlus>? bpp;
    List<Clsag>? clsags;
    List<Uint8List>? pseudo;
    var baseEnd = prefixEnd;
    Uint8List? prunableBytes;
    if (version >= 2) {
      rctType = r.byte();
      if (rctType != RctTypes.nullType) {
        if (rctType < 4 || rctType > 6) throw FormatError('unsupported RingCT type $rctType');
        fee = r.varint();
        for (var i = 0; i < outputs.length; i++) {
          ecdh.add(r.bytes(8));
        }
        for (var i = 0; i < outputs.length; i++) {
          outPk.add(r.bytes(32));
        }
      }
      baseEnd = r.pos;
      if (!pruned && rctType == RctTypes.bulletproofPlus) {
        final nbp = r.varint();
        if (nbp > outputs.length) throw FormatError('too many range proofs');
        bpp = [];
        for (var i = 0; i < nbp; i++) {
          final a = r.bytes(32), a1 = r.bytes(32), b = r.bytes(32);
          final r1 = r.bytes(32), s1 = r.bytes(32), d1 = r.bytes(32);
          final nl = r.varint();
          if (nl > 64) throw FormatError('bad range proof');
          final l = [for (var k = 0; k < nl; k++) r.bytes(32)];
          final nr = r.varint();
          if (nr != nl) throw FormatError('bad range proof');
          final rr = [for (var k = 0; k < nr; k++) r.bytes(32)];
          bpp.add(BulletproofPlus(a, a1, b, r1, s1, d1, l, rr));
        }
        clsags = [];
        for (final input in inputs) {
          final ring = (input as TxInToKey).keyOffsets.length;
          clsags.add(Clsag([for (var k = 0; k < ring; k++) r.bytes(32)], r.bytes(32), r.bytes(32)));
        }
        pseudo = [for (var i = 0; i < inputs.length; i++) r.bytes(32)];
        prunableBytes = Uint8List.sublistView(blob, baseEnd, r.pos);
      }
    }
    return MoneroTx._(
      version,
      unlockTime,
      inputs,
      outputs,
      extra,
      rctType,
      fee,
      ecdh,
      outPk,
      bpp,
      clsags,
      pseudo,
      prunableHash,
      Uint8List.sublistView(blob, 0, prefixEnd),
      Uint8List.sublistView(blob, prefixEnd, baseEnd),
      prunableBytes,
    );
  }

  Uint8List get prefixHash => Keccak.hash256(prefixBytes);

  /// The transaction id: for version 2, Keccak(H(prefix) || H(base) ||
  /// H(prunable)), with zeros for the prunable hash of a coinbase.
  Uint8List get hash {
    if (version == 1) return Keccak.hash256([...prefixBytes, ...baseBytes]);
    final ph = rctType == RctTypes.nullType
        ? Uint8List(32)
        : (prunableBytes != null ? Keccak.hash256(prunableBytes!) : prunableHash ?? (throw StateError('pruned tx without prunable hash')));
    return Keccak.hash256([...prefixHash, ...Keccak.hash256(baseBytes), ...ph]);
  }

  /// What the CLSAGs sign (`get_pre_mlsag_hash`): Keccak(prefix hash ||
  /// H(RingCT base) || H(range proof keys)).
  Uint8List get clsagMessage => clsagMessageFor(prefixHash, baseBytes, bulletproofsPlus!.single);

  static Uint8List clsagMessageFor(Uint8List prefixHash, Uint8List baseBytes, BulletproofPlus p) {
    final kv = [...p.a, ...p.a1, ...p.b, ...p.r1, ...p.s1, ...p.d1, for (final x in p.l) ...x, for (final x in p.r) ...x];
    return Keccak.hash256([...prefixHash, ...Keccak.hash256(baseBytes), ...Keccak.hash256(kv)]);
  }

  /// Transaction public key (extra tag 1) and additional keys (tag 4).
  (Uint8List?, List<Uint8List>) get txPublicKeys => parseExtraKeys(extra);
}

/// Reads the public keys from tx extra, tolerating unknown trailing data.
(Uint8List?, List<Uint8List>) parseExtraKeys(Uint8List extra) {
  Uint8List? main;
  final additional = <Uint8List>[];
  final r = ByteReader(extra);
  try {
    while (!r.isDone) {
      final tag = r.byte();
      switch (tag) {
        case 0x00:
          return (main, additional); // padding to the end
        case 0x01:
          final k = r.bytes(32);
          main ??= k;
        case 0x02:
          r.bytes(r.byte());
        case 0x03:
          r.bytes(r.varint());
        case 0x04:
          final n = r.varint();
          for (var i = 0; i < n; i++) {
            additional.add(r.bytes(32));
          }
        case 0xde:
          r.bytes(r.varint());
        default:
          return (main, additional);
      }
    }
  } on FormatError {
    // keep what was read
  }
  return (main, additional);
}

/// Writes a transaction: prefix, RingCT base and prunable part (type 6).
class TxWriter {
  static Uint8List prefix({
    required int unlockTime,
    required List<TxInToKey> inputs,
    required List<TxOut> outputs,
    required Uint8List extra,
  }) {
    final b = BytesBuilder(copy: false);
    writeVarint(b, 2);
    writeVarint(b, unlockTime);
    writeVarint(b, inputs.length);
    for (final i in inputs) {
      b.addByte(0x02);
      writeVarint(b, i.amount);
      writeVarint(b, i.keyOffsets.length);
      for (final o in i.keyOffsets) {
        writeVarint(b, o);
      }
      b.add(i.keyImage);
    }
    writeVarint(b, outputs.length);
    for (final o in outputs) {
      writeVarint(b, o.amount);
      if (o.viewTag != null) {
        b.addByte(0x03);
        b.add(o.key);
        b.addByte(o.viewTag!);
      } else {
        b.addByte(0x02);
        b.add(o.key);
      }
    }
    writeVarint(b, extra.length);
    b.add(extra);
    return b.takeBytes();
  }

  static Uint8List base({required int fee, required List<Uint8List> ecdhAmounts, required List<Uint8List> outPk}) {
    final b = BytesBuilder(copy: false);
    b.addByte(RctTypes.bulletproofPlus);
    writeVarint(b, fee);
    ecdhAmounts.forEach(b.add);
    outPk.forEach(b.add);
    return b.takeBytes();
  }

  static Uint8List bulletproofPlus(BulletproofPlus p) {
    final b = BytesBuilder(copy: false)
      ..add(p.a)
      ..add(p.a1)
      ..add(p.b)
      ..add(p.r1)
      ..add(p.s1)
      ..add(p.d1);
    writeVarint(b, p.l.length);
    p.l.forEach(b.add);
    writeVarint(b, p.r.length);
    p.r.forEach(b.add);
    return b.takeBytes();
  }

  static Uint8List prunable({required BulletproofPlus proof, required List<Clsag> clsags, required List<Uint8List> pseudoOuts}) {
    final b = BytesBuilder(copy: false);
    writeVarint(b, 1);
    b.add(bulletproofPlus(proof));
    for (final c in clsags) {
      c.s.forEach(b.add);
      b.add(c.c1);
      b.add(c.d);
    }
    pseudoOuts.forEach(b.add);
    return b.takeBytes();
  }
}
