import 'dart:async';
import 'dart:io' show File, Platform;

import 'package:net_core/net_core.dart';

import '../monero/address.dart';
import '../monero/block.dart';
import '../monero/difficulty.dart';
import '../monero/light_chain.dart';
import '../p2pool/consensus.dart';
import '../p2pool/merkle.dart';
import '../p2pool/pool_block.dart';
import '../p2pool/sidechain.dart';
import '../p2pool/template.dart';
import '../randomx/cache.dart' show RandomXDataset;
import '../randomx/hash_pool.dart';
import '../randomx/jit/cpu_features.dart';
import '../randomx/jit/vm_jit.dart';
import '../randomx/memory.dart';
import '../util/bytes.dart';
import '../util/reader.dart';
import 'flex.dart';
import 'monero_net.dart';
import 'p2pool_net.dart';
import 'store.dart';
import 'system_load.dart';

class NodeConfig {
  final String wallet;
  final String sidechain; // nano, mini, main
  final int threads;
  final RxMemoryKind memory;
  final bool fastMode;
  final String dataDir;
  final bool mine;

  /// RandomX engine: `auto` (JIT when the CPU supports it and it passes its
  /// self-test), `jit` or `interpreter`.
  final String engine;

  /// Flexible CPU/RAM mining: fewer threads while other programs use the
  /// CPU, fast mode given up and mining paused while they need the memory
  /// (see [FlexGovernor]).
  final bool flexible;

  const NodeConfig({
    required this.wallet,
    this.sidechain = 'mini',
    required this.threads,
    required this.memory,
    this.fastMode = false,
    required this.dataDir,
    this.mine = true,
    this.engine = 'auto',
    this.flexible = true,
  });

  /// Sensible defaults.
  /// - Desktop: shared memory, fast mode and the JIT, one thread per
  ///   physical core (with SMT the second thread of a core mostly competes
  ///   for L3 and TLB).
  /// - Phones: the JIT, fast mode when the phone has 8 GB or more (the pool
  ///   still falls back to light mode if free memory is short when the
  ///   dataset is built), threads from [CpuFeatures.recommendedThreads]:
  ///   every core in light mode, big cores capped by the L3 in fast mode.
  /// - Without the JIT: the pure Dart interpreter with few threads.
  factory NodeConfig.defaults({required String wallet, required String dataDir, String sidechain = 'mini'}) {
    final desktop = Platform.isLinux || Platform.isWindows || Platform.isMacOS;
    final cpus = Platform.numberOfProcessors;
    final shared = RxBuffer.sharedSupported;
    final jit = shared && RandomXJitVM.supported;
    final ram = totalMemoryBytes() ?? 0;
    final fast = jit && (desktop || ram >= (7 << 30)); // 8 GB phones report 7.2 to 7.6 GiB
    int threads;
    if (jit) {
      threads = CpuFeatures.recommendedThreads(fastMode: fast);
    } else {
      threads = desktop ? (cpus > 2 ? cpus - 1 : 1) : (cpus > 4 ? 2 : 1);
    }
    return NodeConfig(
      wallet: wallet,
      sidechain: sidechain,
      threads: threads,
      memory: shared && (desktop || jit) ? RxMemoryKind.shared : RxMemoryKind.dart,
      fastMode: fast,
      dataDir: dataDir,
    );
  }

  Map<String, Object?> toJson() => {
        'wallet': wallet,
        'sidechain': sidechain,
        'threads': threads,
        'memory': memory.name,
        'fastMode': fastMode,
        'dataDir': dataDir,
        'mine': mine,
        'engine': engine,
        'flexible': flexible,
      };

  static NodeConfig fromJson(Map<String, Object?> m) => NodeConfig(
        wallet: m['wallet']! as String,
        sidechain: m['sidechain']! as String,
        threads: m['threads']! as int,
        memory: RxMemoryKind.values.byName(m['memory']! as String),
        fastMode: m['fastMode']! as bool,
        dataDir: m['dataDir']! as String,
        mine: m['mine']! as bool,
        engine: (m['engine'] as String?) ?? 'auto',
        flexible: (m['flexible'] as bool?) ?? true,
      );
}

