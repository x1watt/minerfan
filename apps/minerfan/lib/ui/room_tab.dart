import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xprs_room/xprs_room.dart';

import '../app_controller.dart';
import '../miners/miner.dart';
import '../network/private_network.dart';
import '../network/rooms.dart';
import 'chat/chat_palette.dart';
import 'chat/chat_view.dart';
import 'contact_edit_page.dart';
import 'room_moderation.dart';

/// A miner's Chat tab: the coin's room, where people mining the same coin
/// share how it goes. Opening it joins the room; with the private network
/// off it offers to turn it on.
class RoomTab extends StatefulWidget {
  final AppController app;
  final Miner miner;

  /// This tab's place in the page's TabBar: messages count as read only
  /// while it is the selected one.
  final int tabIndex;
  const RoomTab(this.app, this.miner, {required this.tabIndex, super.key});

  @override
  State<RoomTab> createState() => _RoomTabState();
}

class _RoomTabState extends State<RoomTab> with AutomaticKeepAliveClientMixin {
  AppController get app => widget.app;
  ChatRoom? _room;
  List<ChatMessage> _messages = const [];
  Timer? _tick;
  TabController? _tabs;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _room = app.roomFor(widget.miner)?..addListener(_refresh);
    _rebuildMessages();
    app.rooms.addListener(_attach);
    app.privateNetwork.addListener(_changed);
    app.contacts.addListener(_refresh);
    // Joining saves the settings and notifies: not in the middle of a build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      app.joinRoom(widget.miner);
      _markRead();
    });
    // "Looking" turns into "nobody here yet" after a while, with no event.
    _tick = Timer.periodic(const Duration(seconds: 15), (_) => _changed());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = DefaultTabController.maybeOf(context);
    if (!identical(c, _tabs)) {
      _tabs?.removeListener(_markRead);
      _tabs = c?..addListener(_markRead);
    }
  }

  @override
  void dispose() {
    _tabs?.removeListener(_markRead);
    _tick?.cancel();
    _room?.removeListener(_refresh);
    app.rooms.removeListener(_attach);
    app.privateNetwork.removeListener(_changed);
    app.contacts.removeListener(_refresh);
    super.dispose();
  }

  void _attach() {
    final r = app.roomFor(widget.miner);
    if (identical(r, _room)) return _changed();
    _room?.removeListener(_refresh);
    _room = r?..addListener(_refresh);
    _refresh();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _refresh() {
    _rebuildMessages();
    _markRead();
    _changed();
  }

  /// Seen while this tab is on screen. Only when there is something to mark:
  /// marking notifies, and that brings us back to [_refresh].
  void _markRead() {
    final e = _room?.engine;
    if (e == null || !mounted || e.store.unread == 0) return;
    final visible = (_tabs == null || _tabs!.index == widget.tabIndex) && (ModalRoute.of(context)?.isCurrent ?? true);
    if (visible) e.markRead();
  }

  /// The message list from the room's store (only when something changed,
  /// never per frame).
  void _rebuildMessages() {
    final e = _room?.engine;
    if (e == null) return;
    final s = e.store;
    final byCallsign = {for (final c in app.contacts.contacts) c.callsign.toUpperCase(): c};
    _messages = [
      for (final i in e.visiblePosts())
        ChatMessage(
          id: i.id,
          parent: i.replyTo,
          callsign: i.from,
          name: byCallsign[i.from]?.title ?? s.identities[i.from]?.nick ?? '',
          isContact: byCallsign.containsKey(i.from),
          outgoing: i.from == e.self,
          text: i.text,
          time: DateTime.fromMillisecondsSinceEpoch(i.tsMs),
          likes: s.likes(i.id),
          liked: s.likedBy(i.id, e.self),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final room = _room;
    final e = room?.engine;
    if (room == null) {
      return const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('There is no chat for this coin.')));
    }
    if (e == null) return const Center(child: CircularProgressIndicator());
    final coin = widget.miner.name;
    final mod = e.amModerator;
    return Column(
      children: [
        _StatusLine(app, room, coin),
        if (room.moderated) ModerationBar(app, room, widget.miner.symbol, _nameOf),
        Expanded(
          child: ChatView(
            messages: _messages,
            hint: 'Message $coin miners',
            emptyText: 'No messages in the last two weeks.\nSay hello, or ask how others set up their $coin mining.',
            infoText: 'Everyone in the $coin room can read this, and the private network carries it in '
                'clear text. Each member keeps messages for 14 days, so a newcomer sees the last two weeks.',
            maxLength: 850,
            onSend: (text, replyTo) async {
              final item = replyTo == null ? null : e.store.post(replyTo.id);
              return await e.post(text, replyTo: item) != Posted.tooLong;
            },
            onLike: (m, like) => unawaited(e.like(m.id, like)),
            onHide: (m) => e.hide(m.id),
            onMute: _confirmMute,
            onAddContact: _addContact,
            onModHide: mod ? (m) => unawaited(e.moderate([('r', m.id), ('hide', 'message')])) : null,
            onModPin: mod ? (m) => unawaited(e.moderate([('r', m.id), ('pin', 'message')])) : null,
            onModMute: mod ? (m) => unawaited(muteInRoom(context, e, m.callsign, m.who)) : null,
          ),
        ),
      ],
    );
  }

  /// A contact's name, else the nickname the callsign signs with, else the
  /// callsign.
  String _nameOf(String callsign) {
    for (final c in app.contacts.contacts) {
      if (c.callsign.toUpperCase() == callsign) return c.title;
    }
    final nick = _room?.store?.identities[callsign]?.nick ?? '';
    return nick.isEmpty ? callsign : '$nick ($callsign)';
  }

  Future<void> _confirmMute(ChatMessage m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Mute ${m.who}?'),
        content: Text('Their messages (${m.callsign}) disappear from this chat on this device, and this device '
            'stops passing them on. Nobody else is told.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Mute')),
        ],
      ),
    );
    if (ok == true) _room?.engine?.mute(m.callsign);
  }

  void _addContact(ChatMessage m) {
    final id = _room?.store?.identities[m.callsign];
    if (id == null) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ContactEditPage(
        app,
        npub: id.npub,
        name: id.nick,
        note: 'Met in the ${widget.miner.name} chat',
      ),
    ));
  }
}

