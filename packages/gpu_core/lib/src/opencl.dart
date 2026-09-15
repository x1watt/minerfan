import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'opencl_ffi.dart';

// Native scratch memory from the C allocator (no package:ffi).
typedef _AllocC = Pointer<Void> Function(IntPtr);
typedef _AllocD = Pointer<Void> Function(int);
typedef _FreeC = Void Function(Pointer<Void>);
typedef _FreeD = void Function(Pointer<Void>);
final DynamicLibrary _libc = Platform.isWindows ? DynamicLibrary.open('ole32.dll') : DynamicLibrary.process();
final _AllocD _alloc = _libc.lookupFunction<_AllocC, _AllocD>(Platform.isWindows ? 'CoTaskMemAlloc' : 'malloc');
final _FreeD _free = _libc.lookupFunction<_FreeC, _FreeD>(Platform.isWindows ? 'CoTaskMemFree' : 'free');

/// Native memory freed by [free] (or [scoped]).
class _Mem {
  final List<Pointer<Void>> _held = [];

  Pointer<T> alloc<T extends NativeType>(int bytes) {
    final p = _alloc(bytes < 1 ? 1 : bytes);
    if (p.address == 0) throw StateError('out of memory');
    _held.add(p);
    return p.cast<T>();
  }

  Pointer<Char> string(String s) {
    final b = utf8.encode(s);
    final p = alloc<Uint8>(b.length + 1);
    p.asTypedList(b.length + 1)
      ..setAll(0, b)
      ..[b.length] = 0;
    return p.cast();
  }

  void free() {
    for (final p in _held) {
      _free(p);
    }
    _held.clear();
  }
}

R _scoped<R>(R Function(_Mem m) f) {
  final m = _Mem();
  try {
    return f(m);
  } finally {
    m.free();
  }
}

class OpenClException implements Exception {
  final String what;
  final int code;
  final String? detail;
  const OpenClException(this.what, this.code, [this.detail]);
  @override
  String toString() => 'OpenCL $what failed ($code)${detail == null ? '' : ':\n$detail'}';
}

void _check(int code, String what) {
  if (code != clSuccess) throw OpenClException(what, code);
}

/// One GPU (or other OpenCL device).
class GpuDevice {
  final ClHandle platform;
  final ClHandle id;
  final String name;
  final String vendor;
  final String platformName;
  final String version;
  final int computeUnits;
  final int globalMemory;
  final int maxAlloc;
  final int maxWorkGroup;

  const GpuDevice._(this.platform, this.id, this.name, this.vendor, this.platformName, this.version, this.computeUnits,
      this.globalMemory, this.maxAlloc, this.maxWorkGroup);

  @override
  String toString() => '$name ($vendor, ${globalMemory >> 20} MiB, $computeUnits CUs, $version)';
}

/// OpenCL availability and the devices of every platform.
abstract final class OpenCl {
  static bool get available => OpenClApi.instance != null;
  static String? get unavailableReason => OpenClApi.loadError;

  /// GPU devices (all device types when [gpuOnly] is false). Empty when
  /// there is no driver.
  /// Why there are no devices, for diagnostics: the driver failing to
  /// load, or what clGetPlatformIDs returned.
  static String diagnose() {
    final api = OpenClApi.instance;
    if (api == null) return 'OpenCL driver not loaded: ${OpenClApi.loadError}';
    return _scoped((m) {
      final count = m.alloc<Uint32>(4);
      final r = api.getPlatformIDs(0, nullptr, count);
      if (r != clSuccess) return 'clGetPlatformIDs returned $r';
      if (count.value == 0) return 'no OpenCL platform';
      final n = devices(gpuOnly: false).length;
      return '${count.value} platforms, $n devices (${devices().length} GPUs)';
    });
  }

