import 'dart:async';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:typed_data';

import '../util/bytes.dart';
import 'cache.dart';
import 'jit/vm_jit.dart';
import 'memory.dart';
import 'vm.dart';

/// Long-lived RandomX worker isolates.
///
/// Workers mine the current job in small batches and yield between hashes so
/// new jobs, seed changes and verification requests are picked up quickly.
/// Verification requests (PoW of shares received from peers) run before
/// mining work.
///
/// With [RxMemoryKind.shared] one cache (and optionally the 2080 MiB
/// dataset) is built once and every worker attaches to it by address. With
/// [RxMemoryKind.dart] each worker builds its own 256 MiB cache.
///
/// With [jit] (shared memory only) workers run RandomX programs as machine
/// code generated at run time (port of xmrig's JIT) and the dataset is built
/// with compiled SuperscalarHash. Worker 0 checks the JIT against the
/// interpreter at every seed; a mismatch switches all workers back to the
/// interpreter.

class MiningJob {
  final int jobId;
  final Uint8List blob;
  final int nonceOffset;

  /// Share target as P2Pool/xmrig use it: a hash qualifies when the
  /// little-endian u64 of bytes 24..31 is <= [target64] (unsigned).
  final int target64;
  final Uint8List seed;
  final bool v2;

  const MiningJob(this.jobId, this.blob, this.nonceOffset, this.target64, this.seed, {this.v2 = false});
}

class FoundResult {
  final int jobId;
  final int nonce;
  final Uint8List hash;
  const FoundResult(this.jobId, this.nonce, this.hash);
}

class HashPoolStats {
  final int hashes;
  final int workers;
  final double hashrate;
  const HashPoolStats(this.hashes, this.workers, this.hashrate);
}

/// Target for a difficulty: the largest u64 t with hash64 <= t meeting it.
int targetForDifficulty(BigInt difficulty) {
  if (difficulty <= BigInt.one) return -1; // 0xffff...ffff
  final t = ((BigInt.one << 64) - BigInt.one) ~/ difficulty;
  return t.toUnsigned(64).toSigned(64).toInt();
}

class HashPool {
  final int workers;
  final RxMemoryKind memory;
  final bool fastMode;

  final List<SendPort> _ports = [];
  final List<Isolate> _isolates = [];
  final ReceivePort _inbox = ReceivePort();
  final StreamController<FoundResult> _found = StreamController.broadcast();
  final Map<int, Completer<Uint8List>> _verify = {};
  final Map<String, Completer<void>> _seedReady = {};
  final List<Completer<void>> _ready = [];
  int _nextRequest = 1;
  int _verifyTurn = 0;
  int _hashes = 0;
  final Stopwatch _clock = Stopwatch()..start();
  int _lastHashes = 0;
  int _lastMs = 0;
  double _hashrate = 0;

  // Shared-memory seeds: seed hex -> cache address (and dataset address).
  final Map<String, (RandomXCache, RandomXDataset?)> _shared = {};
  String? _currentSeed;

  /// Worker indexes holding each seed.
  final Map<String, Set<int>> _holders = {};

  /// Progress notes (fast mode dataset, memory fallback).
  void Function(String)? log;

  /// Result of each JIT self-test (worker 0, once per seed).
  void Function(bool ok, String detail)? onJitSelfTest;

  final bool jit;
  bool _jitDisabled = false;
  String? jitDisabledReason;

  HashPool({required this.workers, this.memory = RxMemoryKind.dart, this.fastMode = false, this.jit = false});

  /// Whether workers use the JIT (requested, supported, not disabled).
  late final bool _jitSupported = jit && memory == RxMemoryKind.shared && RandomXJitVM.supported;
  bool get jitActive => _jitSupported && !_jitDisabled;

  Stream<FoundResult> get found => _found.stream;

  Future<void> start() async {
    _inbox.listen(_onMessage);
    for (var i = 0; i < workers; i++) {
      final ready = Completer<void>();
      _ready.add(ready);
      _isolates.add(await Isolate.spawn(_workerMain, [_inbox.sendPort, i, workers], debugName: 'rx-$i'));
      await ready.future;
    }
    // Check the JIT right away (no seed needed), so a JIT fault shows up
    // within a second of starting rather than after the chains sync.
    if (jitActive) _ports[0].send(['selfTestNow']);
  }

