import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:utxo_core/utxo_core.dart';
import 'package:xmr_core/xmr_core.dart' show ThermalGovernor;

import '../app_controller.dart';
import '../chains/utxo_chain.dart';
import '../format.dart' as fmt;
import '../mining_service.dart';
import 'miner.dart';

/// Settings of a solo miner on a Bitcoin-family chain (`<coin>-miner.json`).
class UtxoMinerSettings {
  /// Where found blocks pay; empty means the first wallet of the coin.
  String payTo;

  /// Target share of the network, 0.01 to 1 (1: no cap).
  double effort;
  bool useGpu;
  int gpuDevice;

  /// CPU mining (phones without a usable GPU, or next to the GPU).
  bool useCpu;
  int cpuThreads;

  UtxoMinerSettings(
      {this.payTo = '', this.effort = 0.25, this.useGpu = true, this.gpuDevice = 0, this.useCpu = false, this.cpuThreads = 1});

  Map<String, Object?> toJson() => {
        'payTo': payTo,
        'effort': effort,
        'useGpu': useGpu,
        'gpuDevice': gpuDevice,
        'useCpu': useCpu,
        'cpuThreads': cpuThreads,
      };

  static UtxoMinerSettings fromJson(Map<String, Object?> m) => UtxoMinerSettings(
        payTo: (m['payTo'] as String?) ?? '',
        effort: ((m['effort'] as num?) ?? 0.25).toDouble().clamp(0.01, 1.0),
        useGpu: (m['useGpu'] as bool?) ?? true,
        gpuDevice: (m['gpuDevice'] as int?) ?? 0,
        useCpu: (m['useCpu'] as bool?) ?? (((m['cpuThreads'] as int?) ?? 0) > 0),
        cpuThreads: max(1, (m['cpuThreads'] as int?) ?? 1),
      );
}

/// Solo mining on a Bitcoin-family chain through its [UtxoChain] (our own
/// light node), on a GPU, CPU threads or both, capped at a share of the
/// network (the effort).
class UtxoMiner extends Miner {
  final AppController app;
  final UtxoChain chain;
  UtxoMinerSettings settings = UtxoMinerSettings();
  bool _running = false;
  bool _starting = false;
  String? error;
  int _lastNotificationMs = 0;
  Timer? _thermalTimer;
  ThermalGovernor? _governor;

  UtxoMiner(this.app, this.chain) {
    chain.addListener(_onStatus);
  }

  UtxoCoin get coin => chain.coin;

  @override
  String get id => coin.id;
  @override
  String get name => coin.name;
  @override
  String get symbol => coin.symbol;
  @override
  String get detail {
    final devices = [if (gpuName != null) 'GPU', if (cpuThreadsPlanned > 0) 'CPU'];
    return 'Solo, ${devices.isEmpty ? 'no device' : devices.join(' and ')}';
  }

  @override
  bool get running => _running;
  @override
  bool get starting => _starting;
  @override
  bool get canStart => payToAddress != null && (gpuName != null || cpuThreadsPlanned > 0);
  @override
  String? get problem {
    if (payToAddress == null) return 'Create a ${coin.name} wallet in Wallets, or enter a payout address in the settings of this miner';
    if (gpuName == null && cpuThreadsPlanned == 0) return 'Choose a GPU or CPU threads in the settings of this miner';
    return error ?? chain.status?.miningError;
  }

  MiningStatus? get mining => _running ? chain.status?.mining : null;

  @override
  double get hashrate => mining?.hashrate ?? 0;

  @override
  String get statusLine {
    if (_starting) return 'Starting';
    if (!_running) return canStart ? 'Stopped' : 'Not set up';
    final s = chain.status;
    final m = mining;
    if (s == null || m == null) return 'Starting';
    if (!s.synced) return 'Syncing headers (${s.tip} of ${s.bestPeerHeight})';
    if (!m.mining) return 'Waiting for work';
    return 'Mining block ${m.height} at ${effortLabel(m.effort)}';
  }

  static String effortLabel(double effort) =>
      effort >= 1 ? 'full speed' : '${(effort * 100).round()}% of the network';

  /// The payout address: the setting, else the first wallet of this coin.
  String? get payToAddress {
    final text = settings.payTo.trim().isNotEmpty ? settings.payTo.trim() : app.firstWalletAddress(coin.id);
    if (text == null) return null;
    return Address.parse(text, coin.params) == null ? null : text;
  }

  /// The GPU this miner would use, or null.
  String? get gpuName {
    final gpus = app.gpus;
    if (!settings.useGpu || gpus.isEmpty) return null;
    return gpus[settings.gpuDevice.clamp(0, gpus.length - 1)];
  }

  /// CPU threads after the power profile (0 when CPU mining is off).
  int get cpuThreadsPlanned {
    if (!settings.useCpu) return 0;
    final n = settings.cpuThreads;
    return app.settings.power == PowerProfile.eco ? (n + 1) ~/ 2 : n;
  }

