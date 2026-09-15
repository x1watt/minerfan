import 'dart:typed_data';

import 'address.dart';
import 'block.dart';
import 'bytes.dart';
import 'header_chain.dart';
import 'params.dart';

/// A block to mine on top of the chain's tip: a coinbase-only block paying
/// [payTo]. Leaving out mempool transactions is valid and forgoes their
/// fees; the node relays nothing it cannot check.
class BlockTemplate {
  final int height;
  final Transaction coinbase;
  final BlockHeader header; // nonce 0

  const BlockTemplate(this.height, this.coinbase, this.header);

  Block withNonce(int nonce) => Block(header.withNonce(nonce), [coinbase]);

  /// Builds the template. [extraNonce] makes each template unique (a
  /// different merkle root, so a fresh nonce space); [tag] goes into the
  /// coinbase script after the height.
  factory BlockTemplate.build({
    required ChainParams params,
    required HeaderChain chain,
    required Address payTo,
    required int extraNonce,
    String tag = '/minerfan/',
    int? nowSeconds,
  }) {
    final height = chain.tipHeight + 1;
    final script = ByteWriter();
    if (params.bip34) script.bytes(scriptNumPush(height));
    script
      ..u8(8)
      ..u64(extraNonce)
      ..varBytes(tag.codeUnits.take(40).toList());
    final coinbase = Transaction(
      inputs: [TxIn(OutPoint(Uint8List(32), 0xffffffff), script.take())],
      outputs: [TxOut(params.subsidy(height), payTo.script)],
    );
    final now = nowSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final mtp = _medianTimePast(chain);
    final header = BlockHeader(
      version: params.blockVersion,
      prevHash: chain.tipHash,
      merkleRoot: merkleRoot([coinbase.txid]),
      time: now > mtp ? now : mtp + 1,
      bits: params.retarget.next(chain, chain.tipHeight),
      nonce: 0,
    );
    return BlockTemplate(height, coinbase, header);
  }

  static int _medianTimePast(HeaderChain c) {
    final ts = <int>[for (var h = c.tipHeight; h > c.tipHeight - 11 && h >= c.firstHeight; h--) c.timeAt(h)]..sort();
    return ts[ts.length ~/ 2];
  }
}

/// `CScript() << n` for a block height: a minimal little-endian number
/// push (BIP34).
Uint8List scriptNumPush(int n) {
  if (n == 0) return Uint8List.fromList([0]);
  if (n >= 1 && n <= 16) return Uint8List.fromList([0x50 + n]);
  final bytes = <int>[];
  var v = n;
  while (v > 0) {
    bytes.add(v & 0xff);
    v >>= 8;
  }
  if (bytes.last & 0x80 != 0) bytes.add(0);
  return Uint8List.fromList([bytes.length, ...bytes]);
}
