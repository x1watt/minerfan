import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../format.dart';
import '../miners/miner.dart';
import '../miners/monero_miner.dart';
import '../miners/utxo_miner.dart';
import 'monero_page.dart';
import 'utxo_miner_page.dart';
import 'widgets.dart';

/// Opens a miner's own page (its settings and details), on its Chat tab
/// when [chat].
void openMiner(BuildContext context, AppController app, Miner m, {bool chat = false}) {
  final page = switch (m) {
    MoneroMiner() => MoneroMinerPage(app, m, initialTab: chat ? MoneroMinerPage.chatTab : null),
    UtxoMiner() => UtxoMinerPage(app, m, initialTab: chat ? UtxoMinerPage.chatTab : null),
    _ => throw UnsupportedError('no page for ${m.id}'),
  };
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
}

/// The miners this app can run; each opens its own page.
class MinersPage extends StatelessWidget {
  final AppController app;
  const MinersPage(this.app, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        for (final m in app.miners)
          Card(
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              leading: MinerBadge(m),
              title: Text(m.name),
              subtitle: Text(
                [
                  if (app.catalog.algorithmOf(m.symbol) case final a?)
                    '${(app.catalog.hardwareOf(m.symbol) ?? a.hardware).label} · ${a.name}',
                  m.detail,
                  m.statusLine,
                  if (m.running) hashrate(m.hashrate),
                ].join('  ·  '),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => openMiner(context, app, m),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            'More miner types will appear here.',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
