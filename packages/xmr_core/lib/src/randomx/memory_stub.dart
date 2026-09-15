import 'dart:typed_data';

/// Fallback for platforms without `dart:ffi` (the web): shared memory is
/// unavailable and callers use the pure Dart backend.

const bool sharedSupported = false;

int allocateShared(int bytes) => throw UnsupportedError('shared memory needs dart:ffi');

Int64List viewShared(int address, int count) => throw UnsupportedError('shared memory needs dart:ffi');

void freeShared(int address) {}

int? availableMemoryBytes() => null;

int? totalMemoryBytes() => null;
