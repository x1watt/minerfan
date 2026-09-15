import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:crypto_core/crypto_core.dart';
import 'package:xmr_core/src/randomx/aes_gen.dart';
import 'package:xmr_core/src/randomx/cache.dart';
import 'package:xmr_core/src/randomx/superscalar.dart';
import 'package:xmr_core/src/randomx/vm.dart';
import 'package:xmr_core/src/util/bytes.dart';

// Vectors from tevador/RandomX src/tests/tests.cpp.

final key000 = utf8.encode('test key 000');
final key001 = utf8.encode('test key 001');

void main() {
  test('AesGenerator1R', () {
    final state = Uint8List(64)..setAll(0, fromHex('6c19536eb2de31b6c0065f7f116e86f960d8af0c57210a6584c3237b9d064dc7'));
    final s = Uint32List.view(state.buffer);
    final out = Uint32List(16);
    fillAes1Rx4(s, out, 0, 16);
    expect(toHex(Uint8List.view(out.buffer)).substring(0, 64),
        'fa89397dd6ca422513aeadba3f124b5540324c4ad4b6db434394307a17c833ab');
  });

  test('SuperscalarHash generator', () {
    const refs = [
      'd3a4a6623738756f77e6104469102f082eff2a3e60be7ad696285ef7dfc72a61',
      'f5e7e0bbc7e93c609003d6359208688070afb4a77165a552ff7be63b38dfbc86',
      '85ed8b11734de5b3e9836641413a8f36e99e89694f419c8cd25c3f3f16c40c5a',
      '5dd956292cf5d5704ad99e362d70098b2777b2a1730520be52f772ca48cd3bc0',
      '6f14018ca7d519e9b48d91af094c0f2d7e12e93af0228782671a8640092af9e5',
      '134be097c92e2c45a92f23208cacd89e4ce51f1009a0b900dbe83b38de11d791',
      '268f9392c20c6e31371a5131f82bd7713d3910075f2f0468baafaa1abd2f3187',
      'c668a05fd909714ed4a91e8d96d67b17e44329e88bc71e0672b529a3fc16be47',
      '99739351315840963011e4c5d8e90ad0bfed3facdcb713fe8f7138fbf01c4c94',
      '14ab53d61880471f66e80183968d97effd5492b406876060e595fcf9682f9295',
    ];
    final gen = Blake2Generator(key000);
    for (var i = 0; i < 10; i++) {
      final p = SuperscalarProgram.generate(gen);
      expect(toHex(Blake2b.hash(p.toReferenceBytes(), 32)), refs[i], reason: 'program $i');
    }
  });

  group('with cache "test key 000"', () {
    late RandomXCache cache;
    setUpAll(() {
      cache = RandomXCache.create(key000);
    });

    test('cache words', () {
      final m = cache.memory;
      expect(m[0], 0x191e0e1d23c02186);
      expect(m[1568413], 0xf1b62fe6210bf8b1);
      expect(m[33554431], 0x1f47f056d05cd99b);
    });

    test('dataset items', () {
      final out = Int64List(8), rl = Int64List(8);
      cache.initDatasetItem(out, 0, 0, rl);
      expect(out[0], 0x680588a85ae222db);
      cache.initDatasetItem(out, 0, 10000000, rl);
      expect(out[0], 0x7943a1f6186ffb72);
      cache.initDatasetItem(out, 0, 20000000, rl);
      expect(out[0], 0x9035244d718095e1);
      cache.initDatasetItem(out, 0, 30000000, rl);
      expect(out[0], 0x145a5091f7853099);
    });

    test('hash a/b/c v1', () {
      final vm = RandomXVM.light(cache);
      expect(toHex(vm.hash(utf8.encode('This is a test'))),
          '639183aae1bf4c9a35884cb46b09cad9175f04efd7684e7262a0ac1c2f0b4e3f');
      expect(toHex(vm.hash(utf8.encode('Lorem ipsum dolor sit amet'))),
          '300a0adb47603dedb42228ccb2b211104f4da45af709cd7547cd049e9489c969');
      expect(toHex(vm.hash(utf8.encode('sed do eiusmod tempor incididunt ut labore et dolore magna aliqua'))),
          'c36d4ed4191e617309867ed66a443be4075014e2b061bcdaf9ce7b721d2b77a8');
    });

    test('hash a/b/c v2', () {
      final vm = RandomXVM.light(cache, v2: true);
      expect(toHex(vm.hash(utf8.encode('This is a test'))),
          '22ec6b861b3eb23686b2efbad69513c967ecfce80983df66c9c5b4fbfb4cdb6f');
      expect(toHex(vm.hash(utf8.encode('Lorem ipsum dolor sit amet'))),
          '9e2c772c12fd48f93c14c97fdc89d556264d9100597023f44d9163e279012ecf');
      expect(toHex(vm.hash(utf8.encode('sed do eiusmod tempor incididunt ut labore et dolore magna aliqua'))),
          '4d6b063a1a603751d525f18a171336a4002f2f06df6c17e4b25fe17e17796e42');
    });
  });

  group('with cache "test key 001"', () {
    late RandomXCache cache;
    setUpAll(() {
      cache = RandomXCache.create(key001);
    });

    test('hash d/e v1 and v2', () {
      final input = utf8.encode('sed do eiusmod tempor incididunt ut labore et dolore magna aliqua');
      final blob = fromHex('0b0b98bea7e805e0010a2126d287a2a0cc833d312cb786385a7c2f9de69d25537f584a9bc9977b00000000'
          '666fd8753bf61a8631f12984e3fd44f4014eca629276817b56f32e9b68bd82f416');
      final v1 = RandomXVM.light(cache);
      expect(toHex(v1.hash(input)), 'e9ff4503201c0c2cca26d285c93ae883f9b1d30c9eb240b820756f2d5a7905fc');
      expect(toHex(v1.hash(blob)), 'c56414121acda1713c2f2a819d8ae38aed7c80c35c2a769298d34f03833cd5f1');
      final v2 = RandomXVM.light(cache, v2: true);
      expect(toHex(v2.hash(input)), '97024134686ce27d362ea8d86d8ef16483ac272abdabd46ef13359400777fe5e');
      expect(toHex(v2.hash(blob)), 'c8e92c5f7c1946fecf06bc382b92e3111da38ee3e6a5ad90704e1a9d8aaf6e76');
    });
  });

  test('hash f v1 (ISUB_R 0x80000000 edge case)', () {
    final cache = RandomXCache.create(fromHex('7797373ea4633194640bf8d8c3b66724d6aa7bd2dc20e009df2f8f1710abe8'));
    final vm = RandomXVM.light(cache);
    final input = fromHex('1010e1eaf8cf067b37b5f0ee031ab23ed1755e090a3af4415830145853e2be3e1f6821fed84dae58d00e00'
        'da5214d6c1f2d0622e0abd51f9373d04e0b0f8e6d6514d90689721c4aac5a9bb0d');
    expect(toHex(vm.hash(input)), '78af2a1864c42abce36d2e8983e13df99b2af0ce1362999af09fab004d4435a8');
  });
}
