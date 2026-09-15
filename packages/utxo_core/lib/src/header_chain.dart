import 'dart:io';
import 'dart:typed_data';

import 'package:pow_core/pow_core.dart';

import 'block.dart';
import 'bytes.dart';
import 'params.dart';

/// Where a light chain starts: the hash of a final block, and the `nBits`
/// and time of the blocks up to it, as many as the retarget reads.
class HeaderCheckpoint {
  final int height;
  final Uint8List hash;
  final List<int> bits; // heights height - bits.length + 1 .. height
  final List<int> times;

  const HeaderCheckpoint({required this.height, required this.hash, required this.bits, required this.times});

  int get firstHeight => height - bits.length + 1;
}

class HeaderRejected implements Exception {
  final String reason;
  const HeaderRejected(this.reason);
  @override
  String toString() => 'header rejected: $reason';
}

/// A header-only chain from a checkpoint: every header must link, carry
/// the `nBits` the retarget demands, meet its target with the chain's PoW,
/// and have a sane time. On forks the branch with the most work wins.
class HeaderChain implements HeaderHistory {
  final ChainParams params;
  final HeaderPow _pow;
  final List<int> _bits = [];
  final List<int> _times = [];
  final List<Uint8List?> _hashes = [];
  final List<BigInt> _work = []; // cumulative from the first stored height
  int _first;

  /// How many heights to keep behind the tip (the retarget window and a
  /// margin for reorganizations).
  final int keep;

  HeaderChain(this.params, HeaderCheckpoint cp, {int? keep})
      : _pow = params.pow(),
        _first = cp.firstHeight,
        keep = keep ?? params.retarget.window + 1000 {
    var work = BigInt.zero;
    for (var i = 0; i < cp.bits.length; i++) {
      _bits.add(cp.bits[i]);
      _times.add(cp.times[i]);
      _hashes.add(i == cp.bits.length - 1 ? cp.hash : null);
      // Work counts from the first stored height; only differences matter.
      work += workOf(cp.bits[i]);
      _work.add(work);
    }
  }

  @override
  int get firstHeight => _first;
  int get tipHeight => _first + _bits.length - 1;
  Uint8List get tipHash => _hashes.last!;
  int get tipTime => _times.last;
  int get tipBits => _bits.last;
  BigInt get tipWork => _work.last;

  @override
  int bitsAt(int height) => _bits[height - _first];
  @override
  int timeAt(int height) => _times[height - _first];
  Uint8List? hashAt(int height) =>
      height < _first || height > tipHeight ? null : _hashes[height - _first];

  Map<String, int>? _index;

  /// Height of a known block hash.
  int? heightOf(Uint8List hash) {
    final index = _index ??= {
      for (var i = 0; i < _hashes.length; i++)
        if (_hashes[i] != null) toHex(_hashes[i]!): _first + i,
    };
    return index[toHex(hash)];
  }

  /// Block locator: the last 10 hashes, then exponentially sparser.
  List<Uint8List> locator() {
    final out = <Uint8List>[];
    var step = 1;
    for (var h = tipHeight; h >= _first; h -= step) {
      final x = hashAt(h);
      if (x == null) break;
      out.add(x);
      if (out.length >= 10) step *= 2;
    }
    return out;
  }

  static BigInt workOf(int bits) {
    final t = CompactTarget.decode(bits);
    return t <= BigInt.zero ? BigInt.zero : (BigInt.one << 256) ~/ (t + BigInt.one);
  }

  /// Adds headers that continue the chain (or a branch of it). Returns how
  /// many became part of the best chain; throws [HeaderRejected] on the
  /// first invalid one (the caller should drop the peer that sent it).
  int add(List<BlockHeader> headers, {int? nowSeconds}) {
    if (headers.isEmpty) return 0;
    final now = nowSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final parent = heightOf(headers.first.prevHash);
    if (parent == null) throw const HeaderRejected('does not connect to our chain');
    // Build the branch on top of `parent` in scratch lists, then keep it if
    // it has more work than what it replaces.
    final branch = _Branch(this, parent);
    for (final h in headers) {
      final height = branch.tipHeight + 1;
      if (!bytesEqual(h.prevHash, branch.tipHash)) throw const HeaderRejected('headers not in sequence');
      final want = params.retarget.next(branch, height - 1);
      if (h.bits != want) {
        throw HeaderRejected('bits ${h.bits.toRadixString(16)} at $height, retarget says ${want.toRadixString(16)}');
      }
      if (!CompactTarget.meets(_pow.hash(h.serialize()), CompactTarget.decode(h.bits))) {
        throw HeaderRejected('proof of work too weak at $height');
      }
      if (h.time <= branch.medianTimePast()) throw HeaderRejected('time not above the median at $height');
      if (h.time > now + params.maxFutureSeconds) throw HeaderRejected('time too far in the future at $height');
      branch.push(h);
    }
    if (branch.tipWork <= tipWork) return 0;
    _truncate(parent);
    for (var i = 0; i < branch.bits.length; i++) {
      _bits.add(branch.bits[i]);
      _times.add(branch.times[i]);
      _hashes.add(branch.hashes[i]);
      _work.add(branch.works[i]);
    }
    _index = null;
    _prune();
    return branch.bits.length;
  }

