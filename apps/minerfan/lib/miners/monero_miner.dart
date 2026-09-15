import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xmr_core/xmr_core.dart';

import '../app_controller.dart';
import '../format.dart' as fmt;
import '../mining_service.dart';
import 'miner.dart';

/// Monero settings (`settings.json`, the app's original file).
class MoneroSettings {
  String wallet;
  String sidechain;
  int threads;
  RxMemoryKind memory;
  bool fastMode;
  String engine; // auto, jit, interpreter

  MoneroSettings({
    this.wallet = '',
    this.sidechain = 'mini',
    required this.threads,
    required this.memory,
    this.fastMode = false,
    this.engine = 'auto',
  });

  Map<String, Object?> toJson() => {
        'wallet': wallet,
        'sidechain': sidechain,
        'threads': threads,
        'memory': memory.name,
        'fastMode': fastMode,
        'engine': engine,
      };

  static MoneroSettings defaults() {
    final d = NodeConfig.defaults(wallet: '', dataDir: '');
    return MoneroSettings(threads: d.threads, memory: d.memory, fastMode: d.fastMode);
  }

  static MoneroSettings fromJson(Map<String, Object?> m) {
    final d = defaults();
    return MoneroSettings(
      wallet: (m['wallet'] as String?) ?? '',
      sidechain: (m['sidechain'] as String?) ?? 'mini',
      threads: (m['threads'] as int?) ?? d.threads,
      memory: RxMemoryKind.values.asNameMap()[m['memory']] ?? d.memory,
      fastMode: (m['fastMode'] as bool?) ?? d.fastMode,
      engine: (m['engine'] as String?) ?? 'auto',
    );
  }
}

/// Monero on P2Pool: our own P2Pool node and Monero light peer in a node
/// isolate, RandomX workers mining to the wallet.
class MoneroMiner extends Miner {
  final AppController app;
  MoneroSettings settings = MoneroSettings.defaults();
  NodeHandle? _node;
  NodeStatus? status;
  String? error;
  bool _starting = false;
  StreamSubscription<NodeStatus>? _sub;
  StreamSubscription<String>? _errSub;
  int _lastNotificationMs = 0;
  Timer? _thermalTimer;
  ThermalGovernor? _governor;

  MoneroMiner(this.app);

  @override
  String get id => 'monero';
  @override
  String get name => 'Monero';
  @override
  String get symbol => 'XMR';
  @override
  String get detail => 'P2Pool ${settings.sidechain}';
  @override
  bool get running => _node != null;
  @override
  bool get starting => _starting;
  @override
  bool get canStart => walletValid;
  @override
  String? get problem => walletValid ? error : 'Set a Monero address in this miner\'s settings';
  @override
  double get hashrate => running ? (status?.hashrate ?? 0) : 0;

  @override
  String get statusLine {
    final s = status;
    if (_starting) return 'Starting';
    if (!running) return walletValid ? 'Stopped' : 'Not set up';
    if (s == null) return 'Starting';
    if (!s.mining) return '${s.phase[0].toUpperCase()}${s.phase.substring(1)}';
    if (s.threads == 0) return 'Paused (${thermalNote != null ? 'phone too hot' : 'other programs busy'})';
    return 'Mining on ${s.threads == s.maxThreads ? '${s.threads}' : '${s.threads} of ${s.maxThreads}'} threads';
  }

  /// Where P2Pool pays: the address in the settings, else the app's own
  /// Monero wallet (P2Pool pays primary addresses only).
  String get payoutAddress {
    final typed = settings.wallet.trim();
    if (typed.isNotEmpty) return typed;
    return app.moneroAppWallet?.address ?? '';
  }

  /// Whether the payout goes to the app's own wallet.
  bool get paysAppWallet => settings.wallet.trim().isEmpty && app.moneroAppWallet != null;

  /// P2Pool payouts the node has seen for the payout address.
  @override
  MinedTotal? get mined {
    final p = status?.payouts;
    if (p == null) return null;
    return MinedTotal(p.fold<int>(0, (a, x) => a + x.amount) / 1e12, symbol, p.length, 'payouts');
  }

  bool get walletValid {
    final a = MoneroAddress.parse(payoutAddress);
    return a != null && a.network == MoneroNetwork.mainnet && a.kind == AddressKind.standard;
  }

  File get _file => File('${app.dataDir}/settings.json');

