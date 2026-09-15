import 'dart:typed_data';

import '../crypto/ed25519.dart' show bytesToBigLE;

/// Monero difficulty (src/cryptonote_basic/difficulty.cpp), 128-bit values
/// kept as BigInt.

const int difficultyTarget = 120;
const int difficultyWindow = 720;
const int difficultyLag = 15;
const int difficultyCut = 60;
const int difficultyBlocksCount = difficultyWindow + difficultyLag; // 735

final BigInt _two256 = BigInt.one << 256;
final BigInt _max128 = (BigInt.one << 128) - BigInt.one;

/// Difficulty of the next block from the timestamps and cumulative
/// difficulties of up to the last [difficultyBlocksCount] blocks, oldest
/// first. The newest [difficultyLag] entries are ignored.
BigInt nextDifficulty(List<int> timestamps, List<BigInt> cumulativeDifficulties) {
  var ts = List<int>.of(timestamps);
  var cd = List<BigInt>.of(cumulativeDifficulties);
  if (ts.length > difficultyWindow) {
    ts = ts.sublist(0, difficultyWindow);
    cd = cd.sublist(0, difficultyWindow);
  }
  final length = ts.length;
  if (length <= 1) return BigInt.one;
  ts.sort();
  int cutBegin, cutEnd;
  const kept = difficultyWindow - 2 * difficultyCut;
  if (length <= kept) {
    cutBegin = 0;
    cutEnd = length;
  } else {
    cutBegin = (length - kept + 1) ~/ 2;
    cutEnd = cutBegin + kept;
  }
  var timeSpan = ts[cutEnd - 1] - ts[cutBegin];
  if (timeSpan == 0) timeSpan = 1;
  final totalWork = cd[cutEnd - 1] - cd[cutBegin];
  final span = BigInt.from(timeSpan);
  final res = (totalWork * BigInt.from(difficultyTarget) + span - BigInt.one) ~/ span;
  if (res > _max128) return BigInt.zero;
  return res;
}

/// True if a RandomX [hash] (32 bytes, little-endian) meets [difficulty]:
/// hash * difficulty < 2^256.
bool checkPow(Uint8List hash, BigInt difficulty) => bytesToBigLE(hash) * difficulty < _two256;
