import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:xprs_wire/xprs_wire.dart';

import 'flood_guard.dart';
import 'member_table.dart';
import 'room_crypto.dart';
import 'room_history.dart';
import 'room_item.dart';
import 'room_store.dart';

/// A frame on the room's port: from which address, to which (ours or a
/// room meeting address), and its text.
class RoomFrame {
  final String fromB32;
  final String? toB32;
  final String payload;
  RoomFrame(this.fromB32, this.toB32, this.payload);
}

/// Carries a room's frames: sends text to an address, delivers what
/// arrives. The app's is I2P; tests use an in-memory network.
abstract class RoomBearer {
  Stream<RoomFrame> get frames;
  Future<bool> send(String b32, String payload);
}

/// Runs curve math away from the caller's isolate ([Isolate.run] by
/// default; tests pass one that runs inline).
typedef Runner = Future<R> Function<R>(R Function() task);

Future<R> _isolateRunner<R>(R Function() task) => Isolate.run(task);

// Top-level wrappers: an Isolate.run closure made here holds only these
// arguments, never the engine.
Future<CheckedFrame> _check(Runner run, List<String> lines, Map<String, String> known) =>
    run(() => checkRoomFrame(lines, known));
Future<bool> _verifyJoined(Runner run, String wire, String key) => run(() => verifyJoined(wire, key));
Future<String> _identity(Runner run, String priv, String nick) => run(() => signRoomIdentity(priv, nick));
Future<List<String>> _post(Runner run, String priv, String self, String room, String text, String? r, String? root) =>
    run(() => signRoomPost(priv, self, room, text, replyTo: r, root: root));
Future<String> _react(Runner run, String priv, String self, String room, String id, bool like) =>
    run(() => signReaction(priv, self, room, id, like));
Future<String> _ask(Runner run, String priv, String self, String room, int since, int until) =>
    run(() => signHistoryAsk(priv, self, room, since, until));
Future<List<String>> _reply(Runner run, String priv, String self, HistoryAsk ask, HistoryPage page) =>
    run(() => buildHistoryReply(priv, self, ask, page));
Future<String> _result(Runner run, String priv, String self, String asker, String askId, int code, String? m) =>
    run(() => signResult(priv, self, asker, askId, code, m: m));

/// How the room is doing, for the screen.
enum RoomState { offline, searching, alone, connected }

/// What became of a post.
enum Posted { stored, tooLong }

/// One room: an XPRS open group (docs XPRS.md 7.3) kept among its members.
///
/// - Joining greets the room's meeting addresses and the members it
///   remembers (`hello`); whoever answers lists the members they know
///   (`members`), and the newest two weeks come by catch-up (11.2).
/// - A post is signed once and pushed to up to [pushTo] live members; every
///   [pullEvery] each member asks a random live member what is new, which
///   fills whatever a push missed. When the room has more live members than
///   [pushTo], receivers also pass fresh posts on to [relayTo] others
///   (`via:` grows, at most three hops, section 9.1).
/// - No moderators: posts over the flood limits, from muted callsigns, or
///   outside the two weeks are neither kept nor passed on.
///
/// Control frames are JSON (`{"v":1,"type":"hello"|"members",...}`); XPRS
/// frames are wire lines led by the sender's signed `t:identity`.
class RoomEngine {
  final String room;
  final RoomStore store;
  final MemberTable members;
  final RoomBearer bearer;
  final String privHex;
  final String self;
  final Runner run;
  final int Function() now;
  final Random rng;
  final int pushTo;
  final int relayTo;
  final Duration pullEvery;

  /// How long to wait for a history answer before asking someone else.
  final Duration askTimeout;
  final void Function(String line)? log;

  RoomEngine({
    required this.room,
    required this.store,
    required this.bearer,
    required this.privHex,
    required this.self,
    MemberTable? members,
    HistoryBudget? budget,
    Runner? run,
    int Function()? now,
    Random? rng,
    this.pushTo = 10,
    this.relayTo = 2,
    this.pullEvery = const Duration(minutes: 5),
    this.askTimeout = const Duration(seconds: 45),
    this.log,
  })  : members = members ?? MemberTable(),
        budget = budget ?? HistoryBudget(),
        run = run ?? _isolateRunner,
        now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
        rng = rng ?? Random.secure();

