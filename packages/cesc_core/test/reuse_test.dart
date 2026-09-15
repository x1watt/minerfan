import 'dart:io';

import 'package:test/test.dart';

/// Everything that is not Cryptoescudo lives in shared packages; they must
/// not know about it.
void main() {
  test('shared packages hold no Cryptoescudo constants', () {
    final needles = [RegExp('cryptoescudo', caseSensitive: false), RegExp(r'\bCESC\b'), RegExp('61143'),
      RegExp(r'0xfb,\s*0xc0'), RegExp('fbc0b6db')];
    for (final pkg in ['crypto_core', 'net_core', 'gpu_core', 'pow_core', 'utxo_core']) {
      for (final f in Directory('../$pkg/lib').listSync(recursive: true).whereType<File>()) {
        final text = f.readAsStringSync();
        for (final n in needles) {
          expect(n.hasMatch(text), isFalse, reason: '${f.path} mentions ${n.pattern}');
        }
      }
    }
  });
}
