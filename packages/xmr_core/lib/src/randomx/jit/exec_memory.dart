import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';

/// Executable memory for generated machine code, from the OS through
/// `dart:ffi` (libc on POSIX, kernel32 on Windows). No native library is
/// bundled; the code written here is produced by the JIT at run time.
///
/// Pages are writable while code is emitted and executable while it runs
/// (W^X): [writable] and [executable] switch between the two. On Apple
/// Silicon the switch is `pthread_jit_write_protect_np` on `MAP_JIT` memory,
/// which applies to the calling thread only, so emit and run on the same
/// thread (one synchronous Dart call).

typedef _MmapC = Pointer<Void> Function(Pointer<Void>, IntPtr, Int32, Int32, Int32, IntPtr);
typedef _MmapD = Pointer<Void> Function(Pointer<Void>, int, int, int, int, int);
typedef _MprotectC = Int32 Function(Pointer<Void>, IntPtr, Int32);
typedef _MprotectD = int Function(Pointer<Void>, int, int);
typedef _MunmapC = Int32 Function(Pointer<Void>, IntPtr);
typedef _MunmapD = int Function(Pointer<Void>, int);
typedef _VoidIntC = Void Function(Int32);
typedef _VoidIntD = void Function(int);
typedef _CacheC = Void Function(Pointer<Void>, IntPtr);
typedef _CacheD = void Function(Pointer<Void>, int);
typedef _ClearCacheC = Void Function(Pointer<Void>, Pointer<Void>);
typedef _ClearCacheD = void Function(Pointer<Void>, Pointer<Void>);

typedef _VirtualAllocC = Pointer<Void> Function(Pointer<Void>, IntPtr, Uint32, Uint32);
typedef _VirtualAllocD = Pointer<Void> Function(Pointer<Void>, int, int, int);
typedef _VirtualProtectC = Int32 Function(Pointer<Void>, IntPtr, Uint32, Pointer<Uint32>);
typedef _VirtualProtectD = int Function(Pointer<Void>, int, int, Pointer<Uint32>);
typedef _VirtualFreeC = Int32 Function(Pointer<Void>, IntPtr, Uint32);
typedef _VirtualFreeD = int Function(Pointer<Void>, int, int);
typedef _FlushIcC = Int32 Function(IntPtr, Pointer<Void>, IntPtr);
typedef _FlushIcD = int Function(int, Pointer<Void>, int);
typedef _MallocC = Pointer<Void> Function(IntPtr);
typedef _MallocD = Pointer<Void> Function(int);
typedef _FreeC = Void Function(Pointer<Void>);
typedef _FreeD = void Function(Pointer<Void>);

const int _protRead = 1, _protWrite = 2, _protExec = 4;
const int _mapPrivate = 2;
const int _madvHugepage = 14; // Linux

bool get _isApple => Platform.isMacOS || Platform.isIOS;
final bool _isArm64 = Abi.current() == Abi.linuxArm64 ||
    Abi.current() == Abi.androidArm64 ||
    Abi.current() == Abi.macosArm64 ||
    Abi.current() == Abi.iosArm64 ||
    Abi.current() == Abi.windowsArm64;
final bool _isX64 = Abi.current() == Abi.linuxX64 ||
    Abi.current() == Abi.androidX64 ||
    Abi.current() == Abi.macosX64 ||
    Abi.current() == Abi.windowsX64;

class _Posix {
  static final DynamicLibrary lib = DynamicLibrary.process();
  static final _MmapD mmap = lib.lookupFunction<_MmapC, _MmapD>('mmap');
  static final _MprotectD mprotect = lib.lookupFunction<_MprotectC, _MprotectD>('mprotect');
  static final _MunmapD munmap = lib.lookupFunction<_MunmapC, _MunmapD>('munmap');
  static final _MprotectD madvise = lib.lookupFunction<_MprotectC, _MprotectD>('madvise');
  static final _VoidIntD? jitWriteProtect = _isApple && _isArm64
      ? lib.lookupFunction<_VoidIntC, _VoidIntD>('pthread_jit_write_protect_np')
      : null;
  static final _CacheD? icacheInvalidate =
      _isApple && _isArm64 ? lib.lookupFunction<_CacheC, _CacheD>('sys_icache_invalidate') : null;
  static final _ClearCacheD? clearCache = () {
    if (_isApple || !_isArm64) return null;
    try {
      return lib.lookupFunction<_ClearCacheC, _ClearCacheD>('__clear_cache');
    } catch (_) {
      return null;
    }
  }();
  static int get mapAnonymous => _isApple ? 0x1000 : 0x20;
  static const int mapJit = 0x800;
}

