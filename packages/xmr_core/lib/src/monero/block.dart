import 'dart:typed_data';

import '../crypto/keccak.dart';
import '../util/bytes.dart';
import '../util/reader.dart';
import '../util/varint.dart';
import 'tree_hash.dart';

/// keccak([0x00]): hash of an RCTTypeNull base, part of every coinbase hash.
final Uint8List rctNullBaseHash = Keccak.hash256(const [0]);

/// One coinbase output.
class TxOutput {
  final int amount;
  final Uint8List key;

  /// Present for `txout_to_tagged_key` (type 3, view tags, since v15).
  final int? viewTag;

  const TxOutput(this.amount, this.key, [this.viewTag]);
}

/// A version-2 coinbase (miner) transaction as Monero serializes it.
class CoinbaseTx {
  final int version;
  final int unlockTime;
  final int genHeight;
  final List<TxOutput> outputs;
  final Uint8List extra;

  CoinbaseTx({
    this.version = 2,
    required this.unlockTime,
    required this.genHeight,
    required this.outputs,
    required this.extra,
  });

  static CoinbaseTx read(ByteReader r) {
    final version = r.varint();
    if (version != 2) throw FormatError('coinbase version $version');
    final unlockTime = r.varint();
    if (r.varint() != 1) throw FormatError('coinbase must have one input');
    if (r.byte() != 0xff) throw FormatError('coinbase input is not txin_gen');
    final height = r.varint();
    final n = r.varint();
    if (n > 20000) throw FormatError('too many outputs');
    final outs = <TxOutput>[];
    for (var i = 0; i < n; i++) {
      final amount = r.varint();
      final type = r.byte();
      if (type == 2) {
        outs.add(TxOutput(amount, r.bytes(32)));
      } else if (type == 3) {
        final key = r.bytes(32);
        outs.add(TxOutput(amount, key, r.byte()));
      } else {
        throw FormatError('unsupported output type $type');
      }
    }
    final extra = r.bytes(r.varint());
    if (r.byte() != 0) throw FormatError('coinbase rct type must be null');
    return CoinbaseTx(unlockTime: unlockTime, genHeight: height, outputs: outs, extra: extra);
  }

  void writePrefix(BytesBuilder b) {
    writeVarint(b, version);
    writeVarint(b, unlockTime);
    writeVarint(b, 1);
    b.addByte(0xff);
    writeVarint(b, genHeight);
    writeVarint(b, outputs.length);
    for (final o in outputs) {
      writeVarint(b, o.amount);
      if (o.viewTag != null) {
        b.addByte(3);
        b.add(o.key);
        b.addByte(o.viewTag!);
      } else {
        b.addByte(2);
        b.add(o.key);
      }
    }
    writeVarint(b, extra.length);
    b.add(extra);
  }

  void write(BytesBuilder b) {
    writePrefix(b);
    b.addByte(0); // RCTTypeNull
  }

  Uint8List serialize() {
    final b = BytesBuilder(copy: false);
    write(b);
    return b.takeBytes();
  }

  Uint8List prefixHash() {
    final b = BytesBuilder(copy: false);
    writePrefix(b);
    return Keccak.hash256(b.takeBytes());
  }

  /// Transaction id: H(H(prefix) || H(rct base) || H(prunable) = 0).
  Uint8List hash() => Keccak.hash256(concatBytes([prefixHash(), rctNullBaseHash, Uint8List(32)]));

  int get totalReward => outputs.fold(0, (s, o) => s + o.amount);
}

/// Monero block header.
class BlockHeader {
  final int majorVersion;
  final int minorVersion;
  final int timestamp;
  final Uint8List prevId;
  final int nonce;

  const BlockHeader(this.majorVersion, this.minorVersion, this.timestamp, this.prevId, this.nonce);

  static BlockHeader read(ByteReader r) {
    final major = r.varint();
    final minor = r.varint();
    final ts = r.varint();
    final prev = r.bytes(32);
    final nonce = r.u32();
    return BlockHeader(major, minor, ts, prev, nonce);
  }

  void write(BytesBuilder b) {
    writeVarint(b, majorVersion);
    writeVarint(b, minorVersion);
    writeVarint(b, timestamp);
    b.add(prevId);
    final n = Uint8List(4);
    writeU32LE(n, 0, nonce);
    b.add(n);
  }

  Uint8List serialize() {
    final b = BytesBuilder(copy: false);
    write(b);
    return b.takeBytes();
  }
}

/// A full Monero block (header, miner transaction, transaction hashes).
class MoneroBlock {
  final BlockHeader header;
  final CoinbaseTx minerTx;
  final List<Uint8List> txHashes;

  MoneroBlock(this.header, this.minerTx, this.txHashes);

  static MoneroBlock read(ByteReader r) {
    final h = BlockHeader.read(r);
    final tx = CoinbaseTx.read(r);
    final n = r.varint();
    if (n > 100000) throw FormatError('too many transactions');
    final hashes = [for (var i = 0; i < n; i++) r.bytes(32)];
    return MoneroBlock(h, tx, hashes);
  }

  static MoneroBlock parse(Uint8List data) {
    final r = ByteReader(data);
    final b = read(r);
    if (!r.isDone) throw FormatError('trailing bytes after block');
    return b;
  }

  Uint8List serialize() {
    final b = BytesBuilder(copy: false);
    header.write(b);
    minerTx.write(b);
    writeVarint(b, txHashes.length);
    for (final h in txHashes) {
      b.add(h);
    }
    return b.takeBytes();
  }

  int get height => minerTx.genHeight;

  Uint8List merkleRoot() => treeHash([minerTx.hash(), ...txHashes]);

  /// The blob that is hashed with RandomX (v16 layout).
  Uint8List hashingBlob() {
    final b = BytesBuilder(copy: false);
    header.write(b);
    b.add(merkleRoot());
    writeVarint(b, txHashes.length + 1);
    return b.takeBytes();
  }

  /// Block id: keccak(varint(len(hashing blob)) || hashing blob).
  Uint8List id() {
    final blob = hashingBlob();
    return Keccak.hash256(concatBytes([encodeVarint(blob.length), blob]));
  }
}
