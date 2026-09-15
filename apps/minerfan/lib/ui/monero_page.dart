import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:xmr_core/xmr_core.dart';

import '../app_controller.dart';
import '../format.dart';
import '../miners/monero_miner.dart';
import '../wallets/monero_wallet.dart';
import 'room_tab.dart';
import 'widgets.dart';

/// The Monero miner's page: overview, its settings, the P2Pool sidechain,
/// the Monero chain, rewards and the node log.
class MoneroMinerPage extends StatelessWidget {
  final AppController app;
  final MoneroMiner m;

  /// The tab to open on (such as [chatTab]); by default the overview, or
  /// the settings while the miner is not set up.
  final int? initialTab;
  const MoneroMinerPage(this.app, this.m, {this.initialTab, super.key});

  static const _tabs = ['Overview', 'Settings', 'Pool', 'Chain', 'Rewards', 'Log', 'Chat'];
  static const chatTab = 6;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: _tabs.length,
      // A miner that is not set up opens on its settings.
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
                _MoneroSettings(app, m),
                _Pool(m),
                _Chain(m),
                _Rewards(m),
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

/// Shown while there is no status: stopped, or starting (the first status
/// arrives about 2 s after Start).
Widget _waiting(BuildContext context, MoneroMiner m, [AppController? app]) {
  if (m.starting || m.running) return const Center(child: CircularProgressIndicator());
  final t = Theme.of(context);
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Looks like a power button, so it is one: starts the miner, or
          // opens its settings when it is not set up yet.
          IconButton.filled(
            iconSize: 44,
            padding: const EdgeInsets.all(18),
            tooltip: m.walletValid ? 'Start' : 'Open settings',
            onPressed: m.walletValid
                ? () => app != null ? app.setMinerOn(m, true) : m.start()
                : () => DefaultTabController.of(context).animateTo(1),
            icon: const Icon(Icons.power_settings_new),
          ),
          const SizedBox(height: 14),
          Text(
            m.walletValid
                ? 'Stopped. Tap to start syncing and mining.'
                : 'Enter a Monero primary address (starts with 4) in Settings, then start.',
            textAlign: TextAlign.center,
          ),
          if (m.error != null) ...[
            const SizedBox(height: 12),
            Text(m.error!, style: TextStyle(color: t.colorScheme.error)),
          ],
        ],
      ),
    ),
  );
}

class _Overview extends StatelessWidget {
  final AppController app;
  final MoneroMiner m;
  const _Overview(this.app, this.m);

  @override
  Widget build(BuildContext context) {
    final s = m.status;
    if (!m.running || s == null) return _waiting(context, m, app);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: ListTile(
            leading: Icon(s.mining ? Icons.bolt : Icons.hourglass_top),
            title: Text(m.statusLine),
            subtitle: Text(
              s.mining
                  ? 'Mining to your wallet on P2Pool ${m.settings.sidechain}'
                  : 'Mining starts once the Monero chain and the sidechain are synced',
            ),
            trailing: s.moneroSynced && s.sideSynced ? Switch(value: s.mining, onChanged: m.setMining) : null,
          ),
        ),
        if (m.thermalNote != null)
          Card(
            child: ListTile(
              leading: const Icon(Icons.thermostat),
              title: Text(m.thermalNote!),
              subtitle: Text(m.thermalReading),
            ),
          ),
        if (s.flexNote.isNotEmpty)
          Card(
            child: ListTile(
              leading: const Icon(Icons.tune),
              title: Text(
                s.threads == 0
                    ? 'Paused for other programs'
                    : 'Flexible mining: ${s.threads} of ${s.maxThreads} threads',
              ),
              subtitle: Text(s.flexNote),
            ),
          ),
        statGrid(context, [
          Stat('Hashrate', hashrate(s.hashrate), icon: Icons.speed),
          Stat(
            'Threads',
            s.threads == s.maxThreads ? '${s.threads}' : '${s.threads} of ${s.maxThreads}',
            icon: Icons.memory,
          ),
          Stat('RandomX engine', s.engine, icon: Icons.developer_board),
          Stat('Shares found', '${s.sharesFound}', icon: Icons.star),
          Stat('Shares in window', '${s.sharesInWindow}', icon: Icons.window),
          Stat('Next block pays you', '${xmr(s.estimatedPayoutPerBlock)} XMR', icon: Icons.payments),
          Stat('Window share', '${(s.windowFraction * 100).toStringAsFixed(4)} %', icon: Icons.pie_chart),
          Stat('Monero height', '${s.moneroHeight}', icon: Icons.link),
          Stat('Sidechain height', '${s.sideHeight}', icon: Icons.hub),
        ]),
        const SizedBox(height: 4),
        _Expectation(s, m.settings.sidechain),
      ],
    );
  }
}

class _Expectation extends StatelessWidget {
  final NodeStatus s;
  final String chain;
  const _Expectation(this.s, this.chain);

