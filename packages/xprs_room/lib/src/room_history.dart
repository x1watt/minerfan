// History catch-up for a room, docs XPRS.md 11.2 and 11.2.1.
//
// Serving is lifted from the xprs app's XprsHistoryServer.serveInline and
// _result (app/lib/services/xprs/xprs_history_server.dart, BSD-3-Clause,
// Max Brito): a signed `t:result code:202`, the original wires newest first
// (the authors' packets, byte for byte), then `code:200`, or `code:206` when
// more is held, or a single `code:404`; the identity lines of the authors on
// the page ride ahead of it so a newcomer can check every signature. The
// room differs in three ways: the store is a RoomStore, nothing older than
// the room keeps (two weeks) is served, and a page ends at 50 items or
// 28 KB counting those identity lines (an I2P frame carries 32 KB), never inside a group of items sharing one second (so moving
// `until:` to the page's oldest time loses nothing). Asking follows the
// app's XprsCatchup: one window at most seven days (12.10.1), 206 chains by
// moving `until:`, and a window that stops moving is abandoned.

import 'package:xprs_wire/xprs_wire.dart';

import 'room_item.dart';
import 'room_store.dart';

/// A `cmd:history` for this room: from whom, the window and the kinds.
class HistoryAsk {
  final String asker;
  final String askId;
  final int? sinceMs;
  final int? untilMs;
  final Set<String> kinds;
  HistoryAsk(this.asker, this.askId, this.sinceMs, this.untilMs, this.kinds);
}

/// [p] as a history ask for [room] (addressed to the room or naming it in
/// `only:`), or null.
HistoryAsk? parseHistoryAsk(XprsPacket p, String room) {
  if (p.type != 'command' || p['cmd'] != 'history') return null;
  final d = (p['d'] ?? '').toUpperCase(), only = (p['only'] ?? '').toUpperCase();
  if (d != room && only != room) return null;
  final kinds = (p['kind'] ?? 'message,reaction').split(',').map((k) => k.trim()).where((k) => k.isNotEmpty).toSet();
  return HistoryAsk((p['f'] ?? '').toUpperCase(), xprsIdentifier(p), xprsParseTs(p['since']), xprsParseTs(p['until']),
      kinds.intersection({'message', 'reaction'}));
}

/// One page of an answer: the items newest first and whether more is held.
class HistoryPage {
  final List<RoomItem> items;
  final bool more;
  final List<String> identityWires;
  HistoryPage(this.items, this.more, this.identityWires);
}

/// The page [store] answers [ask] with.
HistoryPage planHistory(RoomStore store, HistoryAsk ask, {int maxItems = 50, int maxBytes = 28 * 1024}) {
  final all = store.query(sinceMs: ask.sinceMs, untilMs: ask.untilMs, kinds: ask.kinds);
  final page = <RoomItem>[];
  final ids = <String>[];
  final authors = <String>{};
  var bytes = 0;
  var i = 0;
  for (; i < all.length; i++) {
    final it = all[i];
    // An author new to the page brings their identity line along.
    final id = authors.contains(it.from) ? null : store.identities[it.from]?.wire;
    final cost = it.bytes + (id == null ? 0 : id.length + 1);
    final full = page.length >= maxItems || bytes + cost > maxBytes;
    // Never end a page inside one second: `until:` is exclusive.
    if (full && (page.isEmpty || it.tsMs != page.last.tsMs)) break;
    page.add(it);
    if (authors.add(it.from) && id != null) ids.add(id);
    bytes += cost;
  }
  return HistoryPage(page, i < all.length, ids);
}

/// A signed `t:result` line (port of the app's `_result`): `f:` us, `d:` the
/// asker, `r:` the ask's identifier, `code:`. Curve math: call it off the UI
/// isolate.
String signResult(String privHex, String self, String asker, String askId, int code, {String? m}) {
  final p = XprsPacket.parse('t:result f:$self d:$asker ts:${xprsNowTs()} r:$askId code:$code${m == null ? '' : ' m:$m'}')!;
  return xprsSign(p, BigInt.parse(privHex, radix: 16)).encode();
}

/// The lines of an answer, in order (identities, 202, wires, 200 or 206; or
/// a lone 404). Signs, so run it off the UI isolate.
List<String> buildHistoryReply(String privHex, String self, HistoryAsk ask, HistoryPage page) {
  if (page.items.isEmpty) return [signResult(privHex, self, ask.asker, ask.askId, 404)];
  return [
    ...page.identityWires,
    signResult(privHex, self, ask.asker, ask.askId, 202),
    for (final it in page.items) ...it.wires,
    signResult(privHex, self, ask.asker, ask.askId, page.more ? 206 : 200),
  ];
}

/// How many pages a responder serves: per asker and in total, per hour
/// (the app's budgets, scaled for a bearer with no airtime to share).
class HistoryBudget {
  final int perAsker;
  final int total;
  final _asked = <String, List<int>>{};
  final _all = <int>[];
  HistoryBudget({this.perAsker = 30, this.total = 240});

  bool allow(String asker, int nowMs) {
    bool fits(List<int> l, int n) {
      l.removeWhere((t) => nowMs - t >= 3600000);
      return l.length < n;
    }

    final mine = _asked.putIfAbsent(asker, () => []);
    if (!fits(mine, perAsker) || !fits(_all, total)) return false;
    mine.add(nowMs);
    _all.add(nowMs);
    return true;
  }
}

/// A newcomer's catch-up (or a member's gap fill): windows of at most seven
/// days, newest first, each followed through 206 pages.
class HistoryFetch {
  final List<(int since, int until)> _windows;
  int _w = 0;
  int? _until;
  int? _lastUntil;
  bool get done => _w >= _windows.length;

  HistoryFetch(this._windows);

  /// The last [keep] (14 days) as two seven-day windows, newest first.
  factory HistoryFetch.catchUp(int nowMs, {Duration keep = const Duration(days: 14)}) {
    const week = 7 * 24 * 3600 * 1000;
    final from = nowMs - keep.inMilliseconds;
    final windows = <(int, int)>[];
    // The first window reaches a minute past now (clocks differ a little).
    var until = nowMs + 60000, since = nowMs - week;
    while (true) {
      if (since < from) since = from;
      windows.add((since, until));
      if (since <= from) break;
      until = since;
      since = until - week;
    }
    return HistoryFetch(windows);
  }

  /// Only what is newer than [sinceMs] (a member's periodic gap fill).
  factory HistoryFetch.since(int sinceMs, int nowMs) => HistoryFetch([(sinceMs, nowMs + 60000)]);

  /// The window to ask for next, or null when finished.
  (int since, int until)? next() {
    if (done) return null;
    final (since, until) = _windows[_w];
    return (since, _until ?? until);
  }

  /// Takes an answer: [code] and the oldest `ts:` on the page.
  void answered(int code, int? oldestMs) {
    if (done) return;
    if (code == 206 && oldestMs != null && oldestMs != _lastUntil) {
      _lastUntil = oldestMs;
      _until = oldestMs;
      return;
    }
    // 200, 404, or a 206 that did not move: this window is finished.
    _w++;
    _until = null;
    _lastUntil = null;
  }

  /// The responder refused or stayed silent: the same window goes to
  /// someone else.
  void failed() {}
}
