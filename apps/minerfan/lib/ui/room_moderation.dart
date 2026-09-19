import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xprs_room/xprs_room.dart';
import 'package:xprs_wire/xprs_wire.dart' show xprsNowTs;

import '../app_controller.dart';
import '../format.dart';
import '../network/rooms.dart';
import '../wallets/keyed_wallet.dart';
import '../wallets/monero_wallet.dart';
import '../wallets/utxo_wallet.dart';
import '../wallets/wallet.dart';

String _date(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${d.day} ${months[d.month - 1]}, ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

/// The rules, as the app states them.
const moderationRules = 'Moderator rights for this room can be bought. Send any amount above the current one: '
    'the largest payment holds the rights for 30 days. A larger payment takes them over and starts a new 30 days. '
    'If 30 days pass without a larger payment, the rights end and any amount can win them again.\n\n'
    'The moderator can hide messages for everyone, mute people in the room, pin a message, set a topic and ask '
    'for approval before new people post. Messages they hide stay hidden; everything else ends with their term.\n\n'
    'Payments are final and are not refunded, also when a larger payment takes over.';

/// The room's moderation under the status line: who moderates and until
/// when, the topic and pinned post, and the way to buy the rights (or, for
/// the moderator, to run the room).
class ModerationBar extends StatelessWidget {
  final AppController app;
  final ChatRoom room;
  final String symbol;
  final String Function(String callsign) nameOf;
  const ModerationBar(this.app, this.room, this.symbol, this.nameOf, {super.key});

  @override
  Widget build(BuildContext context) {
    final e = room.engine!;
    final t = Theme.of(context);
    final m = e.moderation;
    final me = e.amModerator && m.term?.callsign == e.self;
    final waiting = room.claims?.claims.isNotEmpty ?? false;
    final held = e.amModerator ? e.heldPosts().length : 0;
    final pinned = m.pinned == null ? null : e.store.post(m.pinned!);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final line = m.term == null
        ? 'No moderator right now.'
        : me
            ? 'You moderate this room until ${_date(m.term!.endMs)}.'
            : 'Moderator: ${nameOf(m.term!.callsign)} until ${_date(m.term!.endMs)} '
                '(${coinAmount(room.minerId, m.toBeat, symbol)} to beat).';
    return Material(
      color: t.colorScheme.surfaceContainerLowest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.shield_outlined, size: 18, color: t.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(waiting && !me ? '$line Your payment is waiting for the network to confirm it.' : line,
                    style: muted),
              ),
              if (e.amModerator)
                TextButton(onPressed: () => showModSettings(context, room), child: Text(held > 0 ? 'Moderate ($held)' : 'Moderate'))
              else
                TextButton(onPressed: () => showBuySheet(context, app, room, symbol), child: const Text('Become moderator')),
            ]),
            if (m.topic != null)
              Padding(
                padding: const EdgeInsets.only(left: 28, top: 2),
                child: Text(m.topic!, style: t.textTheme.bodyMedium),
              ),
            if (pinned != null)
              Padding(
                padding: const EdgeInsets.only(left: 28, top: 2),
                child: Row(children: [
                  Icon(Icons.push_pin, size: 14, color: t.colorScheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('${nameOf(pinned.from)}: ${pinned.text}',
                        maxLines: 2, overflow: TextOverflow.ellipsis, style: muted),
                  ),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}

/// The wallets of [coin] this device can pay from.
List<Wallet> payingWallets(AppController app, String coin) => [
      for (final w in app.wallets)
        if (w.chain == coin && ((w is MoneroWallet && !w.viewOnly) || w is UtxoWallet)) w,
    ];

int _spendable(Wallet w) => switch (w) {
      MoneroWallet() => w.status?.unlocked ?? 0,
      UtxoWallet() => w.status?.balance.confirmed ?? 0,
      _ => 0,
    };

Future<void> showBuySheet(BuildContext context, AppController app, ChatRoom room, String symbol) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _BuySheet(app, room, symbol),
    );

class _BuySheet extends StatefulWidget {
  final AppController app;
  final ChatRoom room;
  final String symbol;
  const _BuySheet(this.app, this.room, this.symbol);
  @override
  State<_BuySheet> createState() => _BuySheetState();
}

class _BuySheetState extends State<_BuySheet> {
  final _amount = TextEditingController();
  final _password = TextEditingController();
  Wallet? _wallet;
  String? _error;
  bool _busy = false;

  String get coin => widget.room.minerId;

  @override
  void initState() {
    super.initState();
    final ws = payingWallets(widget.app, coin);
    _wallet = ws.isEmpty ? null : ws.first;
  }

  @override
  void dispose() {
    _amount.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _pay() async {
    final w = _wallet;
    if (w == null) return;
    final units = parseCoins(_amount.text, decimals: coinDecimals(coin));
    final toBeat = widget.room.engine!.moderation.toBeat;
    if (units == null) return setState(() => _error = 'Enter an amount');
    if (BigInt.from(units) <= toBeat) {
      return setState(() => _error = 'The amount has to be more than ${coinAmount(coin, toBeat, widget.symbol)}');
    }
    if (units > _spendable(w)) return setState(() => _error = 'Not enough spendable in this wallet');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.app.rooms.buyModeration(widget.room, w, BigInt.from(units),
          password: w is KeyedWallet && w.hasPassword ? _password.text : null);
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Paid. You get the moderator rights as soon as the network confirms the payment.')));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final ws = payingWallets(widget.app, coin);
    final w = _wallet;
    final toBeat = widget.room.engine!.moderation.toBeat;
    final needsPassword = w is KeyedWallet && w.hasPassword;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Become the moderator', style: t.textTheme.titleLarge),
            const SizedBox(height: 12),
            Text(moderationRules, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            Text(toBeat == BigInt.zero
                ? 'Nobody holds the rights now: any amount wins them.'
                : 'To take over, pay more than ${coinAmount(coin, toBeat, widget.symbol)}.'),
            const SizedBox(height: 12),
            if (ws.isEmpty)
              const Text('You need a wallet for this coin in the Wallets tab to pay from.')
            else ...[
              DropdownButtonFormField<Wallet>(
                initialValue: w,
                decoration: const InputDecoration(labelText: 'Pay from'),
                items: [
                  for (final x in ws)
                    DropdownMenuItem(
                        value: x,
                        child: Text('${x.label}  (${coins(_spendable(x), decimals: coinDecimals(coin))} ${widget.symbol})')),
                ],
                onChanged: _busy ? null : (x) => setState(() => _wallet = x),
              ),
              TextField(
                controller: _amount,
                enabled: !_busy,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: 'Amount (${widget.symbol})'),
              ),
              if (needsPassword)
                TextField(
                  controller: _password,
                  enabled: !_busy,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Wallet password'),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(_error!, style: TextStyle(color: t.colorScheme.error)),
                ),
              const SizedBox(height: 16),
              Row(children: [
                const Spacer(),
                TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy ? null : _pay,
                  child: _busy
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Pay'),
                ),
              ]),
            ],
          ],
        ),
      ),
    );
  }
}

