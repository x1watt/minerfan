import 'dart:io' show Platform;
import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:utxo_core/utxo_core.dart';

import '../app_controller.dart';
import '../format.dart';
import '../miners/utxo_miner.dart';
import '../wallets/utxo_wallet.dart';
import 'room_tab.dart';
import 'widgets.dart';

/// A solo miner on a Bitcoin-family chain (Cryptoescudo): overview, its
/// settings (payout, effort, devices), the blocks it found, the chain and
/// the log.
class UtxoMinerPage extends StatelessWidget {
  final AppController app;
  final UtxoMiner m;

  /// The tab to open on (such as [chatTab]); by default the overview, or
  /// the settings while the miner is not set up.
  final int? initialTab;
  const UtxoMinerPage(this.app, this.m, {this.initialTab, super.key});

  static const _tabs = ['Overview', 'Settings', 'Blocks', 'Chain', 'Log', 'Chat'];
  static const chatTab = 5;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: _tabs.length,
      initialIndex: initialTab ?? (m.running || m.canStart ? 0 : 1),
      child: ListenableBuilder(
        listenable: m,
        builder: (context, _) => Scaffold(
          appBar: AppBar(
            titleSpacing: 0,
            title: Row(
              children: [
                MinerBadge(m, size: 32),
                const SizedBox(width: 10),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text(
                        m.detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [Padding(padding: const EdgeInsets.only(right: 12), child: MinerSwitch(app, m))],
            bottom: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [for (final t in _tabs) Tab(text: t)],
            ),
          ),
          body: SafeArea(
            child: TabBarView(
              children: [
                _Overview(app, m),
                _Settings(app, m),
                _Blocks(m),
                _Chain(m),
                _Log(m),
                RoomTab(app, m, tabIndex: chatTab),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Widget _waiting(BuildContext context, AppController app, UtxoMiner m) {
  if (m.starting || (m.running && m.chain.status == null)) return const Center(child: CircularProgressIndicator());
  final t = Theme.of(context);
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton.filled(
            iconSize: 44,
            padding: const EdgeInsets.all(18),
            tooltip: m.canStart ? 'Start' : 'Open settings',
            onPressed: m.canStart ? () => app.setMinerOn(m, true) : () => DefaultTabController.of(context).animateTo(1),
            icon: const Icon(Icons.power_settings_new),
          ),
          const SizedBox(height: 14),
          Text(m.canStart ? 'Stopped. Tap to start mining.' : (m.problem ?? ''), textAlign: TextAlign.center),
          if (m.canStart && m.problem != null) ...[
            const SizedBox(height: 12),
            Text(
              m.problem!,
              style: TextStyle(color: t.colorScheme.error),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    ),
  );
}

class _Overview extends StatelessWidget {
  final AppController app;
  final UtxoMiner m;
  const _Overview(this.app, this.m);

  @override
  Widget build(BuildContext context) {
    final s = m.chain.status;
    final mining = m.mining;
    if (!m.running || s == null || mining == null) return _waiting(context, app, m);
    final spacing = m.coin.params.targetSpacingSeconds;
    // Expected blocks at the share we aim for, and the share we got.
    final perDay = 86400 / spacing * mining.effort.clamp(0.0, 1.0);
    final accepted = s.found.where((b) => b.accepted == true).length;
    final reward = m.coin.params.subsidy(s.tip + 1);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: ListTile(
            leading: Icon(mining.mining ? Icons.bolt : Icons.hourglass_top),
            title: Text(m.statusLine),
            subtitle: Text('Paying ${mining.payTo} on ${mining.devices.join(' and ')}'),
          ),
        ),
        if (mining.guard < 1)
          Card(
            child: ListTile(
              leading: const Icon(Icons.front_hand_outlined),
              title: Text(
                  mining.guard == 0 ? 'Paused: we found too many of the recent blocks' : 'Slowed down to our share'),
              subtitle: Text(
                  'We found ${(mining.observedShare * 100).toStringAsFixed(0)} % of the last 30 blocks; the target '
                  'is ${(mining.effort * 100).round()} %. The difficulty adjusts slowly, so the miner holds back until '
                  'the rest of the network catches up.'),
            ),
          ),
        statGrid(context, [
          Stat('Hashrate', hashrate(mining.hashrate), icon: Icons.speed),
          Stat('Full speed', hashrate(mining.fullSpeed), icon: Icons.rocket_launch),
          Stat('Duty', '${(mining.duty * 100).toStringAsFixed(1)} %', icon: Icons.tune),
          Stat(
            'Our blocks of the last 30',
            '${(mining.observedShare * 100).toStringAsFixed(0)} % (target ${(mining.effort * 100).round()} %)',
            icon: Icons.pie_chart,
          ),
          Stat('Network hashrate', hashrate(s.networkHashrate), icon: Icons.public),
          Stat('Blocks per day at the target', perDay.toStringAsFixed(0), icon: Icons.schedule),
          Stat('Blocks found', '${s.found.length} ($accepted accepted)', icon: Icons.star),
          Stat('Block reward', '${coins(reward)} ${m.symbol}', icon: Icons.payments),
        ]),
        const SizedBox(height: 4),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Text(
              'Solo mining: each block you find pays the whole reward (${coins(reward)} ${m.symbol}) to your address. '
              'Mined coins can be spent after ${m.coin.params.coinbaseMaturity} confirmations (about '
              '${(m.coin.params.coinbaseMaturity * spacing / 60).round()} minutes). '
              '${m.limitMatters ? 'The duty is how much of the time the devices work, to stay at the share limit.' : 'This ${_device()} mines all the time: it is below the share limit.'}'
              '${Platform.isAndroid ? ' A warm phone slows down by itself (thermal control in Settings).' : ''}',
            ),
          ),
        ),
      ],
    );
  }
}

class _Settings extends StatefulWidget {
  final AppController app;
  final UtxoMiner m;
  const _Settings(this.app, this.m);

  @override
  State<_Settings> createState() => _SettingsState();
}

class _SettingsState extends State<_Settings> {
  late final TextEditingController _payTo = TextEditingController(text: widget.m.settings.payTo);

  @override
  void dispose() {
    _payTo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final m = widget.m;
    final s = m.settings;
    final locked = m.running;
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final coinWallets = app.wallets.whereType<UtxoWallet>().where((w) => w.coin.id == m.coin.id).toList();
    final typed = s.payTo.trim();
    final typedValid = typed.isEmpty || Address.parse(typed, m.coin.params) != null;
    final cores = Platform.numberOfProcessors;
    final monero = app.monero;
    final moneroThreads = monero.running || (app.isEnabled(monero) && monero.canStart) ? monero.settings.threads : 0;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (locked)
          const Card(
            child: ListTile(
              leading: Icon(Icons.lock),
              title: Text('Stop the miner to change the payout address and devices.'),
            ),
          ),
        const SectionTitle('Payout'),
        PayoutPicker(
          wallets: [for (final w in coinWallets) (label: w.label, address: w.firstAddress)],
          value: typed,
          enabled: !locked,
          otherController: _payTo,
          validOther: typedValid,
          coinName: m.coin.name,
          onChanged: (v) {
            s.payTo = v;
            m.save();
          },
        ),
        ..._effortSection(context, m, muted),
        if (app.settings.power == PowerProfile.eco)
          Text('Power profile eco: half of this effort and of the CPU threads.', style: muted),
        const SectionTitle('GPU'),
        if (app.gpus.isEmpty) ...[
          Text(
            app.gpuNote ??
                (Platform.isAndroid
                    ? 'This phone does not let apps use its GPU through OpenCL. Mine on the CPU below; GPU mining '
                        'through Vulkan, which every recent phone has, is a later step.'
                    : 'No OpenCL GPU found. The graphics driver provides OpenCL (NVIDIA, AMD, Intel).'),
            style: muted,
          ),
          if (app.gpuNote != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(onPressed: app.retryGpus, child: const Text('Check the GPU again')),
            ),
        ] else ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Mine on the GPU'),
            subtitle: Text(
              'scrypt runs in our own OpenCL kernel${Platform.isAndroid ? ' on the GPU of the phone' : ''}; every result is '
              'checked on the CPU before a block is sent.',
            ),
            value: s.useGpu,
            onChanged: locked
                ? null
                : (v) {
                    s.useGpu = v;
                    m.save();
                  },
          ),
          if (app.gpus.length > 1)
            DropdownButtonFormField<int>(
              initialValue: s.gpuDevice.clamp(0, app.gpus.length - 1),
              decoration: const InputDecoration(labelText: 'Device'),
              items: [for (var i = 0; i < app.gpus.length; i++) DropdownMenuItem(value: i, child: Text(app.gpus[i]))],
              onChanged: locked
                  ? null
                  : (v) {
                      s.gpuDevice = v ?? 0;
                      m.save();
                    },
            )
          else
            Text('Device: ${app.gpus.first}', style: muted),
          for (final c in app.gpuChecks)
            Text(c.ok ? 'Self-test passed (same hashes as the CPU): $c' : 'Self-test failed, not used: $c', style: muted),
        ],
        const SectionTitle('CPU'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Mine on the CPU'),
          subtitle: Text(_sentence([
            if (app.cpuScryptRate > 0) 'each thread does about ${hashrate(app.cpuScryptRate)} on this ${_device()}',
            if (app.gpus.isNotEmpty) 'the GPU does ${hashrate(app.gpuChecks.firstWhere((c) => c.ok).hashrate)}',
            if (moneroThreads > 0) 'the Monero miner also uses $moneroThreads threads',
          ])),
          value: s.useCpu,
          onChanged: locked
              ? null
              : (v) {
                  s.useCpu = v;
                  m.save();
                },
        ),
        if (s.useCpu) ...[
          Text('Threads: ${s.cpuThreads} of $cores', style: t.textTheme.bodyMedium),
          Slider(
            value: s.cpuThreads.toDouble().clamp(1, cores.toDouble()),
            min: 1,
            max: cores.toDouble(),
            divisions: max(1, cores - 1),
            label: '${s.cpuThreads}',
            onChanged: locked
                ? null
                : (v) {
                    s.cpuThreads = v.round();
                    m.save();
                  },
          ),
          if (s.cpuThreads + moneroThreads > cores)
            Text(
              'Together with Monero this is more threads than the CPU has; both miners will slow each other down.',
              style: TextStyle(color: t.colorScheme.error),
            ),
        ],
      ],
    );
  }
}