  static List<GpuDevice> devices({bool gpuOnly = true}) {
    final api = OpenClApi.instance;
    if (api == null) return const [];
    return _scoped((m) {
      final count = m.alloc<Uint32>(4);
      if (api.getPlatformIDs(0, nullptr, count) != clSuccess || count.value == 0) return const <GpuDevice>[];
      final n = count.value;
      final platforms = m.alloc<ClHandle>(8 * n);
      _check(api.getPlatformIDs(n, platforms, nullptr), 'clGetPlatformIDs');
      final out = <GpuDevice>[];
      for (var i = 0; i < n; i++) {
        final pl = platforms[i];
        final pname = _platformString(api, m, pl, clPlatformName);
        if (api.getDeviceIDs(pl, gpuOnly ? clDeviceTypeGpu : clDeviceTypeAll, 0, nullptr, count) != clSuccess) continue;
        final dn = count.value;
        final devs = m.alloc<ClHandle>(8 * dn);
        if (api.getDeviceIDs(pl, gpuOnly ? clDeviceTypeGpu : clDeviceTypeAll, dn, devs, nullptr) != clSuccess) continue;
        for (var d = 0; d < dn; d++) {
          final dev = devs[d];
          out.add(GpuDevice._(
            pl,
            dev,
            _deviceString(api, m, dev, clDeviceName),
            _deviceString(api, m, dev, clDeviceVendor),
            pname,
            _deviceString(api, m, dev, clDeviceVersion),
            _deviceInt(api, m, dev, clDeviceMaxComputeUnits, 4),
            _deviceInt(api, m, dev, clDeviceGlobalMemSize, 8),
            _deviceInt(api, m, dev, clDeviceMaxMemAllocSize, 8),
            _deviceInt(api, m, dev, clDeviceMaxWorkGroupSize, 8),
          ));
        }
      }
      return out;
    });
  }

  static String _platformString(OpenClApi api, _Mem m, ClHandle p, int param) {
    final size = m.alloc<Size>(8);
    if (api.getPlatformInfo(p, param, 0, nullptr, size) != clSuccess) return '';
    final buf = m.alloc<Uint8>(size.value);
    api.getPlatformInfo(p, param, size.value, buf.cast(), nullptr);
    return _cString(buf, size.value);
  }

  static String _deviceString(OpenClApi api, _Mem m, ClHandle d, int param) {
    final size = m.alloc<Size>(8);
    if (api.getDeviceInfo(d, param, 0, nullptr, size) != clSuccess) return '';
    final buf = m.alloc<Uint8>(size.value);
    api.getDeviceInfo(d, param, size.value, buf.cast(), nullptr);
    return _cString(buf, size.value);
  }

  static int _deviceInt(OpenClApi api, _Mem m, ClHandle d, int param, int bytes) {
    final v = m.alloc<Uint64>(8)..value = 0;
    if (api.getDeviceInfo(d, param, bytes, v.cast(), nullptr) != clSuccess) return 0;
    return bytes == 4 ? v.cast<Uint32>().value : v.value;
  }

  static String _cString(Pointer<Uint8> p, int max) {
    final b = p.asTypedList(max);
    final end = b.indexOf(0);
    return utf8.decode(b.sublist(0, end < 0 ? max : end), allowMalformed: true).trim();
  }
}

/// A context and command queue on one device. Everything created from it
/// is released by [dispose].
class GpuContext {
  final GpuDevice device;
  final OpenClApi _api;
  final ClHandle _context;
  final ClHandle _queue;
  final List<GpuBuffer> _buffers = [];
  final List<GpuProgram> _programs = [];

  GpuContext._(this.device, this._api, this._context, this._queue);

  factory GpuContext(GpuDevice device) {
    final api = OpenClApi.instance!;
    return _scoped((m) {
      final err = m.alloc<Int32>(4);
      final devs = m.alloc<ClHandle>(8)..[0] = device.id;
      final ctx = api.createContext(nullptr, 1, devs, nullptr, nullptr, err);
      _check(err.value, 'clCreateContext');
      final q = api.createCommandQueue(ctx, device.id, 0, err);
      if (err.value != clSuccess) {
        api.releaseContext(ctx);
        _check(err.value, 'clCreateCommandQueue');
      }
      return GpuContext._(device, api, ctx, q);
    });
  }

