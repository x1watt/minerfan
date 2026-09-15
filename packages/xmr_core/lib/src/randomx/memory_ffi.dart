import 'dart:ffi';
import 'dart:io' show File, Platform;
import 'dart:typed_data';

/// Shared memory through `dart:ffi` and the OS C allocator. No native library
/// is bundled: `malloc`/`free` come from the process (libc) on POSIX systems
/// and `CoTaskMemAlloc`/`CoTaskMemFree` from ole32 on Windows.

typedef _AllocC = Pointer<Void> Function(IntPtr);
typedef _AllocD = Pointer<Void> Function(int);
typedef _FreeC = Void Function(Pointer<Void>);
typedef _FreeD = void Function(Pointer<Void>);

final DynamicLibrary _lib = Platform.isWindows ? DynamicLibrary.open('ole32.dll') : DynamicLibrary.process();

final _AllocD _alloc = _lib.lookupFunction<_AllocC, _AllocD>(Platform.isWindows ? 'CoTaskMemAlloc' : 'malloc');
final _FreeD _free = _lib.lookupFunction<_FreeC, _FreeD>(Platform.isWindows ? 'CoTaskMemFree' : 'free');

const bool sharedSupported = true;

int allocateShared(int bytes) {
  final p = _alloc(bytes);
  if (p.address == 0) {
    throw StateError('out of memory allocating $bytes bytes');
  }
  if (bytes >= (32 << 20)) _adviseHugePages(p.address, bytes);
  return p.address;
}

typedef _MadviseC = Int32 Function(Pointer<Void>, IntPtr, Int32);
typedef _MadviseD = int Function(Pointer<Void>, int, int);

/// Transparent huge pages for the cache and dataset (Linux/Android, no root
/// needed): far fewer TLB misses on random dataset reads.
void _adviseHugePages(int address, int length) {
  if (!(Platform.isLinux || Platform.isAndroid)) return;
  try {
    final madvise = DynamicLibrary.process().lookupFunction<_MadviseC, _MadviseD>('madvise');
    final start = (address + 0x1fffff) & ~0x1fffff;
    final end = (address + length) & ~0x1fffff;
    if (end > start) madvise(Pointer.fromAddress(start), end - start, 14); // MADV_HUGEPAGE
  } catch (_) {}
}

Int64List viewShared(int address, int count) => Pointer<Int64>.fromAddress(address).asTypedList(count);

void freeShared(int address) => _free(Pointer<Void>.fromAddress(address));

typedef _MemStatusC = Int32 Function(Pointer<Void>);
typedef _MemStatusD = int Function(Pointer<Void>);

/// Physical memory (Linux/Android: MemTotal; Windows: total physical), or
/// null where it cannot be read without a native helper.
int? totalMemoryBytes() {
  try {
    if (Platform.isLinux || Platform.isAndroid) {
      for (final line in File('/proc/meminfo').readAsLinesSync()) {
        if (line.startsWith('MemTotal:')) return int.parse(line.split(RegExp(r'\s+'))[1]) * 1024;
      }
    } else if (Platform.isWindows) {
      final status = DynamicLibrary.open('kernel32.dll').lookupFunction<_MemStatusC, _MemStatusD>('GlobalMemoryStatusEx');
      final p = _alloc(64);
      try {
        final words = p.cast<Uint32>().asTypedList(16)..fillRange(0, 16, 0);
        words[0] = 64;
        if (status(p) == 0) return null;
        return p.cast<Uint64>().asTypedList(8)[1];
      } finally {
        _free(p);
      }
    }
  } catch (_) {}
  return null;
}

/// Memory the OS can hand out without swapping, or null where it cannot be
/// read without a native helper (macOS, iOS).
int? availableMemoryBytes() {
  try {
    if (Platform.isLinux || Platform.isAndroid) {
      for (final line in File('/proc/meminfo').readAsLinesSync()) {
        if (line.startsWith('MemAvailable:')) {
          return int.parse(line.split(RegExp(r'\s+'))[1]) * 1024;
        }
      }
    } else if (Platform.isWindows) {
      // MEMORYSTATUSEX: dwLength, dwMemoryLoad, ullTotalPhys, ullAvailPhys, ...
      final status = DynamicLibrary.open('kernel32.dll').lookupFunction<_MemStatusC, _MemStatusD>('GlobalMemoryStatusEx');
      final p = _alloc(64);
      try {
        final words = p.cast<Uint32>().asTypedList(16)..fillRange(0, 16, 0);
        words[0] = 64;
        if (status(p) == 0) return null;
        return p.cast<Uint64>().asTypedList(8)[2];
      } finally {
        _free(p);
      }
    }
  } catch (_) {}
  return null;
}
