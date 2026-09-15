import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:pow_core/pow_core.dart';

import 'address.dart';
import 'bytes.dart';
import 'node.dart';
import 'template.dart';

/// The network's hashrate from the last [window] blocks: their work
/// (difficulty x 2^32 each) over the time they took. Unlike the difficulty
/// alone, this sees blocks coming faster or slower than the target spacing
/// at once (the difficulty needs tens of blocks to follow).
double recentNetworkHashrate(UtxoNode node, {int window = 60}) {
  final c = node.chain;
  final last = c.tipHeight;
  final first = max(c.firstHeight + 1, last - window);
  if (last - first < 5) return CompactTarget.hashrate(c.tipBits, node.params.targetSpacingSeconds);
  var work = 0.0;
  for (var h = first + 1; h <= last; h++) {
    work += CompactTarget.difficulty(c.bitsAt(h)) * 4294967296.0;
  }
  // Timestamps can be out of order by minutes; a floor keeps a burst of
  // bad times from dividing by almost nothing.
  final seconds = max(c.timeAt(last) - c.timeAt(first), (last - first) * 5);
  return work / seconds;
}

/// A block this miner found and broadcast.
class FoundBlock {
  final int height;
  final String hash;
  final int time;

  /// null while pending, then true (in the best chain) or false (orphaned).
  bool? accepted;

  FoundBlock(this.height, this.hash, this.time);

  Map<String, Object?> toJson() => {'height': height, 'hash': hash, 'time': time, 'accepted': accepted};
  static FoundBlock fromJson(Map<String, Object?> m) =>
      FoundBlock(m['height']! as int, m['hash']! as String, m['time']! as int)..accepted = m['accepted'] as bool?;
}

/// Solo mining on a light node: coinbase-only templates on the best tip,
/// paid to [payTo], searched by [miners] (a GPU, CPU threads, or both) at
/// the speed the effort controller allows, and broadcast to all peers when
/// found. Each miner gets its own template (its own extra nonce), so their
/// nonce ranges never overlap.
class SoloMiner {
  final UtxoNode node;
  final Address payTo;
  final EffortController effort;
  final List<HeaderMiner> miners;
  final void Function(String line)? log;
  final List<FoundBlock> found;

  /// Called after [found] changes (a new block, or one settled).
  final void Function()? onFound;

  int _extraNonce = Random.secure().nextInt(1 << 32);
  int _workId = 0;
  final Map<int, BlockTemplate> _templates = {}; // work id -> template
  final List<int> _current = []; // work id per miner
  Timer? _refreshTimer, _effortTimer;
  final List<StreamSubscription<Object?>> _subs = [];
  bool _mining = false;
  Uint8List? _lastTip;
  double duty = 1;

  /// Our share of the last 30 blocks and the factor the fair-share guard
  /// applies (1 when within the target).
  double observedShare = 0;
  double guard = 1;

  /// Upper bound on the duty from outside (a warm phone), 0 to 1.
  double dutyCap = 1;

  SoloMiner({
    required this.node,
    required this.payTo,
    required this.effort,
    required this.miners,
    this.log,
    List<FoundBlock>? found,
    this.onFound,
  }) : found = found ?? [];

  bool get mining => _mining;
  BlockTemplate? get template => _current.isEmpty ? null : _templates[_current.first];

  /// Measured hashrate of all miners together.
  double get hashrate => miners.fold(0.0, (a, m) => a + m.stats.hashrate);

  /// Hashrate of all miners at full duty.
  double get fullSpeed => miners.fold(0.0, (a, m) => a + m.stats.fullSpeed);

  double get networkHashrate => recentNetworkHashrate(node);

