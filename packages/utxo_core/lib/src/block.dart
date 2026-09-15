import 'dart:typed_data';

import 'package:crypto_core/crypto_core.dart';

import 'bytes.dart';

/// An 80-byte block header.
class BlockHeader {
  final int version;
  final Uint8List prevHash; // internal byte order
  final Uint8List merkleRoot;
  final int time;
  final int bits;
  final int nonce;

  BlockHeader({
    required this.version,
    required this.prevHash,
    required this.merkleRoot,
    required this.time,
    required this.bits,
    required this.nonce,
  });

  factory BlockHeader.read(ByteReader r) => BlockHeader(
        version: r.i32(),
        prevHash: r.bytes(32),
        merkleRoot: r.bytes(32),
        time: r.u32(),
        bits: r.u32(),
        nonce: r.u32(),
      );

  factory BlockHeader.parse(Uint8List b) => BlockHeader.read(ByteReader(b));

  Uint8List serialize() {
    final w = ByteWriter()
      ..i32(version)
      ..bytes(prevHash)
      ..bytes(merkleRoot)
      ..u32(time)
      ..u32(bits)
      ..u32(nonce);
    return w.take();
  }

  /// Block id: double SHA-256 of the header (internal order).
  Uint8List get hash => sha256d(serialize());
  String get id => hashToHex(hash);

  BlockHeader withNonce(int n) =>
      BlockHeader(version: version, prevHash: prevHash, merkleRoot: merkleRoot, time: time, bits: bits, nonce: n);
}

class OutPoint {
  final Uint8List txid; // internal order
  final int index;
  const OutPoint(this.txid, this.index);

  bool get isNull => index == 0xffffffff && txid.every((b) => b == 0);
  String get key => '${hashToHex(txid)}:$index';
}

class TxIn {
  final OutPoint prevout;
  final Uint8List script;
  final int sequence;
  const TxIn(this.prevout, this.script, [this.sequence = 0xffffffff]);
}

class TxOut {
  final int value; // smallest units
  final Uint8List script;
  const TxOut(this.value, this.script);
}

/// A legacy (pre-SegWit) transaction.
class Transaction {
  final int version;
  final List<TxIn> inputs;
  final List<TxOut> outputs;
  final int lockTime;

  const Transaction({this.version = 1, required this.inputs, required this.outputs, this.lockTime = 0});

  factory Transaction.read(ByteReader r) {
    final version = r.i32();
    final inputs = [
      for (var i = r.varInt(); i > 0; i--) TxIn(OutPoint(r.bytes(32), r.u32()), r.varBytes(), r.u32()),
    ];
    final outputs = [for (var i = r.varInt(); i > 0; i--) TxOut(r.i64(), r.varBytes())];
    return Transaction(version: version, inputs: inputs, outputs: outputs, lockTime: r.u32());
  }

  factory Transaction.parse(Uint8List b) => Transaction.read(ByteReader(b));

  void write(ByteWriter w) {
    w.i32(version);
    w.varInt(inputs.length);
    for (final i in inputs) {
      w
        ..bytes(i.prevout.txid)
        ..u32(i.prevout.index)
        ..varBytes(i.script)
        ..u32(i.sequence);
    }
    w.varInt(outputs.length);
    for (final o in outputs) {
      w
        ..i64(o.value)
        ..varBytes(o.script);
    }
    w.u32(lockTime);
  }

  Uint8List serialize() {
    final w = ByteWriter();
    write(w);
    return w.take();
  }

  Uint8List get txid => sha256d(serialize());
  String get id => hashToHex(txid);
  bool get isCoinbase => inputs.length == 1 && inputs.first.prevout.isNull;
}

class Block {
  final BlockHeader header;
  final List<Transaction> transactions;
  const Block(this.header, this.transactions);

  factory Block.read(ByteReader r) {
    final header = BlockHeader.read(r);
    return Block(header, [for (var i = r.varInt(); i > 0; i--) Transaction.read(r)]);
  }

  Uint8List serialize() {
    final w = ByteWriter()..bytes(header.serialize());
    w.varInt(transactions.length);
    for (final t in transactions) {
      t.write(w);
    }
    return w.take();
  }
}

/// Merkle root of transaction ids (internal order), Bitcoin style
/// (the last hash is paired with itself on odd levels).
Uint8List merkleRoot(List<Uint8List> txids) {
  if (txids.isEmpty) return Uint8List(32);
  var level = txids;
  while (level.length > 1) {
    final next = <Uint8List>[];
    for (var i = 0; i < level.length; i += 2) {
      final a = level[i], b = i + 1 < level.length ? level[i + 1] : level[i];
      next.add(sha256d([...a, ...b]));
    }
    level = next;
  }
  return level.first;
}
