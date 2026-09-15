import 'dart:io' show Platform;

import 'package:xmr_core/xmr_core.dart' show CpuFeatures;

import 'app_controller.dart';
import 'catalog.dart';
import 'miners/miner.dart';
import 'miners/utxo_miner.dart';

/// One device and the miners that use it.
class DeviceUse {
  final String name;
  final bool gpu;
  final List<String> users;
  const DeviceUse(this.name, this.gpu, this.users);
}

/// The device planner: which enabled miner uses the CPU and which the GPU,
/// and conflicts between them (shown, never silently allowed). Defaults
/// follow the mining catalog: CPU-first algorithms (RandomX) keep the CPU,
/// GPU-first coins (Cryptoescudo) take the GPU with no CPU threads.
class DevicePlan {
  final List<DeviceUse> devices;
  final List<String> warnings;
  const DevicePlan(this.devices, this.warnings);

  static DevicePlan of(AppController app) {
    final cores = Platform.numberOfProcessors;
    final cpuUsers = <String>[];
    var cpuThreads = 0;
    final gpuUsers = {for (final g in app.gpus) g: <String>[]};
    final warnings = <String>[];

    bool active(Miner m) => m.running || (app.settings.miningOn && app.isEnabled(m) && m.canStart);

    final monero = app.monero;
    if (active(monero)) {
      final n = monero.status?.maxThreads ?? monero.settings.threads;
      cpuThreads += n;
      cpuUsers.add('${monero.name} ($n threads)');
    }
    for (final m in app.miners.whereType<UtxoMiner>()) {
      if (!active(m)) continue;
      final n = m.cpuThreadsPlanned;
      if (n > 0) {
        cpuThreads += n;
        cpuUsers.add('${m.name} ($n thread${n == 1 ? '' : 's'})');
      }
      final g = m.gpuName;
      if (g != null) gpuUsers[g]?.add('${m.name} (effort ${UtxoMiner.effortLabel(m.settings.effort)})');
      if (g == null && n > 0 && app.catalog.hardwareOf(m.symbol) == MinerHardware.gpu && app.gpus.isNotEmpty) {
        warnings.add('${m.name} is a GPU coin but mines on the CPU; turn on its GPU in its settings.');
      }
    }
    if (cpuThreads > cores) {
      warnings.add('The miners use $cpuThreads CPU threads on $cores: they slow each other down. Suggested: '
          '${CpuFeatures.recommendedThreads(fastMode: monero.settings.fastMode)} for Monero and the GPU for the rest.');
    }
    for (final e in gpuUsers.entries) {
      if (e.value.length > 1) warnings.add('${e.key} is shared by ${e.value.join(' and ')}.');
    }
    return DevicePlan([
      DeviceUse('CPU, $cores threads', false, cpuUsers),
      for (final e in gpuUsers.entries) DeviceUse(e.key, true, e.value),
    ], warnings);
  }
}