  void _onMessage(Object? m) {
    final msg = m! as List<Object?>;
    switch (msg[0]) {
      case 'ready':
        _ports.add(msg[2]! as SendPort);
        _ready[msg[1]! as int].complete();
      case 'found':
        _found.add(FoundResult(msg[1]! as int, msg[2]! as int, msg[3]! as Uint8List));
      case 'hashes':
        _hashes += msg[1]! as int;
      case 'verified':
        _verify.remove(msg[1]! as int)?.complete(msg[2]! as Uint8List);
      case 'seedReady':
        _seedReady[msg[1]! as String]?.complete();
      case 'exited':
        _exited.remove(msg[1]! as int);
        if (_exited.isEmpty && !_allExited.isCompleted) _allExited.complete();
      case 'error':
        _verify.remove(msg[1]! as int)?.completeError(StateError(msg[2]! as String));
      case 'selfTest':
        final ok = msg[1]! as bool;
        final detail = msg[2]! as String;
        onJitSelfTest?.call(ok, detail);
        if (!ok && !_jitDisabled) {
          _jitDisabled = true;
          jitDisabledReason = detail;
          log?.call('JIT self-test failed ($detail): using the interpreter');
          // Re-seed every worker with interpreter VMs.
          unawaited(_serial(() async {
            for (final key in _shared.keys.toList()) {
              if (_holders[key]?.isNotEmpty ?? false) await _seedOnWorkers(key, _sharedMsg(key));
            }
          }));
        }
    }
  }

  HashPoolStats get stats {
    final now = _clock.elapsedMilliseconds;
    if (now - _lastMs >= 2000) {
      _hashrate = (_hashes - _lastHashes) * 1000 / (now - _lastMs);
      _lastHashes = _hashes;
      _lastMs = now;
    }
    return HashPoolStats(_hashes, workers, _hashrate);
  }

  Future<void> _seedLock = Future.value();

  /// Runs seed operations one at a time: concurrent preparation of the same
  /// seed would race on the per-worker completion handles.
  Future<void> _serial(Future<void> Function() op) {
    final next = _seedLock.then((_) => _stopped ? null : op());
    _seedLock = next.catchError((Object _) {});
    return next;
  }

  /// Prepares [seed] on every worker (cache, and dataset in fast mode).
  Future<void> setSeed(Uint8List seed, {bool mining = true}) => _serial(() => _setSeed(seed, mining: mining));

  Future<void> _setSeed(Uint8List seed, {required bool mining}) async {
    final key = toHex(seed);
    if (mining && _currentSeed == key) return;
    if (memory == RxMemoryKind.shared) {
      var entry = _shared[key];
      if (entry == null) {
        entry = (RandomXCache.attach(seed, await _buildSharedCache(seed)), null);
        _shared[key] = entry;
        await _trimShared(key);
      }
      // Workers start on the cache (light mode); in fast mode the dataset is
      // built afterwards and the workers switch to it when it is ready.
      await _seedOnWorkers(key, _sharedMsg(key));
      if (mining) {
        final previous = _currentSeed;
        _currentSeed = key;
        if (previous != null) await _dropDataset(previous);
        if (fastMode && entry.$2 == null && !_datasetOff) unawaited(_serial(() => _buildDataset(key)));
      }
    } else {
      await _seedOnWorkers(key, ['seedBuild', seed]);
      if (mining) _currentSeed = key;
    }
  }

  List<Object?> _sharedMsg(String key) {
    final (cache, ds) = _shared[key]!;
    return ['seedShared', Uint8List.fromList(cache.key), cache.buffer.address, ds?.buffer.address, jitActive];
  }

  /// Keeps the current and one other seed in shared memory.
  Future<void> _trimShared(String keep) async {
    while (_shared.length > 2) {
      final old = _shared.keys.firstWhere((k) => k != keep && k != _currentSeed, orElse: () => '');
      if (old.isEmpty) return;
      // Workers must let go of the memory before it is freed.
      await _sendAll('drop:$old', ['dropSeed', old]);
      _holders.remove(old);
      final (c, d) = _shared.remove(old)!;
      c.free();
      d?.free();
    }
  }

