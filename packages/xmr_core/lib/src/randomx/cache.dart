import 'dart:typed_data';

import '../crypto/argon2d.dart';
import 'config.dart';
import 'memory.dart';
import 'superscalar.dart';

/// The RandomX cache for one key: 256 MiB of Argon2d output plus the eight
/// SuperscalarHash programs. Dataset items are computed from it on demand
/// (light mode) or all at once into a [RandomXDataset] (fast mode).
class RandomXCache {
  final List<int> key;
  final RxBuffer buffer;
  final List<SuperscalarProgram> programs;

  RandomXCache._(this.key, this.buffer, this.programs);

  Int64List get memory => buffer.words;

  static const int words = cacheSizeBytes ~/ 8;

  /// Builds the cache for [key] into freshly allocated memory of [kind].
  static RandomXCache create(List<int> key, {RxMemoryKind kind = RxMemoryKind.dart}) {
    final buf = RxBuffer.allocate(words, kind);
    Argon2d.fill(buf.words, key, rxArgonSalt, passes: rxArgonIterations, blocks: rxArgonMemory);
    return RandomXCache._(List<int>.unmodifiable(key), buf, _programs(key));
  }

  /// Attaches to a cache another isolate already built in shared memory.
  /// The programs are regenerated from the key, which costs microseconds.
  static RandomXCache attach(List<int> key, int address) =>
      RandomXCache._(List<int>.unmodifiable(key), RxBuffer.attach(address, words), _programs(key));

  /// Wraps an existing cache image (e.g. a copy received from another
  /// isolate in the pure Dart backend).
  static RandomXCache fromWords(List<int> key, Int64List memory) =>
      RandomXCache._(List<int>.unmodifiable(key), RxBuffer.fromWords(memory), _programs(key));

  static List<SuperscalarProgram> _programs(List<int> key) {
    final gen = Blake2Generator(key);
    return List.generate(rxCacheAccesses, (_) => SuperscalarProgram.generate(gen), growable: false);
  }

  /// Computes dataset item [itemNumber] into out[outOffset..outOffset+7].
  /// [rl] is an 8-word scratch register file.
  @pragma('vm:unsafe:no-bounds-checks')
  void initDatasetItem(Int64List out, int outOffset, int itemNumber, Int64List rl) {
    final mem = buffer.words;
    var registerValue = itemNumber;
    final r0 = (itemNumber + 1) * superscalarMul0;
    rl[0] = r0;
    for (var i = 1; i < 8; i++) {
      rl[i] = r0 ^ superscalarAdd[i];
    }
    for (var i = 0; i < rxCacheAccesses; i++) {
      final mix = (registerValue & (cacheLineCount - 1)) * 8;
      final prog = programs[i];
      prog.execute(rl);
      for (var q = 0; q < 8; q++) {
        rl[q] ^= mem[mix + q];
      }
      registerValue = rl[prog.addressRegister];
    }
    for (var q = 0; q < 8; q++) {
      out[outOffset + q] = rl[q];
    }
  }

  void free() => buffer.free();
}

/// The full 2080 MiB dataset (fast mode). Only practical in shared memory.
class RandomXDataset {
  final RxBuffer buffer;
  RandomXDataset._(this.buffer);

  static const int words = rxDatasetItemCount * 8;

  Int64List get memory => buffer.words;

  static RandomXDataset allocate(RxMemoryKind kind) => RandomXDataset._(RxBuffer.allocate(words, kind));

  static RandomXDataset attach(int address) => RandomXDataset._(RxBuffer.attach(address, words));

  /// Fills items [start, end) from [cache]. Split the range across isolates
  /// to initialise in parallel.
  void init(RandomXCache cache, int start, int end) {
    final rl = Int64List(8);
    final mem = buffer.words;
    for (var item = start; item < end; item++) {
      cache.initDatasetItem(mem, item * 8, item, rl);
    }
  }

  void free() => buffer.free();
}