  @override
  Widget build(BuildContext context) {
    final diff = double.tryParse(s.sideDifficulty) ?? 0;
    final seconds = s.hashrate > 0 ? diff / s.hashrate : double.infinity;
    String dur(double sec) {
      if (!sec.isFinite) return 'unknown';
      if (sec < 3600) return '${(sec / 60).toStringAsFixed(0)} minutes';
      if (sec < 172800) return '${(sec / 3600).toStringAsFixed(1)} hours';
      return '${(sec / 86400).toStringAsFixed(1)} days';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Text(
          'At ${hashrate(s.hashrate)} and a share difficulty of ${s.sideDifficulty}, you find a share on '
          'P2Pool $chain about every ${dur(seconds)} on average. Each share stays in the PPLNS window for '
          'about ${chain == 'nano' ? '18 hours' : (chain == 'mini' ? '6 hours' : '1 hour')} and is paid in every '
          'Monero block P2Pool finds during that time, directly to your wallet.',
        ),
      ),
    );
  }
}

class _MoneroSettings extends StatefulWidget {
  final AppController app;
  final MoneroMiner m;
  const _MoneroSettings(this.app, this.m);

  @override
  State<_MoneroSettings> createState() => _MoneroSettingsState();
}

class _MoneroSettingsState extends State<_MoneroSettings> {
  late final TextEditingController _wallet = TextEditingController(text: widget.m.settings.wallet);

  @override
  void dispose() {
    _wallet.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.m;
    final s = m.settings;
    final locked = m.running;
    final sharedOk = RxBuffer.sharedSupported;
    final t = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (locked)
          const Card(
            child: ListTile(leading: Icon(Icons.lock), title: Text('Stop the miner to change its settings.')),
          ),
        const SectionTitle('Payout'),
        PayoutPicker(
          // The app's own wallet first: an empty setting pays it.
          wallets: [
            for (final w in [
              ...widget.app.wallets.whereType<MoneroWallet>().where((w) => !w.viewOnly),
              ...widget.app.wallets.whereType<MoneroWallet>().where((w) => w.viewOnly),
              ...widget.app.wallets.whereType<MoneroWatchWallet>(),
            ])
              if (MoneroAddress.parse(w.address)?.kind == AddressKind.standard) (label: w.label, address: w.address),
          ],
          value: s.wallet.trim(),
          enabled: !locked,
          otherController: _wallet,
          validOther: m.walletValid,
          coinName: 'Monero primary',
          onChanged: (v) {
            s.wallet = v;
            m.save();
          },
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('P2Pool pays primary addresses (starting with 4) directly in the blocks it finds.',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ),
        const SectionTitle('P2Pool sidechain'),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'nano', label: Text('Nano')),
            ButtonSegment(value: 'mini', label: Text('Mini')),
            ButtonSegment(value: 'main', label: Text('Main')),
          ],
          selected: {s.sidechain},
          onSelectionChanged: locked
              ? null
              : (v) {
                  s.sidechain = v.first;
                  m.save();
                },
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(switch (s.sidechain) {
            'main' => 'The main P2Pool sidechain: the most pool hashrate and the highest share difficulty.',
            'nano' => 'The smallest P2Pool sidechain: the lowest share difficulty, fewer blocks found.',
            _ => 'P2Pool mini, the sidechain for small miners (as in Gupax): lower share difficulty than main.',
          }),
        ),
        SectionTitle('Mining threads: ${s.threads}'),
        Text(
          Platform.isAndroid || Platform.isIOS
              ? 'Suggested: ${CpuFeatures.recommendedThreads(fastMode: s.fastMode)} '
                    '(${s.fastMode ? 'fast mode: big cores, about 2 MiB of cache each' : 'light mode: every core adds hashrate'}; '
                    'fewer threads run cooler)'
              : 'Suggested: ${CpuFeatures.recommendedThreads(fastMode: s.fastMode)} (one per physical core)',
          style: t.textTheme.bodySmall,
        ),
        Slider(
          value: s.threads.toDouble(),
          min: 1,
          max: Platform.numberOfProcessors.toDouble().clamp(1, 64),
          divisions: (Platform.numberOfProcessors - 1).clamp(1, 63),
          label: '${s.threads}',
          onChanged: locked
              ? null
              : (v) {
                  s.threads = v.round();
                  m.save();
                },
        ),
        const SectionTitle('RandomX'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Shared memory'),
          subtitle: Text(
            sharedOk
                ? 'One 256 MiB RandomX cache for all threads through dart:ffi; needed by the JIT and fast mode. '
                      'Off: each thread keeps its own copy and the interpreter runs.'
                : 'Not available on this platform.',
          ),
          value: s.memory == RxMemoryKind.shared,
          onChanged: locked || !sharedOk
              ? null
              : (v) {
                  s.memory = v ? RxMemoryKind.shared : RxMemoryKind.dart;
                  if (!v) s.fastMode = false;
                  m.save();
                },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Fast mode (2 GiB dataset)'),
          subtitle: const Text(
            'Builds the full RandomX dataset once per seed for several times the hashrate. '
            'Needs shared memory and about 3 GiB of free RAM; with less it keeps mining in light mode.',
          ),
          value: s.fastMode,
          onChanged: locked || s.memory != RxMemoryKind.shared
              ? null
              : (v) {
                  s.fastMode = v;
                  m.save();
                },
        ),
        const SizedBox(height: 8),
        Text('Engine', style: t.textTheme.titleSmall),
        const SizedBox(height: 6),
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 'auto', label: Text('Auto')),
            ButtonSegment(value: 'jit', label: Text('JIT')),
            ButtonSegment(
              value: 'interpreter',
              label: FittedBox(fit: BoxFit.scaleDown, child: Text('Interpreter')),
            ),
          ],
          selected: {s.engine},
          onSelectionChanged: locked
              ? null
              : (v) {
                  s.engine = v.first;
                  m.save();
                },
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            RandomXJitVM.supported
                ? 'The JIT turns each RandomX program into machine code for this CPU (${CpuFeatures.current}), '
                      'many times faster than the interpreter. It checks itself against the interpreter at every '
                      'seed and falls back if they ever disagree. Needs shared memory.'
                : 'The JIT is not available on this CPU or platform; the interpreter is used.',
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Power use, thermal control and the theme are in the app Settings.',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _Pool extends StatelessWidget {
  final MoneroMiner m;
  const _Pool(this.m);

  @override
  Widget build(BuildContext context) {
    final s = m.status;
    if (!m.running || s == null) return _waiting(context, m);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        statGrid(context, [
          Stat('Sidechain', m.settings.sidechain),
          Stat('Our tip', '${s.sideHeight}'),
          Stat('Best peer tip', '${s.sidePeerHeight}'),
          Stat('Peers', '${s.sidePeers}'),
          Stat('Synced', s.sideSynced ? 'yes' : 'no'),
          Stat('Share difficulty', s.sideDifficulty),
        ]),
        const SectionTitle('Shares found by this node'),
        if (s.recentShares.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('None yet.')),
        for (final sh in s.recentShares.reversed)
          ListTile(
            dense: true,
            leading: const Icon(Icons.star),
            title: Text('Side height ${sh.sideHeight}, Monero height ${sh.moneroHeight}'),
            subtitle: Text(
              '${DateTime.fromMillisecondsSinceEpoch(sh.timestamp * 1000)}  ${sh.templateId.substring(0, 16)}...',
            ),
          ),
      ],
    );
  }
}