  /// Builds the 2080 MiB dataset for the mining seed, unless the free memory
  /// would not hold it (then mining stays in light mode).
  Future<void> _buildDataset(String key) async {
    final entry = _shared[key];
    if (entry == null || entry.$2 != null || key != _currentSeed || _datasetOff) return;
    const bytes = RandomXDataset.words * 8;
    final avail = availableMemoryBytes();
    if (avail != null && avail < bytes + datasetHeadroom) {
      log?.call('fast mode needs ${(bytes + datasetHeadroom) >> 20} MiB free, ${avail >> 20} MiB available: staying in light mode');
      return;
    }
    final clock = Stopwatch()..start();
    final ds = RandomXDataset.allocate(RxMemoryKind.shared);
    const items = RandomXDataset.words ~/ 8;
    // Chunks of a few seconds each, so stop() never waits long.
    const chunk = 1 << 17;
    var next = 0;
    final seed = Uint8List.fromList(entry.$1.key);
    JitDatasetInit? jitInit;
    if (jitActive) {
      try {
        jitInit = JitDatasetInit.build(entry.$1);
      } catch (e) {
        log?.call('JIT dataset init unavailable: $e');
      }
    }
    final ji = jitInit;
    Future<void> lane() async {
      while (!_stopped && next < items) {
        final start = next;
        next = start + chunk > items ? items : start + chunk;
        if (ji != null) {
          await _initDatasetRangeJit(ji.initAddress, ji.cacheSlot, ds.buffer.address, start, next);
        } else {
          await _initDatasetRange(seed, entry.$1.buffer.address, ds.buffer.address, start, next);
        }
      }
    }

    // Helper isolates beyond the mining threads: the dataset is needed once
    // and all cores can build it.
    final lanes = Platform.numberOfProcessors > workers ? Platform.numberOfProcessors : workers;
    await Future.wait([for (var w = 0; w < lanes; w++) lane()]);
    ji?.free();
    if (_stopped || key != _currentSeed || !_shared.containsKey(key) || _datasetOff) {
      ds.free();
      return;
    }
    _shared[key] = (entry.$1, ds);
    await _seedOnWorkers(key, _sharedMsg(key));
    log?.call('fast mode dataset ready in ${(clock.elapsedMilliseconds / 1000).toStringAsFixed(1)} s');
  }

  bool _datasetOff = false;

  /// Memory that must stay free besides the dataset for it to be built.
  int datasetHeadroom = 1 << 30;

  /// Whether the mining seed has its fast-mode dataset now.
  bool get hasDataset => _shared[_currentSeed]?.$2 != null;

  /// Gives the fast-mode dataset of the mining seed back to the OS (false):
  /// workers move to the cache (light mode) and keep mining, and the memory
  /// is freed once they all let go of it. True builds it again. For
  /// flexible mining, when other programs need the memory.
  Future<void> setDatasetEnabled(bool on) => _serial(() async {
        if (!fastMode || memory != RxMemoryKind.shared || _datasetOff == !on) return;
        _datasetOff = !on;
        final key = _currentSeed;
        final entry = key == null ? null : _shared[key];
        if (key == null || entry == null) return;
        if (!on && entry.$2 != null) {
          _shared[key] = (entry.$1, null);
          await _seedOnWorkers(key, _sharedMsg(key));
          entry.$2!.free();
          log?.call('fast mode dataset given back (${(RandomXDataset.words * 8) >> 20} MiB): mining in light mode');
        } else if (on && entry.$2 == null) {
          await _buildDataset(key);
        }
      });

  /// Builds the mining seed's dataset if fast mode has none yet (for example
  /// after a start without room for it).
  Future<void> retryDataset() => _serial(() async {
        final key = _currentSeed;
        if (fastMode && !_datasetOff && key != null) await _buildDataset(key);
      });

  /// Moves workers of a seed that is no longer mined back to its cache and
  /// frees its dataset; late shares of that seed are verified in light mode.
  Future<void> _dropDataset(String key) async {
    final entry = _shared[key];
    if (entry == null || entry.$2 == null || key == _currentSeed) return;
    _shared[key] = (entry.$1, null);
    await _seedOnWorkers(key, _sharedMsg(key));
    entry.$2!.free();
  }