  final flood = FloodGuard();
  final HistoryBudget budget;
  final _greeted = <String, int>{};
  final _parts = XprsPartTable();
  final _partWires = <String, Map<int, String>>{};
  final _changes = StreamController<void>.broadcast();
  StreamSubscription<RoomFrame>? _sub;
  final _timers = <Timer>[];

  String? myB32;
  List<String> meetingPoints = const [];
  String _nick = '';
  String? _identityLine;
  int _identityAt = 0;

  HistoryFetch? _fetch;
  ({String b32, String askId, int deadline})? _pending;
  bool caughtUp = false;
  final _triedForHistory = <String>{};

  /// Fires after anything the screen shows changed.
  Stream<void> get changes => _changes.stream;

  RoomState get state {
    if (myB32 == null) return RoomState.offline;
    if (members.recent(now()).isNotEmpty) return RoomState.connected;
    return _started + 90000 < now() ? RoomState.alone : RoomState.searching;
  }

  int _started = 0;

  int get liveCount => members.recent(now()).length;

  set nick(String v) {
    final n = xprsNick(v);
    if (n == _nick) return;
    _nick = n;
    _identityLine = null;
  }

  String get _membersFile => '${store.dir}/members.json';

  /// Loads the store and remembered members, and listens to the bearer.
  Future<void> start() async {
    await store.load();
    try {
      final f = File(_membersFile);
      if (await f.exists()) members.load(jsonDecode(await f.readAsString()) as List);
    } catch (_) {}
    _sub = bearer.frames.listen((f) => unawaited(_onFrame(f)));
    _changes.add(null);
  }

  /// The network is up: our address and the room's meeting addresses.
  void online(String b32, List<String> meeting) {
    myB32 = b32;
    members.self = b32;
    members.forget(b32);
    meetingPoints = meeting;
    _started = now();
    for (final t in _timers) {
      t.cancel();
    }
    _timers
      ..clear()
      // Up to a fifth longer at random, so members do not all ask at once.
      ..add(Timer.periodic(pullEvery * (1 + rng.nextDouble() / 5), (_) => unawaited(_gapFill())))
      ..add(Timer.periodic(const Duration(minutes: 15), (_) => unawaited(_greet(meeting: 1, known: 2))))
      ..add(Timer.periodic(askTimeout ~/ 3, (_) => _checkPending()))
      ..add(Timer.periodic(const Duration(hours: 1), (_) => unawaited(_housekeeping())));
    unawaited(_greet(meeting: meetingPoints.length, known: 5));
    // A member that came up at the same moment has not published its
    // meeting address yet: greet again soon while nobody answered.
    for (final s in const [20, 60, 150]) {
      _timers.add(Timer(Duration(seconds: s), () {
        if (members.recent(now()).isEmpty) unawaited(_greet(meeting: meetingPoints.length, known: 5));
      }));
    }
    _changes.add(null);
  }

  void offline() {
    myB32 = null;
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    _changes.add(null);
  }

  Future<void> close() async {
    offline();
    await _sub?.cancel();
    await _saveMembers();
    await store.flush();
    await _changes.close();
  }

  /// Someone who might be in the room (a contact's I2P address).
  void hint(String b32, String callsign) => members.offer(b32, callsign, now());

  // ---- saying things ----

  /// Posts [text]; [replyTo] answers a post. Returns once it is signed and
  /// kept here ([Posted.stored]); the push to the members runs on, and
  /// whoever it misses gets it by their next catch-up. [Posted.tooLong] when
  /// it does not fit in nine parts (XPRS section 6.6: about a thousand
  /// characters).
  Future<Posted> post(String text, {RoomItem? replyTo}) async {
    if (text.trim().isEmpty) return Posted.tooLong;
    final root = replyTo == null ? null : (replyTo.root ?? replyTo.id);
    final wires = await _post(run, privHex, self, room, text, replyTo?.id, root);
    final item = rebuildItem(wires);
    if (item == null) return Posted.tooLong;
    store.admit(item);
    store.markRead();
    _changes.add(null);
    unawaited(_push(wires, what: 'post ${item.id}'));
    return Posted.stored;
  }