  /// Loads the settings; returns the raw file (older app-wide keys live
  /// there too) or null.
  Map<String, Object?>? load() {
    try {
      if (!_file.existsSync()) return null;
      final m = jsonDecode(_file.readAsStringSync()) as Map<String, Object?>;
      settings = MoneroSettings.fromJson(m);
      return m;
    } catch (_) {
      return null;
    }
  }

  void save() {
    try {
      Directory(app.dataDir).createSync(recursive: true);
      _file.writeAsStringSync(jsonEncode(settings.toJson()));
    } catch (_) {}
    notifyListeners();
  }

  /// What thermal control is doing, when it holds threads back.
  String? get thermalNote {
    final g = _governor;
    if (g == null || g.threads >= g.maxThreads) return null;
    return g.threads == 0 ? 'Paused: the phone is too hot' : 'Phone is warm: ${g.threads} of ${g.maxThreads} threads';
  }

  /// The last thermal reading, for display.
  String get thermalReading => _governor?.last.toString() ?? '';

  @override
  Future<void> start() async {
    if (running || _starting || !walletValid) return;
    _starting = true;
    error = null;
    notifyListeners();
    try {
      final power = app.settings.power;
      final threads = power == PowerProfile.eco ? (settings.threads + 1) ~/ 2 : settings.threads;
      final config = NodeConfig(
        wallet: payoutAddress,
        sidechain: settings.sidechain,
        threads: threads,
        memory: settings.memory,
        fastMode: settings.fastMode && settings.memory == RxMemoryKind.shared,
        dataDir: '${app.dataDir}/${settings.sidechain}',
        engine: settings.engine,
        flexible: power != PowerProfile.performance,
      );
      final node = await NodeHandle.spawn(config);
      _node = node;
      await app.minerStarted('Starting the Monero node');
      _startThermalControl(node, config.threads);
      _sub = node.status.listen((s) {
        status = s;
        _updateNotification(s);
        notifyListeners();
      });
      _errSub = node.errors.listen((e) {
        error = e;
        notifyListeners();
      });
    } catch (e) {
      error = '$e';
    } finally {
      _starting = false;
      notifyListeners();
    }
  }

  @override
  Future<void> stop() async {
    final n = _node;
    if (n == null) return;
    _node = null;
    await _sub?.cancel();
    await _errSub?.cancel();
    _thermalTimer?.cancel();
    _thermalTimer = null;
    _governor = null;
    await n.stop();
    status = null;
    await app.minerStopped();
    notifyListeners();
  }

  void setMining(bool on) => _node?.setMining(on);

  /// Every 10 s: read the phone's thermal state and set the mining threads
  /// (Android; see ThermalGovernor).
  void _startThermalControl(NodeHandle node, int threads) {
    _thermalTimer?.cancel();
    _governor = null;
    if (!MiningService.supported || !app.settings.thermalControl) return;
    final g = _governor = ThermalGovernor(threads);
    _thermalTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      final r = await MiningService.thermal();
      if (r == null || _node != node) return;
      final before = g.threads;
      final after = g.update(r, DateTime.now().millisecondsSinceEpoch);
      if (after != before) {
        node.setActiveThreads(after);
        notifyListeners();
      }
    });
  }

  /// Keeps the Android notification current, at most every 10 seconds.
  void _updateNotification(NodeStatus s) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastNotificationMs < 10000) return;
    _lastNotificationMs = now;
    String text;
    if (!s.mining) {
      text = 'Monero: ${s.phase}';
    } else if (s.threads == 0) {
      text = thermalNote != null
          ? 'Monero paused while the phone is too hot'
          : 'Monero paused while other apps need the ${s.flexNote.contains('memory') ? 'memory' : 'CPU'}';
    } else {
      final why = thermalNote != null ? 'phone warm' : (s.flexNote.isNotEmpty ? 'other apps busy' : null);
      final of = s.threads < s.maxThreads ? '${s.threads} of ${s.maxThreads} threads${why == null ? '' : ' ($why)'}' : '${s.threads} threads';
      text = 'Monero at ${fmt.hashrate(s.hashrate)} on $of, P2Pool ${settings.sidechain}';
    }
    final paid = s.payouts.fold<int>(0, (a, p) => a + p.amount);
    final progress = [
      if (s.sharesFound > 0) '${s.sharesFound} found',
      if (s.sharesInWindow > 0) '${s.sharesInWindow} in window',
      if (s.payouts.isNotEmpty) '${s.payouts.length} payouts, ${fmt.xmr(paid)} XMR',
    ];
    if (progress.isNotEmpty) text = '$text. Shares: ${progress.join(', ')}';
    unawaited(MiningService.update(text));
  }
}