  Future<void> _seedOnWorkers(String key, List<Object?> msg, [Iterable<int>? only]) async {
    final targets = (only ?? List<int>.generate(_ports.length, (i) => i)).toList();
    await _sendAll(key, msg, targets);
    (_holders[key] ??= {}).addAll(targets);
    // Workers keep two seeds; forget holders beyond the two newest.
    while (_holders.length > 3) {
      _holders.remove(_holders.keys.first);
    }
  }

  /// Sends [msg] plus a reply tag to [targets] (all workers by default) and
  /// waits until each has processed it.
  Future<void> _sendAll(String tag, List<Object?> msg, [List<int>? targets]) async {
    final futures = <Future<void>>[];
    for (final i in targets ?? List<int>.generate(_ports.length, (i) => i)) {
      final c = Completer<void>();
      final k = '$tag/$i';
      _seedReady[k] = c;
      _ports[i].send([...msg, k]);
      futures.add(c.future);
    }
    await Future.wait(futures);
    _seedReady.removeWhere((k, _) => k.startsWith('$tag/'));
  }

  /// Starts mining [job] on all workers (replaces the previous job). Nonces
  /// are split so workers never overlap.
  void mine(MiningJob job) {
    _job = job;
    final active = activeWorkers;
    for (var i = 0; i < _ports.length; i++) {
      if (i < active) {
        _ports[i].send(['job', job.jobId, job.blob, job.nonceOffset, job.target64, toHex(job.seed), job.v2, i, active]);
      } else {
        _ports[i].send(['pause']);
      }
    }
  }

  MiningJob? _job;
  int? _activeWorkers;

  /// Workers that mine (the others stay idle but still verify shares). Used
  /// to shed heat on phones without restarting anything; nonces stay
  /// disjoint because the job is re-split over the active workers.
  int get activeWorkers => (_activeWorkers ?? workers).clamp(0, _ports.isEmpty ? workers : _ports.length);

  void setActiveWorkers(int n) {
    final v = n.clamp(0, workers);
    if (v == activeWorkers && _activeWorkers != null) return;
    _activeWorkers = v;
    final job = _job;
    if (job != null) mine(job);
  }

  void pause() {
    _job = null;
    _broadcast(['pause']);
  }

  /// RandomX hash of [blob] with [seed], computed on a worker that already
  /// holds that seed (call [setSeed] first for new seeds).
  Future<Uint8List> hash(Uint8List seed, Uint8List blob, {bool v2 = false}) {
    final id = _nextRequest++;
    final c = Completer<Uint8List>();
    _verify[id] = c;
    final holders = _holders[toHex(seed)]?.toList() ?? const <int>[];
    final idx = holders.isEmpty ? 0 : holders[_verifyTurn++ % holders.length];
    _ports[idx].send(['verify', id, toHex(seed), blob, v2]);
    return c.future;
  }

  /// True if some worker can hash with [seed].
  bool hasSeed(Uint8List seed) => _holders[toHex(seed)]?.isNotEmpty ?? false;

  /// Makes [seed] available for verification without changing the mining
  /// seed. With private memory only worker 0 builds it (256 MiB); with shared
  /// memory every worker attaches to one copy.
  Future<void> addVerificationSeed(Uint8List seed) => _serial(() async {
        if (hasSeed(seed)) return;
        if (memory == RxMemoryKind.shared) {
          await _setSeed(seed, mining: false);
        } else {
          await _seedOnWorkers(toHex(seed), ['seedBuild', seed], const [0]);
        }
      });

  void _broadcast(List<Object?> msg) {
    for (final p in _ports) {
      p.send(msg);
    }
  }

  bool _stopped = false;
  final Set<int> _exited = {};
  final Completer<void> _allExited = Completer();

