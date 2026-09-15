import 'dart:convert';
import 'dart:typed_data';

import '../crypto/aes_soft.dart';
import 'package:crypto_core/crypto_core.dart';

/// RandomX AES generators and hash (tevador/RandomX `aes_hash.cpp`).
/// Keys are derived from their defining Blake2b strings, as the spec states.
class RxAesKeys {
  final Uint32List gen1R; // 4 keys
  final Uint32List gen4R; // 8 keys
  final Uint32List hashState; // 4 columns x 4
  final Uint32List hashXKeys; // 2 keys

  static final RxAesKeys instance = RxAesKeys._();

  RxAesKeys._()
      : gen1R = _words(Blake2b.hash(utf8.encode('RandomX AesGenerator1R keys'), 64)),
        gen4R = Uint32List.fromList([
          ..._words(Blake2b.hash(utf8.encode('RandomX AesGenerator4R keys 0-3'), 64)),
          ..._words(Blake2b.hash(utf8.encode('RandomX AesGenerator4R keys 4-7'), 64)),
        ]),
        hashState = _words(Blake2b.hash(utf8.encode('RandomX AesHash1R state'), 64)),
        hashXKeys = _words(Blake2b.hash(utf8.encode('RandomX AesHash1R xkeys'), 32));

  static Uint32List _words(Uint8List b) => Uint32List.fromList(Uint32List.view(b.buffer, 0, b.length ~/ 4));
}

/// fillAes1Rx4: [state] is 16 words (64 bytes) and is updated in place;
/// fills [out] starting at word [outStart] with [outWords] words.
void fillAes1Rx4(Uint32List state, Uint32List out, int outStart, int outWords) {
  final k = RxAesKeys.instance.gen1R;
  for (var o = outStart; o < outStart + outWords; o += 16) {
    aesDecRound(state, 0, k, 0);
    aesEncRound(state, 4, k, 4);
    aesDecRound(state, 8, k, 8);
    aesEncRound(state, 12, k, 12);
    out.setRange(o, o + 16, state);
  }
}

/// fillAes4Rx4: generates program bytes from [state] (16 words, not written
/// back) into [out].
void fillAes4Rx4(Uint32List state, Uint32List out, int outWords) {
  final k = RxAesKeys.instance.gen4R;
  final s = Uint32List.fromList(state);
  for (var o = 0; o < outWords; o += 16) {
    for (var r = 0; r < 4; r++) {
      aesDecRound(s, 0, k, 4 * r);
      aesEncRound(s, 4, k, 4 * r);
      aesDecRound(s, 8, k, 16 + 4 * r);
      aesEncRound(s, 12, k, 16 + 4 * r);
    }
    out.setRange(o, o + 16, s);
  }
}

/// hashAes1Rx4: 64-byte hash of [input] (words, length a multiple of 16)
/// written into [out] at word [outStart].
void hashAes1Rx4(Uint32List input, Uint32List out, int outStart) {
  final keys = RxAesKeys.instance;
  final s = Uint32List.fromList(keys.hashState);
  final n = input.length;
  for (var i = 0; i < n; i += 16) {
    aesEncRound(s, 0, input, i);
    aesDecRound(s, 4, input, i + 4);
    aesEncRound(s, 8, input, i + 8);
    aesDecRound(s, 12, input, i + 12);
  }
  final x = keys.hashXKeys;
  for (var r = 0; r < 2; r++) {
    aesEncRound(s, 0, x, 4 * r);
    aesDecRound(s, 4, x, 4 * r);
    aesEncRound(s, 8, x, 4 * r);
    aesDecRound(s, 12, x, 4 * r);
  }
  out.setRange(outStart, outStart + 16, s);
}