  /// Likes a post, or takes the like back.
  Future<void> like(String postId, bool like) async {
    final wire = await _react(run, privHex, self, room, postId, like);
    final item = rebuildItem([wire]);
    if (item == null) return;
    store.admit(item);
    _changes.add(null);
    await _push([wire], what: '${like ? 'like' : 'unlike'} of $postId');
  }

  void mute(String callsign) {
    store.mute(callsign);
    _changes.add(null);
  }

  void hide(String postId) {
    store.hide(postId);
    _changes.add(null);
  }

  void markRead() {
    store.markRead();
    _changes.add(null);
  }

  Future<bool> _push(List<String> wires, {String what = 'wires'}) async {
    if (myB32 == null) return false;
    final t = now();
    final live = members.recent(t);
    final targets = MemberTable.sample(live, pushTo, rng);
    // One candidate too: how a listed member turns live.
    final cands = [
      for (final m in members.recent(t, within: const Duration(hours: 24), liveOnly: false))
        if (!m.live) m,
    ];
    targets.addAll(MemberTable.sample(cands, 1, rng));
    if (targets.isEmpty) return false;
    final frame = [await _identityWire(), ...wires].join('\n');
    final sent = await Future.wait([for (final m in targets) bearer.send(m.b32, frame)]);
    log?.call('room $room: pushed $what to ${[
      for (final (i, m) in targets.indexed) '${m.callsign}${sent[i] ? '' : ' (failed)'}'
    ].join(', ')}');
    return sent.any((s) => s);
  }

  Future<String> _identityWire() async {
    if (_identityLine == null || now() - _identityAt > 3600000) {
      _identityLine = await _identity(run, privHex, _nick);
      _identityAt = now();
    }
    return _identityLine!;
  }

  // ---- meeting ----

  Future<void> _greet({required int meeting, required int known}) async {
    if (myB32 == null) return;
    final hello = await _control('hello', {});
    final targets = <String>{
      ...(List.of(meetingPoints)..shuffle(rng)).take(meeting),
      for (final m in MemberTable.sample(
          members.recent(now(), within: const Duration(days: 14), liveOnly: false), known, rng))
        m.b32,
    };
    for (final b in targets) {
      unawaited(bearer.send(b, hello));
    }
  }

  Future<String> _control(String type, Map<String, Object?> extra) async =>
      jsonEncode({'v': 1, 'type': type, 'room': room, 'id': await _identityWire(), ...extra});

  Future<void> _onFrame(RoomFrame f) async {
    if (f.fromB32 == myB32) return; // our own greeting to a meeting address we answer for
    if (f.payload.startsWith('{')) return _onControl(f);
    final lines = f.payload.split('\n').where((l) => l.startsWith('t:')).take(600).toList();
    if (lines.isEmpty) return;
    final known = {for (final i in store.identities.values) i.callsign: i.keyHex};
    final checked = await _check(run, lines, known);
    for (final id in checked.identities) {
      store.putIdentity(id);
    }
    final t = now();
    if (checked.lead != null) members.heard(f.fromB32, checked.lead!, t);
    var oldest = 1 << 62;
    var stored = 0;
    final results = <XprsPacket>[];
    for (final (wire, verdict) in checked.lines) {
      if (verdict == 'bad') continue;
      final p = XprsPacket.parse(wire)!;
      final RoomItem? item;
      if (verdict == 'part') {
        item = await _part(p, wire);
      } else if ((p.type == 'message' || p.type == 'reaction') && (p['d'] ?? '').toUpperCase() == room) {
        item = RoomItem(p, [wire]);
      } else {
        item = null;
        if (p.type == 'command') {
          final ask = parseHistoryAsk(p, room);
          if (ask != null) unawaited(_serve(ask, f.fromB32));
        } else if (p.type == 'result' && (p['d'] ?? '').toUpperCase() == self) {
          results.add(p);
        }
      }
      if (item == null) continue;
      if (item.tsMs < oldest) oldest = item.tsMs;
      if (_take(item, f.fromB32)) stored++;
    }
    if (stored > 0) {
      log?.call('room $room: kept $stored new item(s) from ${checked.lead ?? '?'} at ${f.fromB32.substring(0, 8)}');
      _changes.add(null);
    }
    for (final r in results) {
      _onResult(r, oldest == 1 << 62 ? null : oldest, f.fromB32);
    }
  }

  Future<RoomItem?> _part(XprsPacket p, String wire) async {
    final key = '${p['f']}|${p['ts']}';
    final n = int.tryParse((p['n'] ?? '').split('/').first) ?? 0;
    (_partWires[key] ??= {})[n] = wire;
    final whole = _parts.offer(p, clear: p['m'] ?? '');
    if (whole == null) return null;
    final wires = _partWires.remove(key)!;
    final ordered = [for (final k in wires.keys.toList()..sort()) wires[k]!];
    final keyHex = store.identities[(p['f'] ?? '').toUpperCase()]?.keyHex;
    final sig = whole.sig;
    if (keyHex == null || sig == null) return null;
    final joined = whole.packet.with_('sig', sig);
    if (!await _verifyJoined(run, joined.encode(), keyHex)) {
      log?.call('room $room: a split post from ${p['f']} does not verify');
      return null;
    }
    if (_partWires.length > 64) _partWires.remove(_partWires.keys.first);
    return RoomItem(joined, ordered);
  }

  /// Keeps an item that arrived, and passes a fresh one on when the room is
  /// big enough to need relaying. True when it was new.
  bool _take(RoomItem item, String fromB32) {
    final t = now();
    final fresh = (t - item.tsMs).abs() < 10 * 60 * 1000;
    if (fresh && item.from != self) {
      final why = flood.check(item.from, reaction: item.isReaction, nowMs: t);
      if (why != null) {
        log?.call('room $room: dropped ${item.kind} from ${item.from}: $why');
        return false;
      }
    }
    final r = store.admit(item);
    if (r != Admit.stored) return false;
    if (fresh && item.from != self) unawaited(_relay(item, fromB32));
    return true;
  }

  Future<void> _relay(RoomItem item, String fromB32) async {
    final live = members.recent(now());
    if (live.length <= pushTo) return;
    final via = {for (final p in item.wires) ...xprsVia(XprsPacket.parse(p)!)};
    if (via.length >= 3 || via.contains(self)) return;
    final targets = MemberTable.sample(live, relayTo, rng, exclude: {fromB32, item.from, ...via});
    if (targets.isEmpty) return;
    final wires = [for (final w in item.wires) xprsAppendVia(XprsPacket.parse(w)!, self).encode()];
    final author = store.identities[item.from]?.wire;
    final frame = [await _identityWire(), ?author, ...wires].join('\n');
    for (final m in targets) {
      unawaited(bearer.send(m.b32, frame));
    }
  }

  Future<void> _onControl(RoomFrame f) async {
    Map<String, Object?> m;
    try {
      m = (jsonDecode(f.payload) as Map).cast<String, Object?>();
    } catch (_) {
      return;
    }
    if (m['room'] != room || m['v'] != 1) return;
    final id = m['id'] as String?;
    if (id == null) return;
    final checked = await _check(run, [id], const {});
    final who = checked.lead;
    if (who == null) return;
    store.putIdentity(checked.identities.first);
    final t = now();
    members.heard(f.fromB32, who, t);
    log?.call('room $room: ${m['type']} from $who at ${f.fromB32.substring(0, 8)}'
        '${f.toB32 != null && f.toB32 != myB32 ? ' (via meeting address ${f.toB32!.substring(0, 8)})' : ''}');
    switch (m['type']) {
      case 'hello':
        final list = [
          if (myB32 != null) {'b': myB32, 'c': self, 's': t ~/ 1000},
          for (final x in members.recent(t, within: const Duration(hours: 6)).take(30))
            if (x.b32 != f.fromB32) x.toJson(),
        ];
        unawaited(bearer.send(f.fromB32, await _control('members', {'members': list})));
      case 'members':
        for (final e in (m['members'] as List?) ?? const []) {
          if (e is Map) {
            final x = Member.fromJson(e.cast<String, Object?>());
            if (x != null && x.b32 != myB32 && x.b32 != f.fromB32) members.offer(x.b32, x.callsign, x.lastSeenMs);
          }
        }
        // Greet a few of those we have not heard ourselves: each that answers
        // turns live, and the room does not hang on one member.
        _greeted.removeWhere((_, at) => t - at > 10 * 60 * 1000);
        final fresh = [
          for (final x in members.recent(t, within: const Duration(hours: 6), liveOnly: false))
            if (!x.live && !_greeted.containsKey(x.b32)) x,
        ];
        final hello = await _control('hello', {});
        for (final x in MemberTable.sample(fresh, 3, rng)) {
          _greeted[x.b32] = t;
          unawaited(bearer.send(x.b32, hello));
        }
        if (!caughtUp && _pending == null) {
          _fetch ??= HistoryFetch.catchUp(t, keep: store.keep);
          unawaited(_askNext(f.fromB32));
        }
    }
    _changes.add(null);
  }

  // ---- history ----

  Future<void> _serve(HistoryAsk ask, String b32) async {
    final t = now();
    if (!budget.allow(ask.asker, t)) {
      final line = await _result(run, privHex, self, ask.asker, ask.askId, 429, 'try later');
      unawaited(bearer.send(b32, [await _identityWire(), line].join('\n')));
      return;
    }
    final page = planHistory(store, ask);
    log?.call('room $room: history for ${ask.asker}: ${page.items.length} item(s)${page.more ? ', more held' : ''}');
    final lines = await _reply(run, privHex, self, ask, page);
    unawaited(bearer.send(b32, [await _identityWire(), ...lines].join('\n')));
  }

  Future<void> _askNext(String b32) async {
    final w = _fetch?.next();
    if (w == null) {
      _fetch = null;
      _pending = null;
      caughtUp = true;
      _changes.add(null);
      return;
    }
    final wire = await _ask(run, privHex, self, room, w.$1, w.$2);
    log?.call('room $room: asking ${members[b32]?.callsign ?? b32.substring(0, 8)} for history');
    _pending = (b32: b32, askId: xprsIdentifier(XprsPacket.parse(wire)!), deadline: now() + askTimeout.inMilliseconds);
    unawaited(bearer.send(b32, [await _identityWire(), wire].join('\n')));
  }

  void _onResult(XprsPacket r, int? oldestMs, String fromB32) {
    final p = _pending;
    if (p == null || r['r'] != p.askId) return;
    final code = int.tryParse(r['code'] ?? '') ?? 0;
    if (code == 202) return; // the page follows (in this frame)
    log?.call('room $room: history answer $code from ${r['f']}');
    if (code == 429 || code == 403) {
      _retryElsewhere(fromB32);
      return;
    }
    _fetch?.answered(code, oldestMs);
    unawaited(_askNext(fromB32));
  }

  void _checkPending() {
    final p = _pending;
    if (p != null && now() > p.deadline) {
      log?.call('room $room: no history answer from ${members[p.b32]?.callsign ?? p.b32.substring(0, 8)}');
      _retryElsewhere(p.b32);
    }
  }

  void _retryElsewhere(String failed) {
    _triedForHistory.add(failed);
    _pending = null;
    final next = MemberTable.sample(members.recent(now()), 1, rng, exclude: _triedForHistory);
    if (next.isEmpty) {
      // Nobody else to ask now; the next gap fill tries again.
      _fetch = null;
      _triedForHistory.clear();
      return;
    }
    unawaited(_askNext(next.first.b32));
  }

  Future<void> _gapFill() async {
    if (myB32 == null || _pending != null) return;
    final live = members.recent(now());
    if (live.isEmpty) {
      unawaited(_greet(meeting: meetingPoints.length, known: 5));
      return;
    }
    final t = now();
    final newest = store.newestMs;
    _fetch = caughtUp && newest != null
        ? HistoryFetch.since(newest - 10 * 60 * 1000, t)
        : HistoryFetch.catchUp(t, keep: store.keep);
    await _askNext(MemberTable.sample(live, 1, rng).first.b32);
  }

  Future<void> _housekeeping() async {
    await store.prune();
    flood.sweep(now());
    await _saveMembers();
    _changes.add(null);
  }

  Future<void> _saveMembers() async {
    try {
      await Directory(store.dir).create(recursive: true);
      await File(_membersFile).writeAsString(jsonEncode(members.toJson()));
    } catch (_) {}
  }
}
