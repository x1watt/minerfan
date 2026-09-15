// A messenger-style message list and compose bar for a coin's chat room.
//
// Forked from the xprs app's ChatViewField
// (app/lib/wapp/geoui/widgets/chat_view_field.dart, BSD-3-Clause, Max Brito):
// the same bubbles, day separators, reply threads, likes, auto-scroll and
// long-press menu, with typed messages instead of wapp maps, and without
// what a public room has no use for (media, attachments, redacted text,
// encryption and delivery badges, locations, forwarding, direct messages).
// The menu gains Add to contacts and Mute.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'chat_palette.dart';
import 'generated_avatar.dart';

/// `2026-09-08` as somebody would say it: today and yesterday by name, the
/// last week by weekday, this year without the year, anything older in full.
String chatDayLabel(String ymd, {DateTime? now}) {
  final d = DateTime.tryParse(ymd);
  if (d == null) return ymd;
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final that = DateTime(d.year, d.month, d.day);
  final days = today.difference(that).inDays;
  if (days == 0) return 'Today';
  if (days == 1) return 'Yesterday';
  const months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  const weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  if (days > 1 && days < 7) return weekdays[that.weekday - 1];
  final month = months[that.month - 1];
  if (that.year == today.year) return '${that.day} $month';
  return '${that.day} $month ${that.year}';
}

/// One post as the view shows it.
class ChatMessage {
  /// The post's XPRS id (6 hex, docs XPRS.md section 5): what replies and
  /// likes name.
  final String id;

  /// The id of the post this one answers, if any.
  final String? parent;
  final String callsign;

  /// What to call the sender: a contact's name, else the nickname they sign
  /// with, else empty (the callsign alone).
  final String name;
  final bool outgoing;
  final String text;
  final DateTime time;
  final int likes;
  final bool liked;

  /// The sender is already in the address book.
  final bool isContact;

  const ChatMessage({
    required this.id,
    required this.callsign,
    required this.text,
    required this.time,
    this.parent,
    this.name = '',
    this.outgoing = false,
    this.likes = 0,
    this.liked = false,
    this.isContact = false,
  });

  String get day =>
      '${time.year.toString().padLeft(4, '0')}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
  String get clock => '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  String get who => name.isEmpty ? callsign : name;
}

class ChatView extends StatefulWidget {
  /// Oldest first.
  final List<ChatMessage> messages;

  /// Sends [text], answering [replyTo] when set. False when it is too long
  /// to send.
  final Future<bool> Function(String text, ChatMessage? replyTo) onSend;
  final void Function(ChatMessage m, bool like) onLike;
  final void Function(ChatMessage m) onHide;
  final void Function(ChatMessage m) onMute;
  final void Function(ChatMessage m)? onAddContact;

  /// What Info says about where messages go and how long they stay.
  final String infoText;
  final String hint;
  final String emptyText;
  final int maxLength;

  const ChatView({
    super.key,
    required this.messages,
    required this.onSend,
    required this.onLike,
    required this.onHide,
    required this.onMute,
    this.onAddContact,
    this.infoText = '',
    this.hint = 'Message',
    this.emptyText = 'No messages yet',
    this.maxLength = 850,
  });

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _input = TextEditingController();

  /// Keeps the caret in the composer after a send, so the next message needs
  /// no click into the box first.
  final _inputFocus = FocusNode();
  final _scroll = ScrollController();
  int _lastCount = 0;
  bool _sending = false;

  /// Post id to post, so a reply can quote what it answers.
  final Map<String, ChatMessage> _byId = {};

  /// Direct replies per post id ("N replies", and which posts open a thread).
  final Map<String, int> _replyCount = {};

  /// When set, the list shows one thread only (its first post and every
  /// reply in it); the back arrow returns to the whole room.
  String? _threadRoot;
  ChatMessage? _replyingTo;

  /// New messages only scroll the view while it is at the bottom, so reading
  /// back is not interrupted.
  bool _atBottom = true;

  // Derived indexes, rebuilt when the list changes, never per frame: a long
  // room walked twice per frame starves a slow phone.
  List<ChatMessage>? _indexed;