/// Status snapshot for the UI (plain values so it can cross isolates).
class NodeStatus {
  final String phase;
  final int moneroHeight;
  final int moneroPeers;
  final bool moneroSynced;
  final int sideHeight;
  final int sidePeerHeight;
  final int sidePeers;
  final bool sideSynced;
  final String sideDifficulty;
  final bool mining;
  final double hashrate;
  final int hashes;
  final int threads;
  final int sharesFound;
  final int sharesInWindow;
  final double windowFraction;
  final int estimatedPayoutPerBlock;
  final List<Payout> payouts;
  final List<FoundShare> recentShares;
  final List<String> log;

  /// RandomX engine in use, e.g. `JIT` or `interpreter (reason)`.
  final String engine;

  /// Configured threads ([threads] is how many mine right now).
  final int maxThreads;

  /// What flexible mining holds back and why; empty when nothing.
  final String flexNote;

  const NodeStatus({
    required this.phase,
    required this.moneroHeight,
    required this.moneroPeers,
    required this.moneroSynced,
    required this.sideHeight,
    required this.sidePeerHeight,
    required this.sidePeers,
    required this.sideSynced,
    required this.sideDifficulty,
    required this.mining,
    required this.hashrate,
    required this.hashes,
    required this.threads,
    required this.sharesFound,
    required this.sharesInWindow,
    required this.windowFraction,
    required this.estimatedPayoutPerBlock,
    required this.payouts,
    required this.recentShares,
    required this.log,
    this.engine = '',
    int? maxThreads,
    this.flexNote = '',
  }) : maxThreads = maxThreads ?? threads;

  Map<String, Object?> toJson() => {
        'phase': phase,
        'moneroHeight': moneroHeight,
        'moneroPeers': moneroPeers,
        'moneroSynced': moneroSynced,
        'sideHeight': sideHeight,
        'sidePeerHeight': sidePeerHeight,
        'sidePeers': sidePeers,
        'sideSynced': sideSynced,
        'sideDifficulty': sideDifficulty,
        'mining': mining,
        'hashrate': hashrate,
        'hashes': hashes,
        'threads': threads,
        'sharesFound': sharesFound,
        'sharesInWindow': sharesInWindow,
        'windowFraction': windowFraction,
        'estimatedPayoutPerBlock': estimatedPayoutPerBlock,
        'payouts': [for (final p in payouts) p.toJson()],
        'recentShares': [for (final s in recentShares) s.toJson()],
        'log': log,
        'engine': engine,
        'maxThreads': maxThreads,
        'flexNote': flexNote,
      };

  static NodeStatus fromJson(Map<String, Object?> m) => NodeStatus(
        phase: m['phase']! as String,
        moneroHeight: m['moneroHeight']! as int,
        moneroPeers: m['moneroPeers']! as int,
        moneroSynced: m['moneroSynced']! as bool,
        sideHeight: m['sideHeight']! as int,
        sidePeerHeight: m['sidePeerHeight']! as int,
        sidePeers: m['sidePeers']! as int,
        sideSynced: m['sideSynced']! as bool,
        sideDifficulty: m['sideDifficulty']! as String,
        mining: m['mining']! as bool,
        hashrate: (m['hashrate']! as num).toDouble(),
        hashes: m['hashes']! as int,
        threads: m['threads']! as int,
        sharesFound: m['sharesFound']! as int,
        sharesInWindow: m['sharesInWindow']! as int,
        windowFraction: (m['windowFraction']! as num).toDouble(),
        estimatedPayoutPerBlock: m['estimatedPayoutPerBlock']! as int,
        payouts: [for (final p in m['payouts']! as List) Payout.fromJson(p as Map<String, Object?>)],
        recentShares: [for (final s in m['recentShares']! as List) FoundShare.fromJson(s as Map<String, Object?>)],
        log: (m['log']! as List).cast<String>(),
        engine: (m['engine'] as String?) ?? '',
        maxThreads: m['maxThreads'] as int?,
        flexNote: (m['flexNote'] as String?) ?? '',
      );
}

/// The whole node: Monero light chain, P2Pool sidechain and peers, and the
/// RandomX workers that mine to [NodeConfig.wallet].
class XmrNode {
  final NodeConfig config;
  final Transport transport;
  late final MoneroAddress address;
  late final P2PoolConsensus consensus;
  late final NodeStore store;
  late final MoneroLightChain chain;
  late final SideChain sidechain;
  late final HashPool hashes;
  late final MoneroNet monero;
  late final P2PoolNet p2pool;
  late final TemplateBuilder builder;