/// One line over the chat: where the room stands, and a way on when the
/// private network is off.
class _StatusLine extends StatelessWidget {
  final AppController app;
  final ChatRoom room;
  final String coin;
  const _StatusLine(this.app, this.room, this.coin);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final net = app.privateNetwork;
    final IconData icon;
    final String text;
    Widget? action;
    switch (net.state) {
      case PrivateNetworkState.off:
      case PrivateNetworkState.failed:
        icon = Icons.cloud_off_outlined;
        text = net.state == PrivateNetworkState.failed
            ? 'The private network could not start, so the chat is offline.'
            : 'The chat travels over the private network of this app, which is off.';
        action = FilledButton.tonal(
          onPressed: () => app.setI2p(true),
          child: Text(net.state == PrivateNetworkState.failed ? 'Try again' : 'Join'),
        );
      case PrivateNetworkState.starting:
        icon = Icons.hourglass_top;
        text = 'Connecting to the private network (about a minute)...';
      case PrivateNetworkState.up:
        switch (room.state) {
          case RoomState.offline:
          case RoomState.searching:
            icon = Icons.travel_explore;
            text = 'Looking for other $coin miners...';
          case RoomState.alone:
            icon = Icons.person_outline;
            text = 'No other $coin miners online right now. What you write waits here for them.';
          case RoomState.connected:
            final n = room.engine?.liveCount ?? 0;
            icon = Icons.forum_outlined;
            text = '$n other miner${n == 1 ? '' : 's'} active in the last hour. Messages are public and kept 14 days.';
        }
    }
    return Material(
      color: ChatPalette.windowBg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
        child: Row(
          children: [
            Icon(icon, size: 18, color: t.colorScheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant))),
            if (action != null) ...[const SizedBox(width: 8), action],
          ],
        ),
      ),
    );
  }
}
