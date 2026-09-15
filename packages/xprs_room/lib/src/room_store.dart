import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:xprs_wire/xprs_wire.dart';

import 'room_item.dart';

/// What happened to an item offered to the store.
enum Admit { stored, duplicate, muted, hidden, tooOld, future, flood, notThisRoom }

/// A room's last two weeks on disk, and the local choices about it (who is
/// muted, what is hidden, what was read).
///
/// Admission follows the xprs chat wapp's `room_admit` (apps/chat/room.c):
/// muted, then hidden, then duplicate, then stored, then unread. Duplicates
/// are by the full hash of the canonical packet; the six-character
/// identifier only names posts in replies and reactions.
///
/// Files under [dir], JSON lines so the format can grow:
/// - `YYYY-MM-DD.jsonl` (UTC day of the item's `ts:`): `{"w": [wires]}`;
/// - `identities.jsonl`: the newest signed `t:identity` per callsign;
/// - `local.json`: muted callsigns, hidden posts, the last read time.
/// Nothing older than [keep] is kept or served: the room's "two weeks".
class RoomStore {
  final String dir;
  final String room;
  final int Function() now;
  final Duration keep;
  final int maxBytes;

  RoomStore(this.dir, this.room,
      {int Function()? now, this.keep = const Duration(days: 14), this.maxBytes = 8 * 1024 * 1024})
      : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final _items = <String, RoomItem>{}; // full hash -> item
  final _posts = <String, RoomItem>{}; // identifier -> post
  final _reactions = <String, Map<String, (int, bool)>>{}; // post id -> callsign -> (ts, likes)
  final identities = <String, RoomIdentity>{};
  final muted = <String>{};
  final hidden = <String>{};
  int lastReadMs = 0;
  Future<void> _writing = Future.value();

  int get _cutoff => now() - keep.inMilliseconds;

  // ---- reading ----

  bool has(String key) => _items.containsKey(key);
  RoomItem? post(String id) => _posts[id];
  int get count => _items.length;

  /// Newest post time, or null for an empty room.
  int? get newestMs => _items.isEmpty ? null : _items.values.map((i) => i.tsMs).reduce((a, b) => a > b ? a : b);

  /// The posts to show, oldest first: not hidden, not from muted callsigns.
  List<RoomItem> visiblePosts({int limit = 500}) {
    final l = [
      for (final i in _items.values)
        if (i.isPost && !muted.contains(i.from) && !hidden.contains(i.id)) i,
    ]..sort((a, b) => a.tsMs.compareTo(b.tsMs));
    return l.length > limit ? l.sublist(l.length - limit) : l;
  }

  /// How many callsigns like [id] now (the newest reaction of each wins).
  int likes(String id) => (_reactions[id]?.values.where((r) => r.$2).length) ?? 0;
  bool likedBy(String id, String callsign) => _reactions[id]?[callsign]?.$2 ?? false;

  /// Posts from others since the room was last read.
  int get unread => _items.values
      .where((i) => i.isPost && i.tsMs > lastReadMs && !muted.contains(i.from) && !hidden.contains(i.id))
      .length;

  /// Items newest first in `[sinceMs, untilMs)` of [kinds], for history
  /// (section 11.2: records strictly older than `until:`).
  List<RoomItem> query({int? sinceMs, int? untilMs, Set<String> kinds = const {'message', 'reaction'}}) {
    final since = sinceMs == null || sinceMs < _cutoff ? _cutoff : sinceMs;
    final until = untilMs ?? now() + 1;
    return [
      for (final i in _items.values)
        if (kinds.contains(i.kind) && i.tsMs >= since && i.tsMs < until) i,
    ]..sort((a, b) => b.tsMs.compareTo(a.tsMs));
  }

  // ---- changing ----

