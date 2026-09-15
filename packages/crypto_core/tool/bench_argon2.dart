import 'package:crypto_core/crypto_core.dart';

void main() {
  final sw = Stopwatch()..start();
  Argon2.hash(password: [1, 2, 3], salt: List.filled(16, 0));
  print('Argon2id 64 MiB t=3: ${sw.elapsedMilliseconds} ms');
}
