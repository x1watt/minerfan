/// GPU compute through the system's OpenCL driver.
library;

export 'src/opencl.dart' show OpenCl, GpuDevice, GpuContext, GpuBuffer, GpuProgram, GpuKernel, OpenClException;
export 'src/opencl_ffi.dart' show clMemReadOnly, clMemReadWrite, clMemWriteOnly;