  /// Keeps [item] when it belongs here and persists it. The caller checked
  /// its signature (and, for fresh posts, the flood limits).
  Admit admit(RoomItem item) {
    if (item.room != room) return Admit.notThisRoom;
    if (muted.contains(item.from)) return Admit.muted;
    if (item.isPost && hidden.contains(item.id)) return Admit.hidden;
    if (item.tsMs < _cutoff) return Admit.tooOld;
    if (item.tsMs > now() + 10 * 60 * 1000) return Admit.future;
    if (_items.containsKey(item.key)) return Admit.duplicate;
    _put(item);
    final line = jsonEncode({'w': item.wires});
    final day = _day(item.tsMs);
    _append('$dir/$day.jsonl', line);
    return Admit.stored;
  }

  void _put(RoomItem item) {
    _items[item.key] = item;
    if (item.isPost) {
      _posts[item.id] = item;
    } else if (item.isReaction && item.replyTo != null) {
      final m = _reactions.putIfAbsent(item.replyTo!, () => {});
      final old = m[item.from];
      if (old == null || old.$1 <= item.tsMs) m[item.from] = (item.tsMs, item.likes);
    }
  }

  /// Remembers [id] when it is newer than what is known for its callsign.
  bool putIdentity(RoomIdentity id) {
    final old = identities[id.callsign];
    if (old != null && old.tsMs >= id.tsMs) return false;
    identities[id.callsign] = id;
    _saveIdentities();
    return true;
  }

  void mute(String callsign) {
    muted.add(callsign.toUpperCase());
    _saveLocal();
  }

  void unmute(String callsign) {
    muted.remove(callsign.toUpperCase());
    _saveLocal();
  }

  void hide(String id) {
    hidden.add(id);
    _saveLocal();
  }

  void markRead() {
    final n = newestMs ?? now();
    if (n <= lastReadMs) return;
    lastReadMs = n;
    _saveLocal();
  }

  /// Drops items older than [keep] and, past [maxBytes], the oldest days.
  Future<void> prune() async {
    final cut = _cutoff;
    _items.removeWhere((_, i) => i.tsMs < cut);
    var bytes = _items.values.fold<int>(0, (a, i) => a + i.bytes);
    if (bytes > maxBytes) {
      final byAge = _items.values.toList()..sort((a, b) => a.tsMs.compareTo(b.tsMs));
      for (final i in byAge) {
        if (bytes <= maxBytes) break;
        _items.remove(i.key);
        bytes -= i.bytes;
      }
    }
    _rebuildIndexes();
    await _writing;
    final keepDays = {for (final i in _items.values) _day(i.tsMs)};
    final d = Directory(dir);
    if (!await d.exists()) return;
    await for (final f in d.list()) {
      final name = f.uri.pathSegments.last;
      if (!name.endsWith('.jsonl') || name == 'identities.jsonl') continue;
      final day = name.substring(0, name.length - 6);
      if (!keepDays.contains(day)) {
        await f.delete();
      } else if (day == _day(cut)) {
        // The boundary day: rewrite it without what fell out of the window.
        await _rewriteDay(day);
      }
    }
  }

  void _rebuildIndexes() {
    _posts.clear();
    _reactions.clear();
    final all = _items.values.toList()..sort((a, b) => a.tsMs.compareTo(b.tsMs));
    for (final i in all) {
      _put(i);
    }
  }

  Future<void> _rewriteDay(String day) async {
    final lines = [
      for (final i in _items.values)
        if (_day(i.tsMs) == day) jsonEncode({'w': i.wires}),
    ];
    await File('$dir/$day.jsonl').writeAsString(lines.isEmpty ? '' : '${lines.join('\n')}\n');
  }

  // ---- files ----

  /// Loads what the files hold (parsing on a short-lived isolate).
  Future<void> load() async {
    final d = Directory(dir);
    if (!await d.exists()) return;
    final path = dir, cut = _cutoff;
    final loaded = await _readRoomOff(path, cut);
    for (final wires in loaded.items) {
      final item = rebuildItem(wires);
      if (item != null && item.room == room) _put(item);
    }
    for (final w in loaded.identities) {
      final id = identityFromWire(w);
      if (id != null) identities[id.callsign] = id;
    }
    muted.addAll(loaded.muted);
    hidden.addAll(loaded.hidden);
    lastReadMs = loaded.lastRead;
  }