  Future<void> stop() async {
    // Seed work reads shared memory from helper isolates: let it finish
    // (dataset builds end at the next chunk) before freeing anything.
    _stopped = true;
    await _seedLock;
    // Workers leave their loop after the hash in progress. That hash runs
    // in native code (about 100 ms in light mode on a phone) where
    // Isolate.kill cannot stop it, so wait for every worker's ack before
    // freeing the cache and dataset it reads.
    _exited.addAll(List.generate(_ports.length, (i) => i));
    if (_exited.isEmpty) _allExited.complete();
    _broadcast(['exit']);
    var clean = true;
    await _allExited.future.timeout(const Duration(seconds: 10), onTimeout: () => clean = false);
    for (final i in _isolates) {
      i.kill(priority: Isolate.immediate);
    }
    _inbox.close();
    if (clean) {
      for (final (c, d) in _shared.values) {
        c.free();
        d?.free();
      }
    } else {
      // A worker may still be inside a hash: leaking is safe, freeing is not.
      log?.call('mining workers did not exit in time: leaving their memory allocated');
    }
    _shared.clear();
  }
}

// ---- isolate entry points (top level so closures capture only values) ----

Future<int> _buildSharedCache(Uint8List seed) =>
    Isolate.run(() => RandomXCache.create(seed, kind: RxMemoryKind.shared).buffer.address);

Future<void> _initDatasetRange(Uint8List seed, int cacheAddr, int dsAddr, int start, int end) => Isolate.run(() {
      if (start < end) RandomXDataset.attach(dsAddr).init(RandomXCache.attach(seed, cacheAddr), start, end);
    });

Future<void> _initDatasetRangeJit(int initAddr, int cacheSlot, int dsAddr, int start, int end) => Isolate.run(() {
      if (start < end) JitDatasetInit.initRange(initAddr, cacheSlot, dsAddr, start, end);
    });

// ---- worker isolate --------------------------------------------------------