class _Win {
  static final DynamicLibrary k32 = DynamicLibrary.open('kernel32.dll');
  static final _VirtualAllocD alloc = k32.lookupFunction<_VirtualAllocC, _VirtualAllocD>('VirtualAlloc');
  static final _VirtualProtectD protect = k32.lookupFunction<_VirtualProtectC, _VirtualProtectD>('VirtualProtect');
  static final _VirtualFreeD free = k32.lookupFunction<_VirtualFreeC, _VirtualFreeD>('VirtualFree');
  static final _FlushIcD flush = k32.lookupFunction<_FlushIcC, _FlushIcD>('FlushInstructionCache');
  static final DynamicLibrary ole = DynamicLibrary.open('ole32.dll');
  static final _MallocD malloc = ole.lookupFunction<_MallocC, _MallocD>('CoTaskMemAlloc');
  static final _FreeD mfree = ole.lookupFunction<_FreeC, _FreeD>('CoTaskMemFree');
  static const int memCommit = 0x1000, memReserve = 0x2000, memRelease = 0x8000;
  static const int pageReadWrite = 0x04, pageExecuteRead = 0x20, pageExecuteReadWrite = 0x40;
}

/// Instruction cache flush for ARM64 Linux/Android when libc/libgcc does not
/// export `__clear_cache`; installed by the ARM64 JIT.
void Function(int address, int length)? arm64CacheFlushFallback;

class ExecMemory {
  final int address;
  final int size;

  /// Mapped read-write-execute once (as xmrig does by default): no
  /// permission changes per program. Changing permissions makes the kernel
  /// flush the TLBs of every core running one of our threads, which costs
  /// far more than the program itself when all cores mine.
  final bool rwx;
  bool _executable = false;
  bool _freed = false;

  ExecMemory._(this.address, this.size, this.rwx);

  /// Set to false to always use W^X toggling.
  static bool allowRwx = true;

  /// Whether this platform and CPU can run generated code.
  static bool get supported => (_isX64 || _isArm64) && !Platform.isIOS;

  static bool get isX64 => _isX64;
  static bool get isArm64 => _isArm64;

  /// Maps [size] bytes (rounded up to pages), writable.
  static ExecMemory allocate(int size) {
    size = (size + 0xffff) & ~0xffff;
    var addr = 0;
    var rwx = false;
    if (Platform.isWindows) {
      if (allowRwx) {
        addr = _Win.alloc(nullptr, size, _Win.memCommit | _Win.memReserve, _Win.pageExecuteReadWrite).address;
        rwx = addr != 0;
      }
      if (addr == 0) addr = _Win.alloc(nullptr, size, _Win.memCommit | _Win.memReserve, _Win.pageReadWrite).address;
    } else {
      final appleJit = _isApple && _isArm64;
      final flags = _mapPrivate | _Posix.mapAnonymous | (appleJit ? _Posix.mapJit : 0);
      if (appleJit) {
        addr = _Posix.mmap(nullptr, size, _protRead | _protWrite | _protExec, flags, -1, 0).address;
      } else {
        if (allowRwx) {
          addr = _Posix.mmap(nullptr, size, _protRead | _protWrite | _protExec, flags, -1, 0).address;
          rwx = addr != -1 && addr != 0;
        }
        if (!rwx) addr = _Posix.mmap(nullptr, size, _protRead | _protWrite, flags, -1, 0).address;
      }
      if (addr == -1) addr = 0; // MAP_FAILED
    }
    if (addr == 0) throw StateError('cannot map $size bytes of code memory');
    final m = ExecMemory._(addr, size, rwx);
    if (!rwx) m._setWritable();
    return m;
  }

  /// Byte view for emitting code (only while [writable]).
  Uint8List get bytes => Pointer<Uint8>.fromAddress(address).asTypedList(size);

  void _setWritable() {
    if (Platform.isWindows) {
      _protect(_Win.pageReadWrite);
    } else if (_Posix.jitWriteProtect != null) {
      _Posix.jitWriteProtect!(0);
    } else if (_Posix.mprotect(Pointer.fromAddress(address), size, _protRead | _protWrite) != 0) {
      throw StateError('mprotect RW failed');
    }
    _executable = false;
  }

