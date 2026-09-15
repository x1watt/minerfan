import 'package:test/test.dart';
import 'package:utxo_core/utxo_core.dart';

void main() {
  test('MurmurHash3 (reference values)', () {
    final cases = <(int, String, int)>[
      (0, '', 0x00000000),
      (0xfba4c795, '', 0x6a396f08),
      (0xffffffff, '', 0x81f16f39),
      (0, '00', 0x514e28b7),
      (0, '0011', 0x16c6b7ab),
      (0, '001122', 0x8eb51c3d),
      (0, '00112233', 0xb4471bf8),
      (0, '0011223344', 0xe2301fa8),
      (0, '001122334455667788', 0xb4698def),
      (0x12345678, 'deadbeefcafebabe01', 0xd7852888),
    ];
    for (final (seed, data, want) in cases) {
      expect(BloomFilter.murmur3(seed, fromHex(data)), want, reason: '$seed $data');
    }
  });

  test('bloom filter holds what was inserted and little else', () {
    final f = BloomFilter.forElements(40, tweak: 5);
    final items = [for (var i = 0; i < 40; i++) fromHex(i.toRadixString(16).padLeft(40, '0'))];
    items.forEach(f.insert);
    expect(items.every(f.contains), isTrue);
    var hits = 0;
    for (var i = 1000; i < 11000; i++) {
      if (f.contains(fromHex(i.toRadixString(16).padLeft(40, '0')))) hits++;
    }
    expect(hits, lessThan(50)); // about 0.05% expected
    expect(f.payload().length, greaterThan(f.data.length));
  });
}