  final List<String> _log = [];
  String? _engineNote;

  String get _engine {
    if (hashes.jitActive) return 'JIT';
    final why = hashes.jitDisabledReason ?? _engineNote;
    return why == null ? 'interpreter' : 'interpreter ($why)';
  }

  /// Present while the JIT has not yet passed its first self-test; found at
  /// start it means the process died there, and `auto` then avoids the JIT.
  late final File _jitGuard = File('${config.dataDir}/jit_guard');

  final List<Payout> _payouts = [];
  final List<FoundShare> _shares = [];
  bool _mining = false;
  bool _miningWanted;
  BlockTemplate? _template;
  int _jobId = 0;
  Timer? _saveTimer, _templateTimer, _flexTimer;
  FlexGovernor? _flex;
  CpuTimes? _lastCpu;
  late int _thermalCap = config.threads;
  String _phase = 'starting';
  StreamSubscription<FoundResult>? _foundSub;

  XmrNode(this.config, {Transport? transport})
      : transport = transport ?? IoTransport(),
        _miningWanted = config.mine;

  void _logLine(String s) {
    final line = '${DateTime.now().toIso8601String().substring(11, 19)} $s';
    _log.add(line);
    if (_log.length > 300) _log.removeAt(0);
  }

  Future<void> start() async {
    final a = MoneroAddress.parse(config.wallet);
    if (a == null || a.network != MoneroNetwork.mainnet || a.kind != AddressKind.standard) {
      throw ArgumentError('a mainnet primary address (starting with 4) is required');
    }
    address = a;
    consensus = P2PoolConsensus.byName(config.sidechain);
    store = NodeStore(config.dataDir);
    chain = store.loadChain() ?? MoneroLightChain.fromCheckpoint();
    _payouts.addAll(store.loadPayouts());
    _shares.addAll(store.loadShares());
    sidechain = SideChain(consensus, chain)..log = _logLine;
    builder = TemplateBuilder(sidechain, address.spendKey, address.viewKey);

    var useJit = config.engine != 'interpreter' && config.memory == RxMemoryKind.shared;
    final guard = _jitGuard;
    if (useJit && config.engine == 'auto' && guard.existsSync()) {
      useJit = false;
      _engineNote = 'the JIT was turned off because the previous start ended during its self-test';
      _logLine('RandomX: $_engineNote; choose the JIT engine in settings to try again');
    }
    if (useJit && RandomXJitVM.supported) {
      try {
        guard.writeAsStringSync('${DateTime.now().toIso8601String()}\n');
      } catch (_) {}
    }
    hashes = HashPool(workers: config.threads, memory: config.memory, fastMode: config.fastMode, jit: useJit)
      ..log = _logLine
      ..onJitSelfTest = (ok, detail) {
        _logLine('RandomX JIT self-test: ${ok ? 'passed' : 'failed'} ($detail)');
        try {
          if (guard.existsSync()) guard.deleteSync();
        } catch (_) {}
      };
    if (useJit && !hashes.jitActive) {
      _engineNote = config.memory == RxMemoryKind.shared ? 'this CPU or OS cannot run the JIT' : 'the JIT needs shared memory';
    }
    _logLine('RandomX engine: ${hashes.jitActive ? 'JIT (${CpuFeatures.current})' : 'interpreter'}');
    _phase = 'starting RandomX workers';
    await hashes.start();
    _foundSub = hashes.found.listen(_onFound);

    monero = MoneroNet(transport, chain, hashes, log: _logLine)
      ..onSynced = _onMoneroSynced
      ..onNewTip = _onMoneroTip;
    monero.addKnownPeers(store.loadPeers('monero_peers.txt').map((p) => '${p.$1}:${p.$2}'));
    p2pool = P2PoolNet(transport, consensus, sidechain, chain, hashes, log: _logLine)
      ..onMoneroBlockFound = _onShareIsMoneroBlock;
    p2pool.addKnownPeers(store.loadPeers('p2pool_${consensus.name}_peers.txt').map((p) => '${p.$1}:${p.$2}'));
    sidechain.onNewTip = (_) => _refreshTemplate();

    _phase = 'syncing Monero headers';
    _logLine('node starting: ${consensus.name} sidechain, ${config.threads} threads, '
        '${config.memory.name} memory${config.fastMode ? ', fast mode' : ''}');
    monero.start();
    _saveTimer = Timer.periodic(const Duration(minutes: 2), (_) => _save());
    _templateTimer = Timer.periodic(const Duration(seconds: 20), (_) => _refreshTemplate());
    _startFlex();
  }