  /// Makes the pages writable (and not executable).
  void writable() {
    if (rwx) return;
    if (_executable) _setWritable();
  }

  /// Makes the pages executable (and not writable) and flushes the
  /// instruction cache for [length] bytes from [offset] where needed.
  void executable({int offset = 0, int? length}) {
    final len = length ?? size;
    if (rwx) {
      if (Platform.isWindows) {
        _Win.flush(-1, Pointer.fromAddress(address + offset), len);
      } else if (_isArm64) {
        flushInstructionCache(address + offset, len);
      }
      return;
    }
    if (Platform.isWindows) {
      _protect(_Win.pageExecuteRead);
      _Win.flush(-1, Pointer.fromAddress(address + offset), len); // -1: current process
    } else if (_Posix.jitWriteProtect != null) {
      _Posix.jitWriteProtect!(1);
      _Posix.icacheInvalidate!(Pointer.fromAddress(address + offset), len);
    } else {
      if (_Posix.mprotect(Pointer.fromAddress(address), size, _protRead | _protExec) != 0) {
        throw StateError('mprotect RX failed');
      }
      if (_isArm64) flushInstructionCache(address + offset, len);
    }
    _executable = true;
  }

  void _protect(int prot) {
    final old = Pointer<Uint32>.fromAddress(_Win.malloc(4).address);
    try {
      if (_Win.protect(Pointer.fromAddress(address), size, prot, old) == 0) {
        throw StateError('VirtualProtect failed');
      }
    } finally {
      _Win.mfree(old.cast());
    }
  }

  void free() {
    if (_freed) return;
    _freed = true;
    if (Platform.isWindows) {
      _Win.free(Pointer.fromAddress(address), 0, _Win.memRelease);
    } else {
      _Posix.munmap(Pointer.fromAddress(address), size);
    }
  }
}

/// Fresh read-write pages straight from the OS, aligned to 2 MiB and marked
/// for transparent huge pages before anything touches them (malloc may hand
/// out memory that was already touched, which then stays in small pages).
class NativePages {
  final int _mapping;
  final int _mappingSize;

  /// 2 MiB aligned start of the usable [size] bytes.
  final int address;
  final int size;

  NativePages._(this._mapping, this._mappingSize, this.address, this.size);

  static const int _huge = 2 << 20;

  static NativePages allocate(int size) {
    final mappingSize = ((size + _huge - 1) & ~(_huge - 1)) + _huge;
    int mapping;
    if (Platform.isWindows) {
      mapping = _Win.alloc(nullptr, mappingSize, _Win.memCommit | _Win.memReserve, _Win.pageReadWrite).address;
    } else {
      mapping = _Posix.mmap(nullptr, mappingSize, _protRead | _protWrite, _mapPrivate | _Posix.mapAnonymous, -1, 0).address;
      if (mapping == -1) mapping = 0;
    }
    if (mapping == 0) throw StateError('cannot map $size bytes');
    final start = (mapping + _huge - 1) & ~(_huge - 1);
    adviseHugePages(start, (size + _huge - 1) & ~(_huge - 1));
    return NativePages._(mapping, mappingSize, start, size);
  }

  void free() {
    if (Platform.isWindows) {
      _Win.free(Pointer.fromAddress(_mapping), 0, _Win.memRelease);
    } else {
      _Posix.munmap(Pointer.fromAddress(_mapping), _mappingSize);
    }
  }
}

/// Flushes the instruction cache (ARM64 Linux/Android) after writing code.
void flushInstructionCache(int address, int length) {
  final cc = _Posix.clearCache;
  if (cc != null) {
    cc(Pointer.fromAddress(address), Pointer.fromAddress(address + length));
  } else {
    arm64CacheFlushFallback?.call(address, length);
  }
}

/// Asks Linux/Android for transparent huge pages on a large buffer (no root
/// needed); fewer TLB misses on the dataset and scratchpads.
void adviseHugePages(int address, int length) {
  if (!(Platform.isLinux || Platform.isAndroid)) return;
  try {
    final start = (address + 0x1fffff) & ~0x1fffff;
    final end = (address + length) & ~0x1fffff;
    if (end > start) _Posix.madvise(Pointer.fromAddress(start), end - start, _madvHugepage);
  } catch (_) {}
}
