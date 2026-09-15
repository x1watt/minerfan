// Bindings to the OpenCL 1.2 C API through dart:ffi. The library is the
// system's OpenCL loader (installed with the GPU driver); nothing is bundled.

import 'dart:ffi';
import 'dart:io' show Platform;

typedef ClHandle = Pointer<Void>;

// Constants from CL/cl.h.
const clSuccess = 0;
const clDeviceTypeGpu = 1 << 2;
const clDeviceTypeAll = 0xffffffff;
const clPlatformName = 0x0902;
const clPlatformVendor = 0x0903;
const clPlatformVersion = 0x0901;
const clDeviceName = 0x102B;
const clDeviceVendor = 0x102C;
const clDeviceVersion = 0x102F;
const clDriverVersion = 0x102D;
const clDeviceMaxComputeUnits = 0x1002;
const clDeviceMaxWorkGroupSize = 0x1004;
const clDeviceGlobalMemSize = 0x101F;
const clDeviceMaxMemAllocSize = 0x1010;
const clProgramBuildLog = 0x1183;
const clMemReadWrite = 1 << 0;
const clMemWriteOnly = 1 << 1;
const clMemReadOnly = 1 << 2;

DynamicLibrary _open() {
  if (Platform.isWindows) return DynamicLibrary.open('OpenCL.dll');
  if (Platform.isMacOS) return DynamicLibrary.open('/System/Library/Frameworks/OpenCL.framework/OpenCL');
  if (Platform.isAndroid) {
    // Vendors that let apps use OpenCL list libOpenCL.so in
    // /vendor/etc/public.libraries.txt (Mali, Adreno phones).
    Object? first;
    for (final name in ['libOpenCL.so', '/vendor/lib64/libOpenCL.so', '/system/vendor/lib64/libOpenCL.so']) {
      try {
        return DynamicLibrary.open(name);
      } catch (e) {
        first ??= e;
      }
    }
    throw first!;
  }
  try {
    return DynamicLibrary.open('libOpenCL.so.1');
  } on ArgumentError {
    return DynamicLibrary.open('libOpenCL.so');
  }
}

/// The OpenCL entry points, looked up on first use.
class OpenClApi {
  static OpenClApi? _instance;
  static Object? _loadError;

  /// The API, or null when no OpenCL driver is installed.
  static OpenClApi? get instance {
    if (_instance != null || _loadError != null) return _instance;
    try {
      _instance = OpenClApi._(_open());
    } catch (e) {
      _loadError = e;
    }
    return _instance;
  }

  static String? get loadError => _loadError?.toString();