  /// Starts every miner that can start; throws when none can.
  Future<void> start() async {
    final ok = <HeaderMiner>[];
    for (final m in miners) {
      try {
        await m.start();
        ok.add(m);
        _subs.add(m.found.listen((f) => _onFound(f)));
        _subs.add(m.errors.listen((e) => log?.call('${m.device}: $e')));
      } catch (e) {
        log?.call('cannot mine on this device: $e');
      }
    }
    miners.retainWhere(ok.contains);
    if (miners.isEmpty) throw StateError('no device could start mining');
    _subs.add(node.tipChanges.listen((_) {
      _checkFound();
      // Header batches that do not move the tip change nothing.
      final tip = node.chain.hashAt(node.chain.tipHeight);
      if (tip != null && _lastTip != null && bytesEqual(tip, _lastTip!) && _mining) return;
      _newWork();
    }));
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) => _newWork());
    _effortTimer = Timer.periodic(const Duration(seconds: 15), (_) => _updateDuty());
    _newWork();
  }

  void _newWork() {
    if (!node.synced) {
      if (_mining) log?.call('waiting for the chain to sync before mining');
      _mining = false;
      for (final m in miners) {
        m.pause();
      }
      return;
    }
    _lastTip = node.chain.hashAt(node.chain.tipHeight);
    _templates.clear();
    _current.clear();
    BlockTemplate? first;
    for (final m in miners) {
      _extraNonce = (_extraNonce + 1) & 0xffffffff;
      final t = BlockTemplate.build(params: node.params, chain: node.chain, payTo: payTo, extraNonce: _extraNonce);
      first ??= t;
      final id = ++_workId;
      _templates[id] = t;
      _current.add(id);
      m.work(MiningWork(id, t.header.serialize(), CompactTarget.decode(t.header.bits)));
    }
    if (!_mining) log?.call('mining block ${first!.height} on ${miners.map((m) => m.device).join(' and ')}');
    _mining = true;
    _updateDuty();
  }

  /// The difficulty follows the network only slowly (Kimoto Gravity Well
  /// needs tens of blocks), so the effort controller alone can overshoot
  /// when blocks come fast. The guard counts our blocks among the last 30
  /// on the chain and slows down in proportion when that share is above
  /// the target, and pauses at twice the target.
  double _fairShareGuard() {
    final target = effort.targetShare;
    if (target >= 1) return 1;
    final c = node.chain;
    final ours = {for (final b in found) b.hash};
    var n = 0, mine = 0;
    for (var h = c.tipHeight; h > c.tipHeight - 30 && h >= c.firstHeight; h--) {
      final id = c.hashAt(h);
      if (id == null) break;
      n++;
      if (ours.contains(hashToHex(id))) mine++;
    }
    observedShare = n == 0 ? 0 : mine / n;
    return fairShareFactor(observedShare, target, n);
  }

  /// 1 within the target (and 20% over it), 0 at twice the target, the
  /// ratio between; no opinion before 10 blocks.
  static double fairShareFactor(double observed, double target, int blocks) {
    if (target >= 1 || blocks < 10 || observed <= target * 1.2) return 1;
    if (observed >= target * 2) return 0;
    return target / observed;
  }

  void _updateDuty() {
    final full = fullSpeed > 0 ? fullSpeed : 500e3;
    guard = _fairShareGuard();
    duty = min(dutyCap, guard * effort.duty(networkHashrate: networkHashrate, fullSpeed: full, currentSpeed: hashrate));
    for (final m in miners) {
      m.setDuty(duty);
    }
  }

  /// Caps the duty (thermal control); takes effect at once.
  void setDutyCap(double cap) {
    dutyCap = cap.clamp(0.0, 1.0);
    _updateDuty();
  }

  /// A new effort (share of the network) takes effect at once.
  void setEffort(double share) {
    effort.targetShare = share;
    _updateDuty();
  }

  void _onFound(FoundNonce f) {
    final t = _templates[f.workId];
    if (t == null) return; // stale work
    final block = t.withNonce(f.nonce);
    final hash = block.header.id;
    if (found.any((b) => b.hash == hash)) return;
    final peers = node.broadcastBlock(block);
    found.add(FoundBlock(t.height, hash, block.header.time));
    log?.call('found block ${t.height} $hash, sent to $peers peers');
    onFound?.call();
    // Mine on top of it now (it is valid); waiting for peers to echo it
    // would have us compete with our own block.
    node.addOwnHeader(block.header);
    Future<void>.delayed(const Duration(seconds: 3), node.refresh);
  }

  void _checkFound() {
    final c = node.chain;
    var changed = false;
    for (final b in found.where((b) => b.accepted == null)) {
      if (b.height < c.firstHeight) continue;
      final at = c.hashAt(b.height);
      if (at != null && hashToHex(at) == b.hash) {
        // Ours count only with two blocks on top (we add them to our own
        // chain at once).
        if (c.tipHeight < b.height + 2) continue;
        b.accepted = true;
        changed = true;
        log?.call('block ${b.height} is in the best chain');
      } else if (c.tipHeight > b.height + 2) {
        b.accepted = false;
        changed = true;
        log?.call('block ${b.height} was orphaned');
      }
    }
    if (changed) onFound?.call();
  }

  Future<void> stop() async {
    _refreshTimer?.cancel();
    _effortTimer?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    for (final m in miners) {
      await m.stop();
    }
  }
}