class _Chain extends StatelessWidget {
  final MoneroMiner m;
  const _Chain(this.m);

  @override
  Widget build(BuildContext context) {
    final s = m.status;
    if (!m.running || s == null) return _waiting(context, m);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        statGrid(context, [
          Stat('Height', '${s.moneroHeight}'),
          Stat('Peers', '${s.moneroPeers}'),
          Stat('Synced', s.moneroSynced ? 'yes' : 'no'),
        ]),
        const Card(
          child: Padding(
            padding: EdgeInsets.all(14),
            child: Text(
              'This miner follows the Monero chain itself over the Monero P2P network, starting from a built-in '
              'checkpoint. It computes every block difficulty, checks proof of work on recent and seed blocks, '
              'and compares its cumulative difficulty with several peers. No Monero node or third-party server '
              'is used.',
            ),
          ),
        ),
      ],
    );
  }
}

class _Rewards extends StatelessWidget {
  final MoneroMiner m;
  const _Rewards(this.m);

  @override
  Widget build(BuildContext context) {
    final s = m.status;
    if (!m.running || s == null) return _waiting(context, m);
    final perDay = payoutsPerDay(s.payouts).entries.toList()..sort((a, b) => b.key.compareTo(a.key));
    final total = s.payouts.fold<int>(0, (t, p) => t + p.amount);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        statGrid(context, [
          Stat('Total received', '${xmr(total)} XMR', icon: Icons.savings),
          Stat('Payouts', '${s.payouts.length}', icon: Icons.receipt_long),
          Stat('Next block pays you', '${xmr(s.estimatedPayoutPerBlock)} XMR', icon: Icons.schedule),
        ]),
        const SectionTitle('Per day (UTC)'),
        if (perDay.isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'No payouts yet. P2Pool pays every wallet with a share in the window whenever it finds a '
              'Monero block; the payout arrives in your wallet with no action needed.',
            ),
          ),
        for (final e in perDay)
          ListTile(
            dense: true,
            leading: const Icon(Icons.calendar_today),
            title: Text(e.key),
            trailing: Text('${xmr(e.value)} XMR'),
          ),
        if (s.payouts.isNotEmpty) const Divider(),
        for (final p in s.payouts.reversed)
          ListTile(
            dense: true,
            title: Text('Monero block ${p.moneroHeight}'),
            subtitle: Text(DateTime.fromMillisecondsSinceEpoch(p.timestamp * 1000).toString()),
            trailing: Text('${xmr(p.amount)} XMR'),
          ),
      ],
    );
  }
}

class _Log extends StatelessWidget {
  final MoneroMiner m;
  const _Log(this.m);

  @override
  Widget build(BuildContext context) {
    final s = m.status;
    if (!m.running || s == null) return _waiting(context, m);
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      reverse: true,
      itemCount: s.log.length,
      itemBuilder: (context, i) =>
          Text(s.log[s.log.length - 1 - i], style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
    );
  }
}