/// Clauses joined into one sentence ("A; b; c.").
String _sentence(List<String> parts) {
  if (parts.isEmpty) return '';
  final t = parts.join('; ');
  return '${t[0].toUpperCase()}${t.substring(1)}.';
}

String _device() => Platform.isAndroid || Platform.isIOS ? 'phone' : 'computer';

String _pct(double x) => x < 0.1 ? '${(x * 100).toStringAsFixed(1)} %' : '${(x * 100).round()} %';

/// The share limit, told for this device: a phone is a few percent of the
/// network at most and mines all the time, so there the limit is an
/// advanced setting; a desktop GPU can outrun the whole network, so there
/// it is explained and shown up front.
List<Widget> _effortSection(BuildContext context, UtxoMiner m, TextStyle? muted) {
  final s = m.settings;
  final share = m.fullSpeedShare;
  final slider = Slider(
    value: (s.effort * 100).roundToDouble().clamp(1, 100),
    min: 1,
    max: 100,
    label: UtxoMiner.effortLabel(s.effort),
    onChanged: (v) => m.setEffort(v.roundToDouble() / 100),
  );
  final perDay = share == null ? null : (86400 / m.coin.params.targetSpacingSeconds * share).round();
  if (share != null && !m.limitMatters) {
    return [
      const SectionTitle('Share of the network'),
      Text(
        'At full speed this ${_device()} is about ${_pct(share)} of the ${m.coin.name} network '
        '(${hashrate(m.fullSpeedEstimate)}, about $perDay blocks a day), below the ${_pct(s.effort)} limit, so it '
        'mines all the time.',
      ),
      Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text('Limit: ${UtxoMiner.effortLabel(s.effort)}'),
          subtitle: Text('Advanced: the most of the network this miner takes', style: muted),
          children: [slider],
        ),
      ),
    ];
  }
  return [
    SectionTitle('Share of the network: ${s.effort >= 1 ? 'no limit' : _pct(s.effort)}'),
    Text(
      share == null
          ? 'The most of the ${m.coin.name} network this miner takes. Applies at once.'
          : 'At full speed this ${_device()} alone would be about ${_pct(share)} of the ${m.coin.name} network '
              '(${hashrate(m.fullSpeedEstimate)}). It mines part of the time to stay at the share below, so the other '
              'miners keep finding their blocks. Applies at once.',
      style: muted,
    ),
    slider,
  ];
}