Future<void> _workerMain(List<Object?> args) async {
  final out = args[0]! as SendPort;
  final index = args[1]! as int;
  final inbox = ReceivePort();
  out.send(['ready', index, inbox.sendPort]);

  final vms = <String, RandomXHasher>{};
  final verifyQueue = <List<Object?>>[];
  List<Object?>? job;
  var nonce = 0;
  var step = 1;
  var running = true;
  var pending = 0;
  var wake = Completer<void>();
  final hashOut = Uint8List(32);
  final sinceReport = Stopwatch()..start();
  Uint8List? blob;
  final selfTestRef = <String, Uint8List>{};

  RandomXHasher vmFor(String seedHex, bool v2) {
    final vm = vms[seedHex];
    if (vm == null) throw StateError('seed $seedHex not prepared');
    vm.v2 = v2;
    return vm;
  }

  void put(String key, RandomXHasher vm) {
    final old = vms[key];
    vms[key] = vm;
    if (old != null && !identical(old, vm)) old.free();
  }

  /// Worker 0 compares the JIT with the interpreter once per seed and mode.
  RandomXHasher checked(RandomXHasher jitVm, String key, Uint8List seed, int cacheAddr, bool fast) {
    if (index != 0) return jitVm;
    final input = Uint8List.fromList([...'xmr-dart JIT self-test'.codeUnits, ...seed]);
    final ref = selfTestRef[key] ??= RandomXVM.light(RandomXCache.attach(seed, cacheAddr)).hash(input);
    final got = jitVm.hash(input);
    final ok = bytesEqual(got, ref);
    out.send(['selfTest', ok, ok ? '${fast ? 'fast' : 'light'} mode matches the interpreter' : '${fast ? 'fast' : 'light'} mode hash ${toHex(got)} != ${toHex(ref)}']);
    if (ok) return jitVm;
    jitVm.free();
    return RandomXVM.light(RandomXCache.attach(seed, cacheAddr));
  }

  inbox.listen((m) {
    final msg = m! as List<Object?>;
    switch (msg[0]) {
      case 'seedBuild':
        final seed = msg[1]! as Uint8List;
        final key = toHex(seed);
        vms.putIfAbsent(key, () => RandomXVM.light(RandomXCache.create(seed)));
        while (vms.length > 2) {
          vms.remove(vms.keys.first)?.free();
        }
        out.send(['seedReady', msg[2]]);
      case 'seedShared':
        final seed = msg[1]! as Uint8List;
        final key = toHex(seed);
        final cacheAddr = msg[2]! as int;
        final dsAddr = msg[3] as int?;
        final useJit = msg[4]! as bool;
        RandomXHasher? vm;
        if (useJit) {
          try {
            final j = dsAddr != null
                ? RandomXJitVM.fast(RandomXDataset.attach(dsAddr), index: index)
                : RandomXJitVM.light(RandomXCache.attach(seed, cacheAddr), index: index);
            vm = checked(j, key, seed, cacheAddr, dsAddr != null);
          } catch (e) {
            if (index == 0) out.send(['selfTest', false, 'JIT unavailable: $e']);
          }
        }
        vm ??= dsAddr != null
            ? RandomXVM.fast(RandomXDataset.attach(dsAddr))
            : RandomXVM.light(RandomXCache.attach(seed, cacheAddr));
        put(key, vm);
        out.send(['seedReady', msg[5]]);
      case 'selfTestNow':
        // JIT and interpreter on the same untouched 256 MiB buffer (reads
        // see zeros; no Argon2 needed) must agree, in light mode.
        final key = Uint8List.fromList('xmr-dart startup self-test'.codeUnits);
        final buf = RxBuffer.allocate(RandomXCache.words, RxMemoryKind.shared);
        try {
          final c = RandomXCache.attach(key, buf.address);
          final input = Uint8List.fromList(List.generate(76, (i) => i * 7));
          final ref = RandomXVM.light(c).hash(input);
          final j = RandomXJitVM.light(c, index: index);
          final got = j.hash(input);
          j.free();
          final ok = bytesEqual(got, ref);
          out.send(['selfTest', ok, ok ? 'startup check matches the interpreter' : 'startup check ${toHex(got)} != ${toHex(ref)}']);
        } catch (e) {
          out.send(['selfTest', false, 'JIT unavailable: $e']);
        } finally {
          buf.free();
        }
      case 'dropSeed':
        vms.remove(msg[1])?.free();
        selfTestRef.remove(msg[1]);
        out.send(['seedReady', msg[2]]);
      case 'job':
        job = msg;
        blob = Uint8List.fromList(msg[2]! as Uint8List);
        nonce = msg[7]! as int;
        step = msg[8]! as int;
      case 'pause':
        job = null;
      case 'verify':
        verifyQueue.add(msg);
      case 'exit':
        running = false;
        for (final vm in vms.values) {
          vm.free();
        }
        vms.clear();
        inbox.close();
    }
    if (!wake.isCompleted) wake.complete();
  });

  while (running) {
    if (verifyQueue.isNotEmpty) {
      final v = verifyQueue.removeAt(0);
      try {
        final h = vmFor(v[2]! as String, v[4]! as bool).hash(v[3]! as Uint8List);
        out.send(['verified', v[1], h]);
      } catch (e) {
        out.send(['error', v[1], '$e']);
      }
    } else if (job != null) {
      final j = job!;
      final b = blob!;
      final off = j[3]! as int;
      final target = j[4]! as int;
      RandomXHasher? vm;
      try {
        vm = vmFor(j[5]! as String, j[6]! as bool);
      } catch (_) {
        job = null;
      }
      if (vm != null) {
        // A few hashes per turn of the event loop: new jobs and
        // verification requests are still picked up within milliseconds.
        final sw = Stopwatch()..start();
        do {
          writeU32LE(b, off, nonce);
          vm.hashInto(b, hashOut, 0);
          pending++;
          final h64 = readU64LE(hashOut, 24);
          if ((h64 ^ 0x8000000000000000) <= (target ^ 0x8000000000000000)) {
            out.send(['found', j[1], nonce, Uint8List.fromList(hashOut)]);
          }
          nonce = (nonce + step) & 0xffffffff;
        } while (sw.elapsedMicroseconds < 5000);
        if (pending >= 64 || sinceReport.elapsedMilliseconds >= 500) {
          out.send(['hashes', pending]);
          pending = 0;
          sinceReport.reset();
        }
      }
    } else {
      if (pending > 0) {
        out.send(['hashes', pending]);
        pending = 0;
      }
      wake = Completer<void>();
      await wake.future;
      continue;
    }
    // Yield so control messages are processed between hashes.
    await Future<void>.delayed(Duration.zero);
  }
  // Out of native code for good: the pool may free the shared memory.
  out.send(['exited', index]);
}