  void _refreshDerived(List<ChatMessage> src) {
    if (identical(src, _indexed)) return;
    _indexed = src;
    _byId.clear();
    _replyCount.clear();
    for (final m in src) {
      _byId[m.id] = m;
    }
    for (final m in src) {
      final p = m.parent;
      if (p != null) _replyCount[p] = (_replyCount[p] ?? 0) + 1;
    }
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoScroll());
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    _atBottom = (pos.maxScrollExtent - pos.pixels) <= 48;
  }

  /// Pins the view to the newest message. ListView.builder only estimates
  /// its extent from the items laid out so far, so one jump can land short;
  /// jump again until the extent stops growing (bounded).
  void _autoScroll({int tries = 8}) {
    if (!_scroll.hasClients) return;
    final target = _scroll.position.maxScrollExtent;
    _scroll.jumpTo(target);
    _atBottom = true;
    if (tries <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (_scroll.position.maxScrollExtent > target + 1) _autoScroll(tries: tries - 1);
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    // Inside a focused thread a plain post stays in the thread.
    final target = _replyingTo ?? (_threadRoot == null ? null : _byId[_threadRoot]);
    setState(() => _sending = true);
    final ok = await widget.onSend(text, target);
    if (!mounted) return;
    setState(() => _sending = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That message is too long for one post. Split it in two.')));
      return;
    }
    _input.clear();
    if (_replyingTo != null) setState(() => _replyingTo = null);
    _atBottom = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _inputFocus.requestFocus();
      _autoScroll();
    });
  }

  static const _likeColor = Color(0xFFE8638F);

  static Color _onBubbleFg(bool outgoing, int incomingAlpha) => Colors.white.withAlpha(outgoing ? 235 : incomingAlpha);

  static Color _onBubbleAccent(bool outgoing) => outgoing ? Colors.white : ChatPalette.accent;

  /// Heart and like count. Interactive on others' posts; on our own only
  /// the count (and nothing while nobody liked it).
  Widget _likeButton(ChatMessage m, {bool big = false}) {
    final outgoing = m.outgoing;
    if (outgoing && m.likes == 0) return const SizedBox.shrink();
    // On our own post a filled heart means "has been liked".
    final filled = outgoing ? m.likes > 0 : m.liked;
    final color = filled ? (outgoing ? Colors.white : _likeColor) : _onBubbleFg(outgoing, 140);
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(filled ? Icons.favorite : Icons.favorite_border, size: big ? 16 : 13, color: color),
        if (m.likes > 0) ...[
          const SizedBox(width: 3),
          Text(
            '${m.likes}',
            style: TextStyle(color: color, fontSize: big ? 12.5 : 10, fontWeight: FontWeight.w600),
          ),
        ],
      ],
    );
    final padded = Padding(padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1), child: child);
    if (outgoing) return padded;
    return InkWell(onTap: () => widget.onLike(m, !m.liked), borderRadius: BorderRadius.circular(4), child: padded);
  }

  /// Walks up the reply chain to the first loaded post of a thread.
  String _rootId(ChatMessage m) {
    var cur = m;
    final seen = <String>{};
    while (true) {
      final p = cur.parent;
      if (p == null) break;
      final parent = _byId[p];
      if (parent == null) break;
      seen.add(cur.id);
      if (seen.contains(parent.id)) break;
      cur = parent;
    }
    return cur.id;
  }

  bool _isThreaded(ChatMessage m) => m.parent != null || (_replyCount[m.id] ?? 0) > 0;

  void _openThread(ChatMessage m) {
    setState(() => _threadRoot = _rootId(m));
    _atBottom = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoScroll());
  }

  String _snippet(ChatMessage m) {
    var text = m.text.replaceAll('\n', ' ');
    if (text.length > 60) text = '${text.substring(0, 60)}...';
    return '${m.outgoing ? 'You' : m.who}: $text';
  }

  @override
  Widget build(BuildContext context) {
    _refreshDerived(widget.messages);
    final messages = widget.messages;
    if (messages.length != _lastCount) {
      final grew = messages.length > _lastCount;
      _lastCount = messages.length;
      if (grew && _atBottom) WidgetsBinding.instance.addPostFrameCallback((_) => _autoScroll());
    }
    return Container(
      color: ChatPalette.chatBg,
      child: Column(
        children: [
          Expanded(child: _messageList(messages)),
          const Divider(height: 1),
          _composeBar(),
        ],
      ),
    );
  }

  Widget _messageList(List<ChatMessage> messages) {
    final root = _threadRoot;
    if (root != null) {
      final members = [
        for (final m in messages)
          if (_rootId(m) == root) m,
      ];
      if (members.isEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _threadRoot = null);
        });
      }
      final op = _byId[root];
      final replies = [
        for (final m in members)
          if (m.id != root) m,
      ];
      var totalLikes = 0;
      for (final m in members) {
        totalLikes += m.likes;
      }
      return Column(
        children: [
          op != null ? _threadTopic(op, members.length, totalLikes) : _threadHeader(members.length),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              itemCount: op != null ? replies.length : members.length,
              itemBuilder: (context, i) => _bubble(op != null ? replies[i] : members[i], inThread: true),
            ),
          ),
        ],
      );
    }
    if (messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            widget.emptyText,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white.withAlpha(110), fontSize: 13),
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      itemCount: messages.length,
      itemBuilder: (context, i) {
        final bubble = _bubble(messages[i]);
        final head = _dayHeader(messages, i);
        if (head == null) return bubble;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [head, bubble]);
      },
    );
  }

  Widget? _dayHeader(List<ChatMessage> messages, int i) {
    final day = messages[i].day;
    if (i > 0 && messages[i - 1].day == day) return null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: ChatPalette.inBubble, borderRadius: BorderRadius.circular(10)),
          child: Text(
            chatDayLabel(day),
            style: const TextStyle(color: ChatPalette.secondary, fontSize: 11.5, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }

  /// A thread's first post shown as its topic: back arrow, the post in
  /// full, how many messages and likes the thread has, and its like.
  Widget _threadTopic(ChatMessage op, int count, int totalLikes) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: ChatPalette.accent.withAlpha(26),
        border: Border(bottom: BorderSide(color: ChatPalette.accent.withAlpha(90), width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _threadRoot = null),
            child: const Padding(
              padding: EdgeInsets.fromLTRB(8, 8, 12, 2),
              child: Row(
                children: [
                  Icon(Icons.arrow_back, size: 18, color: ChatPalette.accent),
                  SizedBox(width: 6),
                  Text(
                    'Back to chat',
                    style: TextStyle(color: ChatPalette.accent, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(child: _sender(op, big: true)),
                    const SizedBox(width: 8),
                    Text(op.clock, style: TextStyle(color: Colors.white.withAlpha(120), fontSize: 10)),
                  ],
                ),
                const SizedBox(height: 5),
                SelectableText(
                  op.text,
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600, height: 1.25),
                ),
                const SizedBox(height: 9),
                Row(
                  children: [
                    Icon(Icons.forum_outlined, size: 14, color: Colors.white.withAlpha(160)),
                    const SizedBox(width: 5),
                    Text(
                      '$count message${count == 1 ? '' : 's'}',
                      style: TextStyle(color: Colors.white.withAlpha(180), fontSize: 12.5, fontWeight: FontWeight.w600),
                    ),
                    if (totalLikes > 0) ...[
                      const SizedBox(width: 12),
                      const Icon(Icons.favorite, size: 12, color: _likeColor),
                      const SizedBox(width: 4),
                      Text(
                        '$totalLikes',
                        style: const TextStyle(color: _likeColor, fontSize: 12.5, fontWeight: FontWeight.w600),
                      ),
                    ],
                    const Spacer(),
                    _likeButton(op, big: true),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _threadHeader(int count) {
    return InkWell(
      onTap: () => setState(() => _threadRoot = null),
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
        color: ChatPalette.accent.withAlpha(22),
        child: Row(
          children: [
            const Icon(Icons.arrow_back, size: 18, color: ChatPalette.accent),
            const SizedBox(width: 8),
            Text(
              'Thread, $count message${count == 1 ? '' : 's'}',
              style: const TextStyle(color: ChatPalette.accent, fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            Text('Back to chat', style: TextStyle(color: Colors.white.withAlpha(120), fontSize: 11)),
          ],
        ),
      ),
    );
  }

  /// Avatar, name (a contact's or the signed nickname) and the callsign,
  /// which is always shown: a nickname is chosen by its owner and proves
  /// nothing on its own.
  Widget _sender(ChatMessage m, {bool big = false}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GeneratedAvatar(seed: m.callsign, size: big ? 18 : 16),
        const SizedBox(width: 5),
        if (m.name.isNotEmpty) ...[
          Flexible(
            child: Text(
              m.name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: m.isContact ? const Color(0xFF4CAF82) : ChatPalette.accent,
                fontSize: big ? 13 : 11.5,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 5),
        ],
        Text(
          m.callsign,
          style: TextStyle(
            color: m.name.isEmpty ? ChatPalette.accent : Colors.white.withAlpha(120),
            fontSize: m.name.isEmpty ? (big ? 13 : 11) : 9.5,
            fontWeight: m.name.isEmpty ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ],
    );
  }

  Widget _bubble(ChatMessage m, {bool inThread = false}) {
    final outgoing = m.outgoing;
    final parent = m.parent;
    final replies = _replyCount[m.id] ?? 0;
    final canOpen = !inThread && _isThreaded(m);
    final bubble = Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      constraints: const BoxConstraints(maxWidth: 440),
      decoration: BoxDecoration(
        color: outgoing ? ChatPalette.outBubble : ChatPalette.inBubble,
        borderRadius: BorderRadius.circular(16),
      ),
      child: IntrinsicWidth(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // In a focused thread, replies to its first post do not quote it.
            if (parent != null && !(inThread && parent == _threadRoot)) _quotedParent(parent, outgoing),
            if (!outgoing) Padding(padding: const EdgeInsets.only(bottom: 2), child: _sender(m)),
            Text(m.text, style: const TextStyle(color: Colors.white, fontSize: 14)),
            Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(m.clock, style: TextStyle(color: _onBubbleFg(outgoing, 115), fontSize: 10)),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap: () => setState(() => _replyingTo = m),
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.reply, size: 12, color: _onBubbleFg(outgoing, 140)),
                        const SizedBox(width: 2),
                        Text('Reply', style: TextStyle(color: _onBubbleFg(outgoing, 140), fontSize: 10)),
                      ],
                    ),
                  ),
                ),
                if (replies > 0 && !inThread) ...[
                  const SizedBox(width: 10),
                  InkWell(
                    onTap: () => _openThread(m),
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.forum_outlined, size: 12, color: _onBubbleAccent(outgoing)),
                          const SizedBox(width: 3),
                          Text(
                            '$replies ${replies == 1 ? 'reply' : 'replies'}',
                            style: TextStyle(
                              color: _onBubbleAccent(outgoing),
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 10),
                _likeButton(m),
                // The desktop-friendly way to the menu, without a long press.
                const SizedBox(width: 8),
                InkWell(
                  onTap: () => _showMessageMenu(m),
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
                    child: Icon(Icons.more_vert, size: 15, color: _onBubbleFg(outgoing, 150)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    return Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: () => _showMessageMenu(m),
        onTap: canOpen ? () => _openThread(m) : null,
        child: bubble,
      ),
    );
  }

  void _showMessageMenu(ChatMessage m) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheet) {
        void act(VoidCallback f) {
          Navigator.pop(sheet);
          f();
        }

        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.public),
                  title: const Text('Info'),
                  onTap: () => act(() => _showInfo(m)),
                ),
                ListTile(
                  leading: const Icon(Icons.copy),
                  title: const Text('Copy'),
                  onTap: () => act(() => _copyText(m.text)),
                ),
                ListTile(
                  leading: const Icon(Icons.reply),
                  title: const Text('Reply'),
                  onTap: () => act(() => setState(() => _replyingTo = m)),
                ),
                ListTile(
                  leading: const Icon(Icons.visibility_off_outlined),
                  title: const Text('Hide this message'),
                  onTap: () => act(() => widget.onHide(m)),
                ),
                if (!m.outgoing && !m.isContact && widget.onAddContact != null)
                  ListTile(
                    leading: const Icon(Icons.person_add_alt),
                    title: Text('Add ${m.who} to contacts'),
                    onTap: () => act(() => widget.onAddContact!(m)),
                  ),
                if (!m.outgoing)
                  ListTile(
                    leading: const Icon(Icons.volume_off_outlined, color: Colors.red),
                    title: Text('Mute ${m.who}', style: const TextStyle(color: Colors.red)),
                    subtitle: const Text('Hides everything they wrote, on this device only'),
                    onTap: () => act(() => widget.onMute(m)),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showInfo(ChatMessage m) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.public, color: Color(0xFFE0A030), size: 20),
            SizedBox(width: 8),
            Text('Public', style: TextStyle(color: Color(0xFFE0A030))),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.infoText.isNotEmpty) Text(widget.infoText),
            const SizedBox(height: 12),
            if (m.name.isNotEmpty) _infoRow('Name', m.name),
            _infoRow('Callsign', m.callsign),
            _infoRow('Time', '${m.day} ${m.clock}'),
            _infoRow('Signature', 'Signed, author verified'),
            _infoRow('Id', m.id),
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }

  Widget _infoRow(String label, String value) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 84,
          child: Text(label, style: TextStyle(color: Colors.white.withAlpha(140), fontSize: 12.5)),
        ),
        Expanded(child: SelectableText(value, style: const TextStyle(fontSize: 12.5))),
      ],
    ),
  );

  void _copyText(String text) {
    if (text.trim().isEmpty) return;
    unawaited(Clipboard.setData(ClipboardData(text: text.trim())));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Message copied'), duration: Duration(seconds: 1)));
    }
  }

  /// The post this one answers, quoted in a line: its author and text when
  /// loaded, else its id.
  Widget _quotedParent(String parentId, bool outgoing) {
    final p = _byId[parentId];
    final label = p != null ? _snippet(p) : '#$parentId';
    final accent = _onBubbleAccent(outgoing);
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(8, 3, 8, 3),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(18),
        borderRadius: BorderRadius.circular(6),
        border: Border(left: BorderSide(color: accent, width: 2.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.subdirectory_arrow_right, size: 12, color: accent.withAlpha(200)),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.white.withAlpha(170), fontSize: 11, fontStyle: FontStyle.italic),
            ),
          ),
        ],
      ),
    );
  }

  Widget _replyBanner() {
    final m = _replyingTo!;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      color: ChatPalette.windowBg,
      child: Row(
        children: [
          const Icon(Icons.reply, size: 14, color: ChatPalette.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Replying to ${_snippet(m)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.white.withAlpha(180), fontSize: 12),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            color: Colors.white.withAlpha(150),
            visualDensity: VisualDensity.compact,
            tooltip: 'Cancel the reply',
            onPressed: () => setState(() => _replyingTo = null),
          ),
        ],
      ),
    );
  }

  Widget _composeBar() {
    final row = Container(
      color: ChatPalette.windowBg,
      padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              focusNode: _inputFocus,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              minLines: 1,
              maxLines: 4,
              maxLength: widget.maxLength,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                hintText: widget.hint,
                hintStyle: TextStyle(color: Colors.white.withAlpha(90)),
                counterText: '',
                isDense: true,
                filled: true,
                fillColor: Colors.white.withAlpha(15),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: _sending
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send),
            color: ChatPalette.accent,
            tooltip: 'Send',
            onPressed: _sending ? null : _send,
          ),
        ],
      ),
    );
    if (_replyingTo == null) return row;
    return Column(mainAxisSize: MainAxisSize.min, children: [_replyBanner(), row]);
  }
}