  /// Flexible CPU/RAM mining: samples the machine every 2 s.
  void _startFlex() {
    if (!config.flexible) return;
    final shared = config.memory == RxMemoryKind.shared;
    final g = _flex = FlexGovernor(config.threads, datasetBytes: config.fastMode && shared ? RandomXDataset.words * 8 : 0);
    final total = totalMemoryBytes();
    // Build the dataset only with room to keep it (the same rule as for
    // taking it back): a dataset given back seconds after a build wastes
    // all cores for those seconds.
    if (total != null) hashes.datasetHeadroom = FlexGovernor.lowMark(total) + (1 << 30);
    _lastCpu = SystemLoad.cpuTimes();
    _logLine('flexible mining: on (${_lastCpu == null ? 'memory only: this OS does not show other programs\' CPU use' : 'CPU and memory'})');
    var lastMemory = '';
    var lastRetryMs = DateTime.now().millisecondsSinceEpoch;
    _flexTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      final now = SystemLoad.cpuTimes();
      final prev = _lastCpu;
      _lastCpu = now;
      final wasThreads = g.threads, wasDataset = g.datasetWanted;
      g.update(
        FlexReading(
          otherCores: now != null && prev != null ? SystemLoad.otherCores(prev, now, Platform.numberOfProcessors) : null,
          availableBytes: availableMemoryBytes(),
          totalBytes: total,
        ),
        DateTime.now().millisecondsSinceEpoch,
      );
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (g.datasetWanted != wasDataset) {
        unawaited(hashes.setDatasetEnabled(g.datasetWanted));
      } else if (g.datasetWanted && g.datasetRoom && !hashes.hasDataset && nowMs - lastRetryMs >= 180000) {
        // Fast mode started without room for the dataset; there is now.
        lastRetryMs = nowMs;
        unawaited(hashes.retryDataset());
      }
      if (g.threads != wasThreads) _applyThreads();
      if (g.memoryNote != lastMemory) _logLine('flexible mining: ${g.memoryNote.isEmpty ? 'memory is fine again' : g.memoryNote}');
      lastMemory = g.memoryNote;
    });
  }

  /// Mining threads: the lower of thermal control and flexible mining.
  void _applyThreads() {
    final flex = _flex?.threads ?? config.threads;
    final v = (flex < _thermalCap ? flex : _thermalCap).clamp(0, config.threads);
    if (v == hashes.activeWorkers) return;
    final why = [
      if (_thermalCap < config.threads) 'thermal',
      if (flex < config.threads) _flex!.note,
    ].join('; ');
    _logLine('mining threads: $v of ${config.threads}${why.isEmpty ? '' : ' ($why)'}');
    hashes.setActiveWorkers(v);
  }

  Future<void> _onMoneroSynced() async {
    _phase = 'syncing P2Pool sidechain';
    try {
      final md = chain.minerData;
      if (md != null) await hashes.setSeed(md.seedHash);
      _loadShareCache();
      await p2pool.start();
    } catch (e) {
      _logLine('p2pool start failed: $e');
    }
  }

  void _onMoneroTip(MoneroBlock b) {
    _checkPayout(b);
    _refreshTemplate();
  }

  /// A P2Pool-found Monero block pays every wallet in its window; record our
  /// part. The coinbase commits to the share through its merge mining root.
  void _checkPayout(MoneroBlock b) {
    try {
      final tags = ExtraTag.parseAll(b.minerTx.extra);
      final mm = tags.where((t) => t.tag == extraTagMergeMining).firstOrNull;
      if (mm == null) return;
      final tag = MergeMiningTag.read(ByteReader(mm.data));
      final share = sidechain.byMerkleRoot(tag.rootHash);
      if (share == null) return;
      var amount = 0;
      for (var i = 0; i < b.minerTx.outputs.length; i++) {
        final (key, _) = sidechain.derivations.ephemeral(address.spendKey, address.viewKey, share.side.txPrivateKey, i);
        if (bytesEqual(key, b.minerTx.outputs[i].key)) amount += b.minerTx.outputs[i].amount;
      }
      _logLine('P2Pool found Monero block ${b.height}; our payout ${amount / 1e12} XMR');
      if (amount > 0) {
        _payouts.add(Payout(b.height, b.header.timestamp, amount, toHex(b.id())));
        store.savePayouts(_payouts);
      }
    } catch (_) {}
  }

  /// Start mining once both chains are synced; keep mining through short
  /// catch-ups (a share being verified, a peer a few shares ahead).
  bool get _ready {
    if (!_miningWanted || !monero.synced || sidechain.tip == null) return false;
    return _mining ? p2pool.behind <= 10 : p2pool.synced;
  }

  Future<void> _refreshTemplate() async {
    if (!_ready) {
      if (_mining) {
        hashes.pause();
        _mining = false;
      }
      return;
    }
    final md = chain.minerData;
    if (md == null) return;
    try {
      final tpl = builder.build(md);
      await hashes.setSeed(md.seedHash);
      _template = tpl;
      _jobId++;
      final diff = tpl.sidechainDifficulty < tpl.mainchainDifficulty ? tpl.sidechainDifficulty : tpl.mainchainDifficulty;
      hashes.mine(MiningJob(_jobId, tpl.hashingBlob, tpl.nonceOffset, targetForDifficulty(diff), md.seedHash));
      if (!_mining) _logLine('mining started at side height ${tpl.block.side.height}, difficulty ${tpl.sidechainDifficulty}');
      _mining = true;
      _phase = 'mining';
    } catch (e) {
      _logLine('template error: $e');
    }
  }

  void _onFound(FoundResult r) {
    final tpl = _template;
    if (tpl == null || r.jobId != _jobId) return;
    if (!checkPow(r.hash, tpl.sidechainDifficulty)) return;
    final share = tpl.finish(r.nonce);
    share.powHash = r.hash;
    final isBlock = checkPow(r.hash, tpl.mainchainDifficulty);
    final res = p2pool.submitOwnShare(share);
    final id = toHex(share.templateId(consensus));
    _logLine('found share at side height ${share.side.height}'
        '${isBlock ? ' (also a Monero block!)' : ''}: ${res.isOk ? 'accepted' : res.invalid ?? res.cantVerify}');
    _shares.add(FoundShare(share.side.height, share.main.genHeight, share.main.timestamp, id));
    store.saveShares(_shares);
    if (isBlock) _onShareIsMoneroBlock(share);
    _template = null;
    unawaited(_refreshTemplate());
  }

  void _onShareIsMoneroBlock(PoolBlock share) {
    monero.submitBlock(share.main.moneroBlob(), share.main.genHeight);
  }

  /// Threads thermal control allows; the rest stay idle.
  void setActiveThreads(int n) {
    _thermalCap = n.clamp(0, config.threads);
    _applyThreads();
  }

  void setMining(bool on) {
    _miningWanted = on;
    unawaited(_refreshTemplate());
  }

  NodeStatus status() {
    final tip = sidechain.tip;
    var inWindow = 0;
    var fraction = 0.0;
    var estimate = 0;
    if (tip != null) {
      try {
        final shares = sidechain.getShares(tip);
        var total = BigInt.zero, ours = BigInt.zero;
        for (final s in shares) {
          total += s.weight;
          if (bytesEqual(s.spend, address.spendKey) && bytesEqual(s.view, address.viewKey)) ours += s.weight;
        }
        if (total > BigInt.zero) {
          fraction = ours / total;
          estimate = (BigInt.from(tailEmissionReward) * ours ~/ total).toInt();
        }
        for (PoolBlock? b = tip; b != null && tip.side.height - b.side.height < consensus.chainWindowSize; b = sidechain.parentOf(b)) {
          if (bytesEqual(b.side.spendKey, address.spendKey)) inWindow++;
        }
      } catch (_) {}
    }
    final st = hashes.stats;
    return NodeStatus(
      phase: _phase,
      moneroHeight: chain.tipHeight,
      moneroPeers: monero.peerCount,
      moneroSynced: monero.synced,
      sideHeight: tip?.side.height ?? 0,
      sidePeerHeight: p2pool.bestPeerHeight,
      sidePeers: p2pool.peerCount,
      sideSynced: p2pool.synced,
      sideDifficulty: sidechain.difficulty.toString(),
      mining: _mining,
      hashrate: st.hashrate,
      hashes: st.hashes,
      threads: hashes.activeWorkers,
      maxThreads: config.threads,
      sharesFound: _shares.length,
      sharesInWindow: inWindow,
      windowFraction: fraction,
      estimatedPayoutPerBlock: estimate,
      payouts: List.of(_payouts),
      recentShares: _shares.length > 20 ? _shares.sublist(_shares.length - 20) : List.of(_shares),
      log: List.of(_log.length > 100 ? _log.sublist(_log.length - 100) : _log),
      engine: _engine,
      flexNote: _flex?.note ?? '',
    );
  }

  String get _shareCacheName => 'shares_${consensus.name}_compact.bin';
  String get _oldShareCacheName => 'shares_${consensus.name}.bin';

  /// Shares saved by this node after it verified them; they are re-added
  /// without repeating verification, and new shares from peers build on them.
  /// Stored in compact form (transactions as indices into the parent's
  /// list), oldest first, so each parent is known before its child.
  void _loadShareCache() {
    final clock = Stopwatch()..start();
    var blobs = store.loadShareCache(_shareCacheName);
    final compact = blobs.isNotEmpty;
    if (!compact) blobs = store.loadShareCache(_oldShareCacheName);
    var blocks = <PoolBlock>[];
    for (final blob in blobs) {
      try {
        blocks.add(PoolBlock.parse(blob, consensus, compact: compact));
      } catch (_) {}
    }
    if (compact) {
      blocks.sort((a, b) => a.side.height.compareTo(b.side.height));
      final byId = <String, PoolBlock>{};
      final ready = <PoolBlock>[];
      for (final b in blocks) {
        if (b.main.txParentIndices.any((p) => p != 0)) {
          final parent = byId[toHex(b.side.parent)];
          if (parent == null || !b.fillCompactFrom(parent)) continue;
        } else {
          b.main.txParentIndices = [];
        }
        byId[toHex(b.templateId(consensus))] = b;
        ready.add(b);
      }
      blocks = ready;
    }
    final added = sidechain.addTrusted([for (final b in blocks) if (!sidechain.blockSeen(b)) b]);
    if (blobs.isNotEmpty) {
      _logLine('loaded $added of ${blobs.length} cached shares in ${clock.elapsedMilliseconds} ms, '
          'tip ${sidechain.tip?.side.height ?? '-'}');
    }
  }

  /// The share cache is tens of MB (mostly coinbase outputs); written hourly
  /// and on stop so phones do not rewrite it every few minutes.
  int _lastShareCacheMs = 0;

  void _save({bool force = false}) {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      if ((force || now - _lastShareCacheMs > 3600000) && sidechain.tip != null) {
        _lastShareCacheMs = now;
        final blocks = sidechain.allBlocks.where((b) => b.verified && !b.invalid).toList()
          ..sort((a, b) => a.side.height.compareTo(b.side.height));
        store.saveShareCache(_shareCacheName, blocks.map((b) => b.serializeCompactAgainst(sidechain.parentOf(b))));
        store.remove(_oldShareCacheName);
      }
      store.saveChain(chain);
      store.savePeers('monero_peers.txt', monero.knownPeers.map(_split));
      store.savePeers('p2pool_${consensus.name}_peers.txt', p2pool.knownPeers.map(_split));
    } catch (e) {
      _logLine('save failed: $e');
    }
  }

  static (String, int) _split(String k) {
    final i = k.lastIndexOf(':');
    return (k.substring(0, i), int.parse(k.substring(i + 1)));
  }

  Future<void> stop() async {
    try {
      if (_jitGuard.existsSync()) _jitGuard.deleteSync();
    } catch (_) {}
    _saveTimer?.cancel();
    _templateTimer?.cancel();
    _flexTimer?.cancel();
    await _foundSub?.cancel();
    // Workers first: they are the heavy part, and if the handle's deadline
    // killed this isolate before, they would keep mining unowned.
    await hashes.stop();
    _save(force: true);
    await p2pool.stop();
    await monero.stop();
  }
}

/// Status summaries for payouts per day (UTC dates).
Map<String, int> payoutsPerDay(List<Payout> payouts) {
  final out = <String, int>{};
  for (final p in payouts) {
    final d = DateTime.fromMillisecondsSinceEpoch(p.timestamp * 1000, isUtc: true).toIso8601String().substring(0, 10);
    out[d] = (out[d] ?? 0) + p.amount;
  }
  return out;
}
