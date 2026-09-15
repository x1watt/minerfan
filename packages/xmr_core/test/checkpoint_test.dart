import 'package:test/test.dart';
import 'package:xmr_core/src/monero/checkpoint.g.dart';
import 'package:xmr_core/src/monero/difficulty.dart';

void main() {
  test('checkpoint is contiguous and yields the next block difficulty', () {
    expect(checkpointHeaders.length, difficultyBlocksCount);
    final ts = [for (final h in checkpointHeaders) h.$2];
    final cd = [for (final h in checkpointHeaders) BigInt.parse(h.$3)];
    for (var i = 1; i < cd.length; i++) {
      expect(cd[i] > cd[i - 1], isTrue);
    }
    // Monero block 3758094 (the first block after the checkpoint), from its
    // header as reported by monerod when the checkpoint was generated.
    if (checkpointEndHeight == 3758093) {
      expect(nextDifficulty(ts, cd), BigInt.from(719371725129));
    }
  });
}
