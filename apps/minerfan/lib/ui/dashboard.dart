import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../format.dart';
import '../miners/miner.dart';
import '../miners/monero_miner.dart';
import '../miners/utxo_miner.dart';
import '../devices.dart';
import 'chat_button.dart';
import 'contacts_page.dart';
import 'miners_page.dart';
import 'widgets.dart';

/// Every miner at a glance.
class DashboardPage extends StatelessWidget {
  final AppController app;
  const DashboardPage(this.app, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        app.settings.miningOn ? 'Mining is on' : 'Mining is off',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.textTheme.titleLarge,
                      ),
                    ),
                    // The master switch: every enabled miner on or off at once.
                    Transform.scale(
                      scale: 1.25,
                      child: Switch(
                        value: app.settings.miningOn,
                        onChanged: app.miners.any((m) => m.canStart) ? app.setMiningOn : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                // Hashrates of different algorithms do not add up, so each
                // running miner shows its own.
                Text(
                  'Hashrate',
                  maxLines: 1,
                  style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 4),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    app.runningCount == 0
                        ? hashrate(0)
                        : [
                            for (final m in app.miners)
                              if (m.running) '${m.symbol} ${hashrate(m.hashrate)}',
                          ].join('   '),
                    maxLines: 1,
                    style: t.textTheme.displaySmall?.copyWith(color: t.colorScheme.primary),
                  ),
                ),
                const SizedBox(height: 6),
                if (app.miners.map((m) => m.mined).any((x) => x != null && x.count > 0))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      'Mined so far: ${[
                        for (final m in app.miners)
                          if (m.mined case final x? when x.count > 0) minedLabel(x),
                      ].join('   ')}',
                      style: t.textTheme.titleSmall,
                    ),
                  ),
                Text(
                  '${app.runningCount} of ${app.miners.length} miners running  ·  ${_powerLabel(app.settings.power)}',
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
        for (final m in app.miners) _MinerCard(app, m),
        _ContactsCard(app),
        _DevicesCard(app),
      ],
    );
  }

  static String _powerLabel(PowerProfile p) => switch (p) {
    PowerProfile.performance => 'Power: performance',
    PowerProfile.balanced => 'Power: balanced (flexible)',
    PowerProfile.eco => 'Power: eco',
  };
}

class _MinerCard extends StatelessWidget {
  final AppController app;
  final Miner miner;
  const _MinerCard(this.app, this.miner);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final m = miner;
    final monero = m is MoneroMiner ? m : null;
    final s = monero?.status;
    final utxo = m is UtxoMiner ? m : null;
    final u = utxo?.mining;
    final chain = utxo?.chain.status;
    final notes = [
      if (monero?.thermalNote != null) monero!.thermalNote!,
      if (utxo?.thermalNote != null) utxo!.thermalNote!,
      if (s != null && s.flexNote.isNotEmpty) 'Flexible: ${s.flexNote}',
      if (!m.running && m.problem != null) m.problem!,
    ];
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openMiner(context, app, m),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  MinerBadge(m),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleMedium),
                        Text(
                          '${m.detail}  ·  ${m.statusLine}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  ChatButton(app, m.id),
                  MinerSwitch(app, m),
                ],
              ),
              if (m.running && u != null && chain != null) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 22,
                  runSpacing: 6,
                  children: [
                    _kv(context, 'Hashrate', hashrate(u.hashrate)),
                    _kv(context, 'Network', hashrate(chain.networkHashrate)),
                    _kv(context, 'Effort', UtxoMiner.effortLabel(u.effort)),
                    _kv(context, 'Blocks', '${chain.found.where((b) => b.accepted == true).length} found'),
                if (utxo!.mined case final x?) _kv(context, 'Mined', minedLabel(x)),
                  ],
                ),
              ],
              if (m.running && s != null) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 22,
                  runSpacing: 6,
                  children: [
                    _kv(context, 'Hashrate', hashrate(s.hashrate)),
                    _kv(
                      context,
                      'Threads',
                      s.threads == s.maxThreads ? '${s.threads}' : '${s.threads} of ${s.maxThreads}',
                    ),
                    _kv(context, 'Shares', '${s.sharesFound} found, ${s.sharesInWindow} in window'),
                    _kv(context, 'Paid', '${xmr(s.payouts.fold<int>(0, (a, p) => a + p.amount))} XMR'),
                  ],
                ),
              ],
              if (m.mined case final x? when x.count > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(children: [
                  Icon(Icons.savings_outlined, size: 16, color: t.colorScheme.primary),
                  const SizedBox(width: 6),
                  Expanded(child: Text('Mined: ${minedLabel(x)} (${x.count} ${x.count == 1 ? x.unit.substring(0, x.unit.length - 1) : x.unit})')),
                ]),
              ),
            for (final n in notes)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, size: 16, color: t.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 6),
                      Expanded(child: Text(n, style: t.textTheme.bodySmall)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _kv(BuildContext context, String k, String v) {
    final t = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(k, style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        Text(v, style: t.textTheme.bodyLarge),
      ],
    );
  }
}

/// Which miner uses which device, and conflicts between them.
/// The address book at a glance: how many contacts, this device's
/// callsign, and the way in.
class _ContactsCard extends StatelessWidget {
  final AppController app;
  const _ContactsCard(this.app);

  @override
  Widget build(BuildContext context) {
    final n = app.contacts.contacts.length;
    final me = app.privateNetwork.station;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: const Icon(Icons.contacts_outlined),
        title: const Text('Contacts'),
        subtitle: Text([
          n == 0 ? 'No contacts yet' : '$n contact${n == 1 ? '' : 's'}',
          if (me != null) 'you are ${me.callsign}',
        ].join('  ·  ')),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ContactsPage(app))),
      ),
    );
  }
}

class _DevicesCard extends StatelessWidget {
  final AppController app;
  const _DevicesCard(this.app);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final plan = DevicePlan.of(app);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Devices', style: t.textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final d in plan.devices)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(d.gpu ? Icons.videogame_asset_outlined : Icons.memory, size: 18, color: t.colorScheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${d.name}: ${d.users.isEmpty ? 'idle' : d.users.join(', ')}',
                        style: t.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
            for (final w in plan.warnings)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber, size: 16, color: t.colorScheme.error),
                    const SizedBox(width: 6),
                    Expanded(child: Text(w, style: t.textTheme.bodySmall)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// "60.00 CESC", "0.001234 XMR".
String minedLabel(MinedTotal x) =>
    '${x.amount.toStringAsFixed(x.amount >= 1 ? 2 : 6)} ${x.symbol}';
