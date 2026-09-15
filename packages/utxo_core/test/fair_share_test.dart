import 'package:test/test.dart';
import 'package:utxo_core/utxo_core.dart';

void main() {
  test('the fair-share guard slows down above the target and pauses at twice it', () {
    expect(SoloMiner.fairShareFactor(0.25, 0.25, 30), 1);
    expect(SoloMiner.fairShareFactor(0.29, 0.25, 30), 1); // within 20%
    expect(SoloMiner.fairShareFactor(0.4, 0.25, 30), closeTo(0.625, 1e-9));
    expect(SoloMiner.fairShareFactor(0.5, 0.25, 30), 0);
    expect(SoloMiner.fairShareFactor(0.9, 0.25, 30), 0);
    expect(SoloMiner.fairShareFactor(0.9, 0.25, 5), 1); // too few blocks to judge
    expect(SoloMiner.fairShareFactor(0.9, 1, 30), 1); // full speed asked for
  });
}