  /// This device's speed at full duty, from the startup self-tests (the
  /// GPU's timed batch and one CPU thread's timed hashes).
  double get fullSpeedEstimate {
    var r = 0.0;
    final g = gpuName;
    if (g != null) {
      for (final c in app.gpuChecks) {
        if (c.ok && c.name == g) r += c.hashrate;
      }
    }
    return r + cpuThreadsPlanned * app.cpuScryptRate;
  }

  /// The share of the network this device would be at full speed, or null
  /// while the network's speed is unknown.
  double? get fullSpeedShare {
    final net = chain.status?.networkHashrate;
    final full = fullSpeedEstimate;
    if (net == null || net <= 0 || full <= 0) return null;
    final others = max(net - hashrate, net * 0.1);
    return full / (others + full);
  }

  /// Whether the share limit changes anything on this device (a phone is
  /// usually far below it and mines all the time).
  bool get limitMatters => (fullSpeedShare ?? 1) > settings.effort;

  /// Effort after the power profile (eco halves it).
  double get effortPlanned {
    final e = settings.effort;
    return app.settings.power == PowerProfile.eco ? (e >= 1 ? 0.5 : e / 2) : e;
  }

  File get _file => File('${app.dataDir}/${coin.id}-miner.json');

  void load() {
    try {
      if (_file.existsSync()) {
        settings = UtxoMinerSettings.fromJson(jsonDecode(_file.readAsStringSync()) as Map<String, Object?>);
        return;
      }
    } catch (_) {}
    // Defaults from the device planner: a GPU coin gets the GPU and no CPU
    // threads (they stay with the CPU miners); without a GPU, one thread.
    settings = UtxoMinerSettings(useGpu: true, useCpu: app.gpus.isEmpty, cpuThreads: 1);
  }

  void save() {
    try {
      Directory(app.dataDir).createSync(recursive: true);
      _file.writeAsStringSync(jsonEncode(settings.toJson()));
    } catch (_) {}
    notifyListeners();
  }

  /// Applies a new effort at once (also while mining).
  void setEffort(double e) {
    settings.effort = e.clamp(0.01, 1.0);
    save();
    if (_running) chain.handle?.setEffort(effortPlanned);
  }

  @override
  Future<void> start() async {
    if (_running || _starting || !canStart) return;
    _starting = true;
    error = null;
    notifyListeners();
    try {
      final h = await chain.acquire(this);
      await h.startMining(MiningConfig(
        payTo: payToAddress!,
        effort: effortPlanned,
        gpuDevice: gpuName == null ? null : settings.gpuDevice,
        cpuThreads: cpuThreadsPlanned,
      ));
      _running = true;
      await app.minerStarted('Starting the ${coin.name} miner');
      _startThermalControl(h);
    } catch (e) {
      error = '$e';
      await chain.release(this);
    } finally {
      _starting = false;
      notifyListeners();
    }
  }

  @override
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _thermalTimer?.cancel();
    _thermalTimer = null;
    _governor = null;
    notifyListeners();
    try {
      await chain.handle?.stopMining();
    } catch (_) {}
    await chain.release(this);
    await app.minerStopped();
    notifyListeners();
  }

  /// On phones: the thermal state caps how much of the time the GPU and
  /// CPU threads work (steps of a quarter, as the Monero miner does with
  /// threads).
  void _startThermalControl(ChainHandle h) {
    if (!MiningService.supported || !app.settings.thermalControl) return;
    final g = _governor = ThermalGovernor(4);
    _thermalTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      final r = await MiningService.thermal();
      if (r == null || !_running) return;
      final before = g.threads;
      final after = g.update(r, DateTime.now().millisecondsSinceEpoch);
      if (after != before) {
        h.setDutyCap(after / 4);
        notifyListeners();
      }
    });
  }

  /// What thermal control is doing, when it holds the miner back.
  String? get thermalNote {
    final g = _governor;
    if (g == null || g.threads >= g.maxThreads) return null;
    return g.threads == 0 ? 'Paused: the phone is too hot' : 'Phone is warm: at most ${g.threads * 25}% of the time';
  }

  void _onStatus() {
    if (_running) _updateNotification();
    notifyListeners();
  }

  /// The Android notification, while no Monero miner writes it.
  void _updateNotification() {
    if (app.monero.running) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastNotificationMs < 10000) return;
    _lastNotificationMs = now;
    final m = mining;
    final accepted = chain.status?.found.where((b) => b.accepted == true).length ?? 0;
    unawaited(MiningService.update(m == null
        ? '${coin.name}: starting'
        : '${coin.name} at ${fmt.hashrate(m.hashrate)} (${effortLabel(m.effort)}), $accepted blocks found'));
  }

  @override
  void dispose() {
    chain.removeListener(_onStatus);
    super.dispose();
  }
}
