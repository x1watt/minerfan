import 'dart:typed_data';

import 'package:gpu_core/gpu_core.dart';

/// Lists OpenCL devices and runs a tiny kernel on the first GPU.
void main() {
  if (!OpenCl.available) {
    print('no OpenCL: ${OpenCl.unavailableReason}');
    return;
  }
  final devs = OpenCl.devices();
  for (final d in devs) {
    print(d);
  }
  if (devs.isEmpty) return;
  final ctx = GpuContext(devs.first);
  final prog = ctx.build('__kernel void f(__global uint* a) { uint i = get_global_id(0); a[i] = a[i] * 2u + 1u; }');
  final k = prog.kernel('f');
  final buf = ctx.buffer(4 * 1024);
  buf.write(Uint32List.fromList(List<int>.generate(1024, (i) => i)).buffer.asUint8List());
  k.setBuffer(0, buf);
  ctx.run(k, 1024);
  final out = buf.read(4 * 1024).buffer.asUint32List();
  print('kernel ok: ${out[0]} ${out[1]} ${out[1023]} (expect 1 3 2047)');
  ctx.dispose();
}