  void _append(String path, String line) {
    _writing = _writing.then((_) async {
      try {
        await Directory(dir).create(recursive: true);
        await File(path).writeAsString('$line\n', mode: FileMode.append, flush: true);
      } catch (_) {}
    });
  }

  void _saveIdentities() {
    final text = [for (final i in identities.values) jsonEncode({'w': [i.wire]})].join('\n');
    _replace('$dir/identities.jsonl', '$text\n');
  }

  void _saveLocal() {
    _replace('$dir/local.json',
        jsonEncode({'muted': muted.toList(), 'hidden': hidden.toList(), 'lastRead': lastReadMs}));
  }

  void _replace(String path, String text) {
    _writing = _writing.then((_) async {
      try {
        await Directory(dir).create(recursive: true);
        final tmp = File('$path.tmp');
        await tmp.writeAsString(text, flush: true);
        await tmp.rename(path);
      } catch (_) {}
    });
  }

  /// Waits for pending writes (tests, shutdown).
  Future<void> flush() => _writing;

  static String _day(int ms) => xprsNowTs(ms).substring(0, 10);
}

/// An item from its stored wires: one packet, or parts rejoined (the last
/// part carries the signature of the whole, section 9.1.1).
RoomItem? rebuildItem(List<String> wires) {
  if (wires.isEmpty) return null;
  final packets = [for (final w in wires) XprsPacket.parse(w)];
  if (packets.any((p) => p == null)) return null;
  if (packets.length == 1 && !packets.first!.has('n')) return RoomItem(packets.first!, wires);
  final table = XprsPartTable();
  XprsReassembled? whole;
  final at = DateTime.now();
  for (final p in packets) {
    whole = table.offer(p!, clear: p['m'] ?? '', now: at) ?? whole;
  }
  if (whole == null || whole.sig == null) return null;
  return RoomItem(whole.packet.with_('sig', whole.sig!), wires);
}

/// A [RoomIdentity] from a stored `t:identity` wire (checked when it came in).
RoomIdentity? identityFromWire(String wire) {
  final p = XprsPacket.parse(wire);
  if (p == null || p.type != 'identity') return null;
  try {
    return RoomIdentity((p['f'] ?? '').toUpperCase(), NostrCrypto.decodeNpub(p['k'] ?? ''), p['nick'] ?? '',
        xprsParseTs(p['ts']) ?? 0, wire);
  } catch (_) {
    return null;
  }
}

// A top-level function, so the isolate's closure holds only its arguments.
Future<_Loaded> _readRoomOff(String dir, int cutoff) => Isolate.run(() => _readRoom(dir, cutoff));

typedef _Loaded = ({List<List<String>> items, List<String> identities, List<String> muted, List<String> hidden, int lastRead});

_Loaded _readRoom(String dir, int cutoff) {
  final items = <List<String>>[];
  final ids = <String>[];
  var muted = <String>[], hidden = <String>[];
  var lastRead = 0;
  final cutDay = xprsNowTs(cutoff).substring(0, 10);
  for (final f in Directory(dir).listSync().whereType<File>()) {
    final name = f.uri.pathSegments.last;
    try {
      if (name == 'local.json') {
        final m = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
        muted = [for (final c in (m['muted'] as List?) ?? const []) '$c'];
        hidden = [for (final c in (m['hidden'] as List?) ?? const []) '$c'];
        lastRead = (m['lastRead'] as num?)?.toInt() ?? 0;
      } else if (name.endsWith('.jsonl')) {
        final isIds = name == 'identities.jsonl';
        if (!isIds && name.substring(0, name.length - 6).compareTo(cutDay) < 0) continue;
        for (final line in f.readAsLinesSync()) {
          if (line.trim().isEmpty) continue;
          final w = [for (final x in ((jsonDecode(line) as Map)['w'] as List?) ?? const []) '$x'];
          if (isIds) {
            ids.addAll(w);
          } else {
            items.add(w);
          }
        }
      }
    } catch (_) {}
  }
  return (items: items, identities: ids, muted: muted, hidden: hidden, lastRead: lastRead);
}
