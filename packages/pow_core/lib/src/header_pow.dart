import 'dart:typed_data';

import 'package:crypto_core/crypto_core.dart';

/// The proof-of-work function of a chain's 80-byte block header. The hash
/// is compared, as a little-endian number, with the target from `nBits`.
abstract class HeaderPow {
  /// Algorithm id as in the mining catalog (`scrypt`, `sha256d`, ...).
  String get algorithm;

  Uint8List hash(List<int> header);
}

/// scrypt(N=1024, r=1, p=1) over the header (Litecoin family). Keeps one
/// scratchpad, so an instance belongs to one isolate.
class ScryptPow implements HeaderPow {
  final ScryptHasher _hasher = ScryptHasher();

  @override
  String get algorithm => 'scrypt';

  @override
  Uint8List hash(List<int> header) => scryptPow(header, _hasher);
}

/// Double SHA-256 over the header (Bitcoin family).
class Sha256dPow implements HeaderPow {
  @override
  String get algorithm => 'sha256d';

  @override
  Uint8List hash(List<int> header) => sha256d(header);
}