  OpenClApi._(DynamicLibrary l)
      : getPlatformIDs = l.lookupFunction<Int32 Function(Uint32, Pointer<ClHandle>, Pointer<Uint32>),
            int Function(int, Pointer<ClHandle>, Pointer<Uint32>)>('clGetPlatformIDs'),
        getPlatformInfo = l.lookupFunction<Int32 Function(ClHandle, Uint32, Size, Pointer<Void>, Pointer<Size>),
            int Function(ClHandle, int, int, Pointer<Void>, Pointer<Size>)>('clGetPlatformInfo'),
        getDeviceIDs = l.lookupFunction<Int32 Function(ClHandle, Uint64, Uint32, Pointer<ClHandle>, Pointer<Uint32>),
            int Function(ClHandle, int, int, Pointer<ClHandle>, Pointer<Uint32>)>('clGetDeviceIDs'),
        getDeviceInfo = l.lookupFunction<Int32 Function(ClHandle, Uint32, Size, Pointer<Void>, Pointer<Size>),
            int Function(ClHandle, int, int, Pointer<Void>, Pointer<Size>)>('clGetDeviceInfo'),
        createContext = l.lookupFunction<
            ClHandle Function(Pointer<IntPtr>, Uint32, Pointer<ClHandle>, Pointer<Void>, Pointer<Void>, Pointer<Int32>),
            ClHandle Function(Pointer<IntPtr>, int, Pointer<ClHandle>, Pointer<Void>, Pointer<Void>, Pointer<Int32>)>('clCreateContext'),
        createCommandQueue = l.lookupFunction<ClHandle Function(ClHandle, ClHandle, Uint64, Pointer<Int32>),
            ClHandle Function(ClHandle, ClHandle, int, Pointer<Int32>)>('clCreateCommandQueue'),
        createProgramWithSource = l.lookupFunction<
            ClHandle Function(ClHandle, Uint32, Pointer<Pointer<Char>>, Pointer<Size>, Pointer<Int32>),
            ClHandle Function(ClHandle, int, Pointer<Pointer<Char>>, Pointer<Size>, Pointer<Int32>)>('clCreateProgramWithSource'),
        buildProgram = l.lookupFunction<
            Int32 Function(ClHandle, Uint32, Pointer<ClHandle>, Pointer<Char>, Pointer<Void>, Pointer<Void>),
            int Function(ClHandle, int, Pointer<ClHandle>, Pointer<Char>, Pointer<Void>, Pointer<Void>)>('clBuildProgram'),
        getProgramBuildInfo = l.lookupFunction<Int32 Function(ClHandle, ClHandle, Uint32, Size, Pointer<Void>, Pointer<Size>),
            int Function(ClHandle, ClHandle, int, int, Pointer<Void>, Pointer<Size>)>('clGetProgramBuildInfo'),
        createKernel = l.lookupFunction<ClHandle Function(ClHandle, Pointer<Char>, Pointer<Int32>),
            ClHandle Function(ClHandle, Pointer<Char>, Pointer<Int32>)>('clCreateKernel'),
        createBuffer = l.lookupFunction<ClHandle Function(ClHandle, Uint64, Size, Pointer<Void>, Pointer<Int32>),
            ClHandle Function(ClHandle, int, int, Pointer<Void>, Pointer<Int32>)>('clCreateBuffer'),
        setKernelArg = l.lookupFunction<Int32 Function(ClHandle, Uint32, Size, Pointer<Void>),
            int Function(ClHandle, int, int, Pointer<Void>)>('clSetKernelArg'),
        enqueueWriteBuffer = l.lookupFunction<
            Int32 Function(ClHandle, ClHandle, Uint32, Size, Size, Pointer<Void>, Uint32, Pointer<ClHandle>, Pointer<ClHandle>),
            int Function(ClHandle, ClHandle, int, int, int, Pointer<Void>, int, Pointer<ClHandle>, Pointer<ClHandle>)>('clEnqueueWriteBuffer'),
        enqueueReadBuffer = l.lookupFunction<
            Int32 Function(ClHandle, ClHandle, Uint32, Size, Size, Pointer<Void>, Uint32, Pointer<ClHandle>, Pointer<ClHandle>),
            int Function(ClHandle, ClHandle, int, int, int, Pointer<Void>, int, Pointer<ClHandle>, Pointer<ClHandle>)>('clEnqueueReadBuffer'),
        enqueueNDRangeKernel = l.lookupFunction<
            Int32 Function(ClHandle, ClHandle, Uint32, Pointer<Size>, Pointer<Size>, Pointer<Size>, Uint32, Pointer<ClHandle>, Pointer<ClHandle>),
            int Function(ClHandle, ClHandle, int, Pointer<Size>, Pointer<Size>, Pointer<Size>, int, Pointer<ClHandle>, Pointer<ClHandle>)>(
            'clEnqueueNDRangeKernel'),
        finish = l.lookupFunction<Int32 Function(ClHandle), int Function(ClHandle)>('clFinish'),
        releaseMemObject = l.lookupFunction<Int32 Function(ClHandle), int Function(ClHandle)>('clReleaseMemObject'),
        releaseKernel = l.lookupFunction<Int32 Function(ClHandle), int Function(ClHandle)>('clReleaseKernel'),
        releaseProgram = l.lookupFunction<Int32 Function(ClHandle), int Function(ClHandle)>('clReleaseProgram'),
        releaseCommandQueue = l.lookupFunction<Int32 Function(ClHandle), int Function(ClHandle)>('clReleaseCommandQueue'),
        releaseContext = l.lookupFunction<Int32 Function(ClHandle), int Function(ClHandle)>('clReleaseContext');

  final int Function(int, Pointer<ClHandle>, Pointer<Uint32>) getPlatformIDs;
  final int Function(ClHandle, int, int, Pointer<Void>, Pointer<Size>) getPlatformInfo;
  final int Function(ClHandle, int, int, Pointer<ClHandle>, Pointer<Uint32>) getDeviceIDs;
  final int Function(ClHandle, int, int, Pointer<Void>, Pointer<Size>) getDeviceInfo;
  final ClHandle Function(Pointer<IntPtr>, int, Pointer<ClHandle>, Pointer<Void>, Pointer<Void>, Pointer<Int32>) createContext;
  final ClHandle Function(ClHandle, ClHandle, int, Pointer<Int32>) createCommandQueue;
  final ClHandle Function(ClHandle, int, Pointer<Pointer<Char>>, Pointer<Size>, Pointer<Int32>) createProgramWithSource;
  final int Function(ClHandle, int, Pointer<ClHandle>, Pointer<Char>, Pointer<Void>, Pointer<Void>) buildProgram;
  final int Function(ClHandle, ClHandle, int, int, Pointer<Void>, Pointer<Size>) getProgramBuildInfo;
  final ClHandle Function(ClHandle, Pointer<Char>, Pointer<Int32>) createKernel;
  final ClHandle Function(ClHandle, int, int, Pointer<Void>, Pointer<Int32>) createBuffer;
  final int Function(ClHandle, int, int, Pointer<Void>) setKernelArg;
  final int Function(ClHandle, ClHandle, int, int, int, Pointer<Void>, int, Pointer<ClHandle>, Pointer<ClHandle>) enqueueWriteBuffer;
  final int Function(ClHandle, ClHandle, int, int, int, Pointer<Void>, int, Pointer<ClHandle>, Pointer<ClHandle>) enqueueReadBuffer;
  final int Function(ClHandle, ClHandle, int, Pointer<Size>, Pointer<Size>, Pointer<Size>, int, Pointer<ClHandle>, Pointer<ClHandle>)
      enqueueNDRangeKernel;
  final int Function(ClHandle) finish;
  final int Function(ClHandle) releaseMemObject;
  final int Function(ClHandle) releaseKernel;
  final int Function(ClHandle) releaseProgram;
  final int Function(ClHandle) releaseCommandQueue;
  final int Function(ClHandle) releaseContext;
}