  /// Builds OpenCL C [source]; throws with the driver's build log.
  GpuProgram build(String source, {String options = ''}) => _scoped((m) {
        final err = m.alloc<Int32>(4);
        final src = m.alloc<Pointer<Char>>(8)..[0] = m.string(source);
        final prog = _api.createProgramWithSource(_context, 1, src, nullptr, err);
        _check(err.value, 'clCreateProgramWithSource');
        final devs = m.alloc<ClHandle>(8)..[0] = device.id;
        final rc = _api.buildProgram(prog, 1, devs, m.string(options), nullptr, nullptr);
        if (rc != clSuccess) {
          final size = m.alloc<Size>(8);
          _api.getProgramBuildInfo(prog, device.id, clProgramBuildLog, 0, nullptr, size);
          final log = m.alloc<Uint8>(size.value);
          _api.getProgramBuildInfo(prog, device.id, clProgramBuildLog, size.value, log.cast(), nullptr);
          _api.releaseProgram(prog);
          throw OpenClException('clBuildProgram', rc, OpenCl._cString(log, size.value));
        }
        final p = GpuProgram._(this, prog);
        _programs.add(p);
        return p;
      });

  GpuBuffer buffer(int bytes, {int flags = clMemReadWrite}) => _scoped((m) {
        final err = m.alloc<Int32>(4);
        final mem = _api.createBuffer(_context, flags, bytes, nullptr, err);
        _check(err.value, 'clCreateBuffer($bytes bytes)');
        final b = GpuBuffer._(this, mem, bytes);
        _buffers.add(b);
        return b;
      });

  /// Runs [kernel] over [global] work items (1-D) and waits for it.
  void run(GpuKernel kernel, int global, {int? local}) => _scoped((m) {
        final g = m.alloc<Size>(8)..value = global;
        Pointer<Size> l = nullptr;
        if (local != null) l = m.alloc<Size>(8)..value = local;
        _check(_api.enqueueNDRangeKernel(_queue, kernel._handle, 1, nullptr, g, l, 0, nullptr, nullptr), 'clEnqueueNDRangeKernel');
        _check(_api.finish(_queue), 'clFinish');
      });

  void dispose() {
    for (final b in _buffers) {
      _api.releaseMemObject(b._handle);
    }
    for (final p in _programs) {
      p._release();
    }
    _buffers.clear();
    _programs.clear();
    _api.releaseCommandQueue(_queue);
    _api.releaseContext(_context);
  }
}

class GpuBuffer {
  final GpuContext _ctx;
  final ClHandle _handle;
  final int size;
  GpuBuffer._(this._ctx, this._handle, this.size);

  void write(Uint8List data, {int offset = 0}) => _scoped((m) {
        final p = m.alloc<Uint8>(data.length);
        p.asTypedList(data.length).setAll(0, data);
        _check(_ctx._api.enqueueWriteBuffer(_ctx._queue, _handle, 1, offset, data.length, p.cast(), 0, nullptr, nullptr),
            'clEnqueueWriteBuffer');
      });

  Uint8List read(int length, {int offset = 0}) => _scoped((m) {
        final p = m.alloc<Uint8>(length);
        _check(_ctx._api.enqueueReadBuffer(_ctx._queue, _handle, 1, offset, length, p.cast(), 0, nullptr, nullptr),
            'clEnqueueReadBuffer');
        return Uint8List.fromList(p.asTypedList(length));
      });
}

class GpuProgram {
  final GpuContext _ctx;
  final ClHandle _handle;
  final List<GpuKernel> _kernels = [];
  GpuProgram._(this._ctx, this._handle);

  GpuKernel kernel(String name) => _scoped((m) {
        final err = m.alloc<Int32>(4);
        final k = _ctx._api.createKernel(_handle, m.string(name), err);
        _check(err.value, 'clCreateKernel($name)');
        final kernel = GpuKernel._(_ctx, k);
        _kernels.add(kernel);
        return kernel;
      });

  void _release() {
    for (final k in _kernels) {
      _ctx._api.releaseKernel(k._handle);
    }
    _ctx._api.releaseProgram(_handle);
  }
}

class GpuKernel {
  final GpuContext _ctx;
  final ClHandle _handle;
  GpuKernel._(this._ctx, this._handle);

  void setBuffer(int index, GpuBuffer b) => _scoped((m) {
        final p = m.alloc<ClHandle>(8)..value = b._handle;
        _check(_ctx._api.setKernelArg(_handle, index, 8, p.cast()), 'clSetKernelArg($index)');
      });

  void setUint(int index, int v) => _scoped((m) {
        final p = m.alloc<Uint32>(4)..value = v;
        _check(_ctx._api.setKernelArg(_handle, index, 4, p.cast()), 'clSetKernelArg($index)');
      });
}
