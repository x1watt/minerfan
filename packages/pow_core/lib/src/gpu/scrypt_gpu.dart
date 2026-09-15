import 'dart:io' show Platform;
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:gpu_core/gpu_core.dart';

import 'scrypt_cl.dart';

/// scrypt header search on one GPU. Owns a context; call [dispose].
class ScryptGpu {
  final GpuDevice device;
  final GpuContext _ctx;
  late final GpuProgram _program;
  late final GpuKernel _search;
  late final GpuKernel _hash;
  final GpuBuffer _hdr;
  final GpuBuffer _target;
  final GpuBuffer _out;
  late final GpuBuffer _v;

  /// Work items per launch (nonces per batch).
  final int batch;

  static const bytesPerItem = 128 * 1024;

  ScryptGpu._(this.device, this._ctx, this.batch)
      : _hdr = _ctx.buffer(80, flags: clMemReadOnly),
        _target = _ctx.buffer(32, flags: clMemReadOnly),
        _out = _ctx.buffer(4 * 256) {
    _program = _ctx.build(scryptKernelSource);
    _search = _program.kernel('scrypt_search');
    _hash = _program.kernel('scrypt_hash');
    _v = _ctx.buffer(batch * bytesPerItem);
  }

  /// A searcher on [device]; the batch is sized from its memory (the
  /// scratch must fit in one allocation) unless given.
  factory ScryptGpu(GpuDevice device, {int? batch}) {
    // Phone GPUs share the phone's RAM and report a large allocation limit:
    // keep the scratch at 128 MiB there (1024 nonces per launch).
    final mobile = Platform.isAndroid || Platform.isIOS;
    final cap = mobile ? 128 << 20 : device.maxAlloc;
    var b = batch ?? (min(device.maxAlloc, cap) ~/ bytesPerItem);
    b = (b ~/ 256) * 256;
    if (b < 256) b = 256;
    final ctx = GpuContext(device);
    try {
      return ScryptGpu._(device, ctx, b);
    } catch (_) {
      ctx.dispose();
      rethrow;
    }
  }

  static Uint8List _targetWords(BigInt target) {
    final b = Uint8List(32);
    var t = target;
    for (var i = 0; i < 32; i++) {
      b[i] = (t & BigInt.from(0xff)).toInt();
      t >>= 8;
    }
    return b; // little-endian bytes = little-endian words in LE memory
  }

  void _prepare(List<int> header80, BigInt target) {
    // The kernel reads big-endian words, as SHA-256 does.
    final src = ByteData.sublistView(Uint8List.fromList(header80));
    final w = ByteData(80);
    for (var i = 0; i < 20; i++) {
      w.setUint32(i * 4, src.getUint32(i * 4, Endian.big), Endian.host);
    }
    _hdr.write(w.buffer.asUint8List());
    _target.write(_targetWords(target));
  }

  /// Nonces in `[nonce0, nonce0 + batch)` whose scrypt hash of [header80]
  /// (nonce at bytes 76..79) is at or below [target].
  List<int> search(List<int> header80, BigInt target, int nonce0) {
    _prepare(header80, target);
    _out.write(Uint8List(4));
    _search
      ..setBuffer(0, _hdr)
      ..setBuffer(1, _target)
      ..setUint(2, nonce0 & 0xffffffff)
      ..setBuffer(3, _v)
      ..setBuffer(4, _out);
    _ctx.run(_search, batch);
    final out = ByteData.sublistView(_out.read(4 * 256));
    final n = out.getUint32(0, Endian.host);
    return [for (var i = 0; i < n && i < 255; i++) out.getUint32(4 + i * 4, Endian.host)];
  }

  /// The scrypt hashes (32 bytes, as the CPU version returns them) of the
  /// first [count] nonces from [nonce0]; for self-tests.
  List<Uint8List> hashes(List<int> header80, int nonce0, int count) {
    _prepare(header80, BigInt.zero);
    final outBuf = _ctx.buffer(batch * 32);
    _hash
      ..setBuffer(0, _hdr)
      ..setBuffer(1, _target)
      ..setUint(2, nonce0 & 0xffffffff)
      ..setBuffer(3, _v)
      ..setBuffer(4, outBuf);
    _ctx.run(_hash, batch);
    final raw = ByteData.sublistView(outBuf.read(count * 32));
    return [
      for (var i = 0; i < count; i++)
        Uint8List.fromList([
          for (var k = 0; k < 8; k++) ...(ByteData(4)..setUint32(0, raw.getUint32(i * 32 + k * 4, Endian.host), Endian.big)).buffer.asUint8List(),
        ]),
    ];
  }

  void dispose() => _ctx.dispose();
}
