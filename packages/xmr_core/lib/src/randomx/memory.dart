import 'dart:typed_data';

import 'memory_stub.dart' if (dart.library.ffi) 'memory_ffi.dart' as native;

/// Where RandomX's large buffers (256 MiB cache, 2080 MiB dataset) live.
///
/// * [RxMemoryKind.dart]: an ordinary `Int64List`. Private to the isolate that
///   made it; other isolates need their own copy. Works everywhere.
/// * [RxMemoryKind.shared]: memory from the OS allocator through `dart:ffi`
///   (Dart SDK only, no native library). Any isolate can view it by address,
///   so every hashing thread shares one cache or dataset.
enum RxMemoryKind { dart, shared }

/// A buffer of 64-bit words plus, for shared memory, the handle another
/// isolate needs to attach to it.
class RxBuffer {
  final Int64List words;
  final RxMemoryKind kind;

  /// Native address for [RxMemoryKind.shared], 0 otherwise.
  final int address;

  RxBuffer._(this.words, this.kind, this.address);

  /// Allocates [count] words of the requested kind.
  factory RxBuffer.allocate(int count, RxMemoryKind kind) {
    if (kind == RxMemoryKind.shared) {
      final addr = native.allocateShared(count * 8);
      return RxBuffer._(native.viewShared(addr, count), kind, addr);
    }
    return RxBuffer._(Int64List(count), kind, 0);
  }

  /// Attaches to shared memory made by another isolate.
  factory RxBuffer.attach(int address, int count) =>
      RxBuffer._(native.viewShared(address, count), RxMemoryKind.shared, address);

  /// Wraps an existing isolate-private word list.
  factory RxBuffer.fromWords(Int64List words) => RxBuffer._(words, RxMemoryKind.dart, 0);

  /// Portable handle: `(address, count)` for shared buffers.
  (int, int) get handle => (address, words.length);

  void free() {
    if (kind == RxMemoryKind.shared && address != 0) native.freeShared(address);
  }

  static bool get sharedSupported => native.sharedSupported;
}

/// Memory available without swapping, where the platform exposes it
/// (Linux, Android, Windows); null elsewhere.
int? availableMemoryBytes() => native.availableMemoryBytes();

/// Physical memory, where the platform exposes it (Linux, Android, Windows).
int? totalMemoryBytes() => native.totalMemoryBytes();
