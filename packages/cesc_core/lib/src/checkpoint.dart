import 'dart:convert';
import 'dart:typed_data';

import 'package:utxo_core/utxo_core.dart';

import 'checkpoint.g.dart';

/// The embedded starting point of the Cryptoescudo light chain.
HeaderCheckpoint cryptoescudoCheckpoint() {
  final hist = ByteData.sublistView(base64.decode(checkpointHistory));
  final n = hist.lengthInBytes ~/ 8;
  return HeaderCheckpoint(
    height: checkpointHeight,
    hash: hashFromHex(checkpointHash),
    bits: [for (var i = 0; i < n; i++) hist.getUint32(i * 8, Endian.little)],
    times: [for (var i = 0; i < n; i++) hist.getUint32(i * 8 + 4, Endian.little)],
  );
}