Future<void> showModSettings(BuildContext context, ChatRoom room) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ModSheet(room),
    );

class _ModSheet extends StatefulWidget {
  final ChatRoom room;
  const _ModSheet(this.room);
  @override
  State<_ModSheet> createState() => _ModSheetState();
}

class _ModSheetState extends State<_ModSheet> {
  late final _topic = TextEditingController(text: widget.room.engine!.moderation.topic ?? '');
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.room.engine!.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _topic.dispose();
    super.dispose();
  }

  Future<void> _act(List<(String, String)> fields, {String? text}) async {
    final r = await widget.room.engine!.moderate(fields, text: text);
    if (!mounted || r == Moderated.done) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(r == Moderated.tooLong ? 'That is too long.' : 'Only the moderator of this room can do that.')));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final e = widget.room.engine!;
    final m = e.moderation;
    final held = e.heldPosts();
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Moderate the room', style: t.textTheme.titleLarge),
            if (m.term != null)
              Text('Your rights last until ${_date(m.term!.endMs)} unless someone pays more.',
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            TextField(
              controller: _topic,
              maxLength: 120,
              decoration: const InputDecoration(labelText: 'Topic, shown at the top of the room'),
            ),
            Row(children: [
              TextButton(onPressed: () => _act([('set', 'topic')], text: _topic.text), child: const Text('Set topic')),
              if (m.pinned != null) TextButton(onPressed: () => _act([('set', 'unpin')]), child: const Text('Unpin')),
            ]),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('New people need approval to post'),
              subtitle: const Text('Their messages wait here until you approve them.'),
              value: m.approval,
              onChanged: (on) => _act([('set', on ? 'approval' : 'open')]),
            ),
            if (m.muted.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Muted', style: t.textTheme.titleSmall),
              for (final c in m.muted.keys)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(c),
                  subtitle: Text('until ${_date(m.muted[c]!)}'),
                  trailing: TextButton(onPressed: () => _act([('grant', c)]), child: const Text('Unmute')),
                ),
            ],
            if (held.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Waiting for approval', style: t.textTheme.titleSmall),
              for (final p in held)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(p.text, maxLines: 3, overflow: TextOverflow.ellipsis),
                  subtitle: Text(p.from),
                  trailing: Wrap(spacing: 4, children: [
                    IconButton(
                        tooltip: 'Hide',
                        icon: const Icon(Icons.visibility_off_outlined),
                        onPressed: () => _act([('r', p.id), ('hide', 'message')])),
                    IconButton(
                        tooltip: 'Approve ${p.from}',
                        icon: const Icon(Icons.check),
                        onPressed: () => _act([('grant', p.from)])),
                  ]),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Asks how long to mute [who], then mutes them (at most until the term
/// ends; the moderation replay caps it anyway).
Future<void> muteInRoom(BuildContext context, RoomEngine e, String callsign, String who) async {
  final end = e.moderation.term?.endMs;
  final now = DateTime.now().millisecondsSinceEpoch;
  final choice = await showDialog<int>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text('Mute $who in this room'),
      children: [
        SimpleDialogOption(onPressed: () => Navigator.pop(ctx, now + 3600000), child: const Text('For an hour')),
        SimpleDialogOption(onPressed: () => Navigator.pop(ctx, now + 86400000), child: const Text('For a day')),
        SimpleDialogOption(onPressed: () => Navigator.pop(ctx, now + 7 * 86400000), child: const Text('For a week')),
        if (end != null)
          SimpleDialogOption(onPressed: () => Navigator.pop(ctx, end), child: const Text('Until my rights end')),
      ],
    ),
  );
  if (choice == null) return;
  await e.moderate([('revoke', callsign), ('until', xprsNowTs(choice))]);
}
