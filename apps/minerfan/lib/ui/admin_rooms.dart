import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../moderation/config.dart';
import '../network/rooms.dart';
import 'room_moderation.dart' show coinAmount;

/// Whether this device signs as the rooms' admin, which is what turns the
/// duties below on: the claims that reach it are checked against its own
/// wallets and answered with a term (moderation/admin.dart).
bool signsAsRoomsAdmin(AppController app) {
  final me = app.privateNetwork.station?.callsign;
  return me != null && me == ModerationConfig.adminCallsign;
}

/// What the rooms' admin sees: the address each room's payments go to, who
/// moderates it now, and what its app decided lately. Only shown on the
/// device that holds the admin account.
class AdminRoomsSection extends StatelessWidget {
  final AppController app;
  const AdminRoomsSection(this.app, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final rooms = [for (final r in app.rooms.rooms) if (r.moderated) r];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(
        'This device signs as ${ModerationConfig.adminCallsign}, the callsign the site publishes, so it is the one '
        'that hands out the rooms\' moderator terms. It has to be running to notice a payment and answer it; while '
        'it is off, terms already given keep running and nothing else changes.',
        style: muted,
      ),
      const SizedBox(height: 8),
      if (rooms.isEmpty) Text('No room has moderation built in.', style: muted),
      for (final r in rooms) _RoomCard(app, r),
    ]);
  }
}

class _RoomCard extends StatelessWidget {
  final AppController app;
  final ChatRoom room;
  const _RoomCard(this.app, this.room);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final e = room.engine;
    final address = ModerationConfig.address(room.minerId);
    final wallet = app.rooms.admin?.walletFor(room.minerId);
    final m = e?.moderation;
    final term = m?.term;
    final symbol = _symbolOf(room.minerId);
    final decisions = [
      for (final line in app.privateNetwork.log.reversed)
        if (line.contains('rooms: ${room.name}:')) line,
    ].take(6).toList();
    return Card(
      margin: const EdgeInsets.only(top: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${room.name} (${room.coin})', style: t.textTheme.titleSmall),
          const SizedBox(height: 6),
          if (address != null) _row(context, 'Payments to', address),
          Text(
            wallet == null
                ? 'No wallet here holds that address, so payments to it cannot be checked. Restore it in Wallets '
                    'before anyone buys the rights.'
                : 'The wallet "${wallet.label}" here holds that address.',
            style: muted,
          ),
          const SizedBox(height: 6),
          if (term == null)
            Text('Nobody moderates this room; any payment wins the rights.', style: t.textTheme.bodyMedium)
          else
            Text(
              '${term.callsign} moderates until ${_date(term.endMs)}, bought for '
              '${coinAmount(room.minerId, term.paid, symbol)}.',
              style: t.textTheme.bodyMedium,
            ),
          if (m != null && m.hidden.isNotEmpty)
            Text('${m.hidden.length} message(s) hidden for good.', style: muted),
          if (decisions.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Lately', style: t.textTheme.bodySmall),
            for (final d in decisions)
              Text(d, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
          ],
        ]),
      ),
    );
  }

  String _symbolOf(String coinId) => coinId == 'monero' ? 'XMR' : 'CESC';

  static String _date(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day} ${months[d.month - 1]} ${d.year}, ${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
  }

  Widget _row(BuildContext context, String label, String value) {
    final t = Theme.of(context);
    return Row(children: [
      SizedBox(width: 92, child: Text(label, style: t.textTheme.bodySmall)),
      Expanded(child: SelectableText(value, style: const TextStyle(fontFamily: 'monospace', fontSize: 12))),
      IconButton(
        tooltip: 'Copy',
        icon: const Icon(Icons.copy, size: 18),
        onPressed: () {
          Clipboard.setData(ClipboardData(text: value));
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Address copied')));
        },
      ),
    ]);
  }
}