  void _truncate(int height) {
    _index = null;
    final n = height - _first + 1;
    _bits.length = n;
    _times.length = n;
    _hashes.length = n;
    _work.length = n;
  }

  void _prune() {
    final extra = _bits.length - keep;
    if (extra <= 0) return;
    _index = null;
    _bits.removeRange(0, extra);
    _times.removeRange(0, extra);
    _hashes.removeRange(0, extra);
    _work.removeRange(0, extra);
    _first += extra;
  }

  // ---- persistence ----

  /// `first height | count | (bits, time, has hash, hash?) ...`; work is
  /// recomputed on load.
  Uint8List serialize() {
    final w = ByteWriter()
      ..u32(_first)
      ..u32(_bits.length);
    for (var i = 0; i < _bits.length; i++) {
      w
        ..u32(_bits[i])
        ..u32(_times[i]);
      final h = _hashes[i];
      w.u8(h == null ? 0 : 1);
      if (h != null) w.bytes(h);
    }
    return w.take();
  }

  /// Restores a saved chain if it continues [cp]; null otherwise.
  static HeaderChain? restore(ChainParams params, HeaderCheckpoint cp, Uint8List data, {int? keep}) {
    try {
      final r = ByteReader(data);
      final first = r.u32();
      final n = r.u32();
      final bits = <int>[], times = <int>[];
      final hashes = <Uint8List?>[];
      for (var i = 0; i < n; i++) {
        bits.add(r.u32());
        times.add(r.u32());
        hashes.add(r.u8() == 1 ? r.bytes(32) : null);
      }
      final tip = first + n - 1;
      if (tip < cp.height || first > cp.height) return null;
      final at = hashes[cp.height - first];
      if (at == null || !bytesEqual(at, cp.hash)) return null;
      final c = HeaderChain(params, cp, keep: keep);
      c._first = first;
      c._bits
        ..clear()
        ..addAll(bits);
      c._times
        ..clear()
        ..addAll(times);
      c._hashes
        ..clear()
        ..addAll(hashes);
      c._work.clear();
      c._index = null;
      var work = BigInt.zero;
      for (final b in bits) {
        work += workOf(b);
        c._work.add(work);
      }
      return c;
    } on FormatException {
      return null;
    }
  }

  void save(File f) {
    final tmp = File('${f.path}.tmp');
    tmp.writeAsBytesSync(serialize(), flush: true);
    tmp.renameSync(f.path);
  }
}

/// A candidate branch on top of a height of the chain.
class _Branch implements HeaderHistory {
  final HeaderChain base;
  final int parent;
  final List<int> bits = [], times = [];
  final List<Uint8List> hashes = [];
  final List<BigInt> works = [];

  _Branch(this.base, this.parent);

  int get tipHeight => parent + bits.length;
  Uint8List get tipHash => hashes.isEmpty ? base.hashAt(parent)! : hashes.last;
  BigInt get tipWork => works.isEmpty ? base._work[parent - base._first] : works.last;

  @override
  int get firstHeight => base.firstHeight;
  @override
  int bitsAt(int h) => h <= parent ? base.bitsAt(h) : bits[h - parent - 1];
  @override
  int timeAt(int h) => h <= parent ? base.timeAt(h) : times[h - parent - 1];

  int medianTimePast() {
    final ts = <int>[for (var h = tipHeight; h > tipHeight - 11 && h >= firstHeight; h--) timeAt(h)]..sort();
    return ts[ts.length ~/ 2];
  }

  void push(BlockHeader h) {
    bits.add(h.bits);
    times.add(h.time);
    hashes.add(h.hash);
    works.add(tipWork + HeaderChain.workOf(h.bits));
  }
}