class _Blocks extends StatelessWidget {
  final UtxoMiner m;
  const _Blocks(this.m);

  @override
  Widget build(BuildContext context) {
    final found = m.chain.status?.found ?? const <FoundBlock>[];
    final reward = m.coin.params.subsidy;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (found.isEmpty)
          const Padding(padding: EdgeInsets.all(12), child: Text('No blocks found yet.'))
        else
          for (final b in found.reversed)
            ListTile(
              dense: true,
              leading: Icon(
                b.accepted == false ? Icons.close : (b.accepted == true ? Icons.check_circle : Icons.pending),
              ),
              title: Text(
                'Block ${b.height}: ${b.accepted == null ? 'waiting for the network' : (b.accepted! ? 'in the chain' : 'orphaned')}',
              ),
              subtitle: Text('${DateTime.fromMillisecondsSinceEpoch(b.time * 1000)}  ${b.hash.substring(0, 16)}...'),
              trailing: Text('${coins(reward(b.height))} ${m.symbol}'),
            ),
        if (m.chain.status == null)
          const Padding(padding: EdgeInsets.all(12), child: Text('Start the miner or open a wallet to see the chain.')),
      ],
    );
  }
}

class _Chain extends StatelessWidget {
  final UtxoMiner m;
  const _Chain(this.m);

  @override
  Widget build(BuildContext context) {
    final s = m.chain.status;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (s != null)
          statGrid(context, [
            Stat('Height', '${s.tip}'),
            Stat('Best peer', '${s.bestPeerHeight}'),
            Stat('Peers', '${s.peers}'),
            Stat('Synced', s.synced ? 'yes' : 'no'),
            Stat('Difficulty', s.difficulty.toStringAsFixed(6)),
            Stat('Network hashrate', hashrate(s.networkHashrate)),
          ]),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Text(
              'This miner follows the ${m.coin.name} chain itself over its P2P network, from a built-in checkpoint: it '
              'checks the proof of work of every header (scrypt) and difficulty (Kimoto Gravity Well) and follows the chain '
              'with the most work. Blocks it finds go straight to its peers. No ${m.coin.name} node, pool or server '
              'is used.',
            ),
          ),
        ),
      ],
    );
  }
}

class _Log extends StatelessWidget {
  final UtxoMiner m;
  const _Log(this.m);

  @override
  Widget build(BuildContext context) {
    final log = m.chain.log;
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      reverse: true,
      itemCount: log.length,
      itemBuilder: (context, i) =>
          Text(log[log.length - 1 - i], style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
    );
  }
}
