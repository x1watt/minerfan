import 'package:crypto_core/crypto_core.dart';

/// Scrypt(1024,1,1) hashes per second on one core.
void main() {
  final h = ScryptHasher();
  final header = List<int>.generate(80, (i) => i);
  for (var i = 0; i < 50; i++) {
    scryptPow(header, h);
  }
  final sw = Stopwatch()..start();
  var n = 0;
  while (sw.elapsedMilliseconds < 3000) {
    header[76] = n & 0xff;
    scryptPow(header, h);
    n++;
  }
  print('scrypt(1024,1,1): ${(n * 1000 / sw.elapsedMilliseconds).toStringAsFixed(0)} H/s on one core');
}
