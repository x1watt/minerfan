import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:xprs_room/xprs_room.dart';
import 'package:xprs_wire/xprs_wire.dart';

Future<R> inline<R>(R Function() f) async => f();

/// A station: key, callsign.
class Station {
  final NostrKeyPair k = NostrCrypto.generateKeyPair();
  String get priv => k.privateKeyHex;
  String get call => k.callsign;
  late final String idWire = signRoomIdentity(priv, 'n$call');
}

/// A post from [s] at [tsMs] (a past time, which signRoomPost cannot make).
List<String> postAt(Station s, String room, String text, int tsMs) {
  final head = XprsPacket.parse('t:message f:${s.call} d:$room ts:${xprsNowTs(tsMs)}')!;
  return [
    for (final p in xprsBuildDirect(head: head, text: text, private: false, signingKey: BigInt.parse(s.priv, radix: 16))
        .packets)
      p.encode()
  ];
}

/// An in-memory network: addresses, meeting addresses answered by members,
/// loss and delay.
class MemNet {
  final _boxes = <String, StreamController<RoomFrame>>{};
  final _meeting = <String, List<String>>{};
  final double loss;
  final Random rng;
  int sent = 0;
  MemNet({this.loss = 0, int seed = 1}) : rng = Random(seed);

  MemBearer join(String b32) => MemBearer(this, b32, _boxes.putIfAbsent(b32, () => StreamController.broadcast()));
  void answer(String meeting, String b32) => (_meeting[meeting] ??= []).add(b32);

  Future<bool> deliver(String from, String to, String payload) async {
    sent++;
    final targets = _meeting[to];
    final dest = targets != null && targets.isNotEmpty ? targets[rng.nextInt(targets.length)] : to;
    final box = _boxes[dest];
    if (box == null) return false;
    if (rng.nextDouble() < loss) return true; // taken, then lost
    await Future<void>.delayed(Duration(milliseconds: 1 + rng.nextInt(10)));
    box.add(RoomFrame(from, to, payload));
    return true;
  }
}

class MemBearer implements RoomBearer {
  final MemNet net;
  final String b32;
  final StreamController<RoomFrame> box;
  MemBearer(this.net, this.b32, this.box);
  @override
  Stream<RoomFrame> get frames => box.stream;
  @override
  Future<bool> send(String to, String payload) => net.deliver(b32, to, payload);
}

Future<void> eventually(bool Function() ok, {Duration within = const Duration(seconds: 20)}) async {
  final end = DateTime.now().add(within);
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('condition not met in $within');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('room'));
  tearDown(() async {
    // Stores write in the background; give the last writes a moment.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('room names and meeting addresses', () {
    expect(roomNameFor('Monero'), 'MONERO');
    expect(roomNameFor('Cryptoescudo'), 'CRYPTOESCUDO');
    expect(roomNameFor('X1AB'), isNull, reason: 'shaped like a callsign');
    final (e0, s0) = roomSlotSeeds('MONERO', 0);
    final (e1, _) = roomSlotSeeds('MONERO', 1);
    expect(e0, isNot(e1));
    expect(roomSlotSeeds('MONERO', 0).$2, s0);
  });

  group('store', () {
    test('keeps two weeks, dedupes by full hash, reloads, counts likes', () async {
      final a = Station(), b = Station();
      final now = DateTime.now().millisecondsSinceEpoch;
      final s = RoomStore('${tmp.path}/MONERO', 'MONERO');
      final fresh = rebuildItem(postAt(a, 'MONERO', 'hello miners', now - 3600000))!;
      final old = rebuildItem(postAt(a, 'MONERO', 'from last month', now - 20 * 86400000))!;
      final long = rebuildItem(postAt(b, 'MONERO', List.generate(70, (i) => 'w$i').join(' '), now - 7200000))!;
      expect(long.wires.length, greaterThan(1));
      expect(s.admit(fresh), Admit.stored);
      expect(s.admit(fresh), Admit.duplicate);
      expect(s.admit(old), Admit.tooOld);
      expect(s.admit(long), Admit.stored);
      final like = rebuildItem([signReaction(b.priv, b.call, 'MONERO', fresh.id, true)])!;
      expect(s.admit(like), Admit.stored);
      expect(s.likes(fresh.id), 1);
      s.putIdentity(identityFromWire(a.idWire)!);
      s.mute(b.call);
      await s.flush();

      final again = RoomStore('${tmp.path}/MONERO', 'MONERO');
      await again.load();
      expect(again.count, 3);
      expect(again.visiblePosts().map((p) => p.text), ['hello miners'], reason: 'b is muted');
      again.unmute(b.call);
      expect(again.visiblePosts().last.text, 'hello miners');
      expect(again.post(long.id)!.wires, long.wires, reason: 'parts kept as sent');
      expect(again.identities[a.call]!.nick, 'n${a.call}');
      expect(again.likes(fresh.id), 1);
      await again.flush();
    });

    test('prune drops what fell out of the window', () async {
      final a = Station();
      var clock = DateTime.now().millisecondsSinceEpoch;
      final s = RoomStore('${tmp.path}/R', 'MONERO', now: () => clock);
      s.admit(rebuildItem(postAt(a, 'MONERO', 'thirteen days ago', clock - 13 * 86400000))!);
      s.admit(rebuildItem(postAt(a, 'MONERO', 'today', clock))!);
      clock += 2 * 86400000;
      await s.prune();
      expect(s.visiblePosts().map((p) => p.text), ['today']);
    });
  });

  group('history', () {
    test('pages newest first, never split inside one second, 404 when empty', () {
      final a = Station(), asker = Station();
      final now = DateTime.now().millisecondsSinceEpoch;
      final s = RoomStore('${tmp.path}/H', 'MONERO');
      for (var i = 0; i < 120; i++) {
        s.admit(rebuildItem(postAt(a, 'MONERO', 'post $i', now - (i ~/ 3) * 60000))!);
      }
      s.putIdentity(identityFromWire(a.idWire)!);
      final ask = parseHistoryAsk(
          XprsPacket.parse(signHistoryAsk(asker.priv, asker.call, 'MONERO', now - 86400000, now + 60000))!, 'MONERO')!;
      final page = planHistory(s, ask);
      expect(page.more, isTrue);
      expect(page.items.length, 51, reason: 'three posts share each minute: the page ends after a whole group');
      expect(page.identityWires, [a.idWire]);
      final reply = buildHistoryReply(asker.priv, asker.call, ask, page);
      expect(reply.first, a.idWire);
      expect(XprsPacket.parse(reply[1])!['code'], '202');
      expect(XprsPacket.parse(reply.last)!['code'], '206');

      final empty = parseHistoryAsk(
          XprsPacket.parse(signHistoryAsk(asker.priv, asker.call, 'MONERO', now + 1000, now + 2000))!, 'MONERO')!;
      expect(XprsPacket.parse(buildHistoryReply(asker.priv, asker.call, empty, planHistory(s, empty)).single)!['code'],
          '404');
    });

    test('catch-up asks two seven-day windows and follows 206 until it stops moving', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final f = HistoryFetch.catchUp(now);
      final w1 = f.next()!;
      expect(w1.$2 - w1.$1, closeTo(7 * 86400000, 61000));
      f.answered(206, w1.$2 - 1000);
      expect(f.next()!.$2, w1.$2 - 1000);
      f.answered(206, w1.$2 - 1000); // did not move
      final w2 = f.next()!;
      expect(w2.$2, w1.$1);
      f.answered(200, null);
      expect(f.done, isTrue);
    });

    test('budget meters each asker', () {
      final b = HistoryBudget(perAsker: 2, total: 3);
      expect(b.allow('X1A', 0), isTrue);
      expect(b.allow('X1A', 1), isTrue);
      expect(b.allow('X1A', 2), isFalse);
      expect(b.allow('X1B', 3), isTrue);
      expect(b.allow('X1C', 4), isFalse);
      expect(b.allow('X1A', 3600001), isTrue);
    });
  });

  test('flood guard: per minute, per hour, new authors in a busy room', () {
    final g = FloodGuard(postsPerMinute: 3, postsPerHour: 5, busyRoomPerMinute: 4);
    const t = 1000000;
    expect([for (var i = 0; i < 4; i++) g.check('X1A', reaction: false, nowMs: t + i)], [null, null, null, isNotNull]);
    expect(g.check('X1A', reaction: false, nowMs: t + 61000), isNull);
    expect(g.check('X1A', reaction: false, nowMs: t + 62000), isNull);
    expect(g.check('X1A', reaction: false, nowMs: t + 63000), isNotNull, reason: 'five an hour');
    expect(g.check('X1NEW', reaction: false, nowMs: t + 63500), isNull, reason: 'the room took 2 this minute');
  });

  test('members: candidates turn live when heard', () {
    final m = MemberTable(self: 'me.b32.i2p');
    m.offer('x.b32.i2p', 'X1X', 1000);
    m.offer('me.b32.i2p', 'X1ME', 1000);
    expect(m.recent(2000), isEmpty);
    expect(m.recent(2000, liveOnly: false).single.callsign, 'X1X');
    m.heard('x.b32.i2p', 'X1X', 1500);
    expect(m.recent(2000).single.live, isTrue);
  });

  group('engine', () {
    Future<(RoomEngine, Station)> node(MemNet net, String b32, String dir,
        {Duration pull = const Duration(milliseconds: 400)}) async {
      final s = Station();
      final e = RoomEngine(
          room: 'MONERO',
          store: RoomStore('$dir/$b32', 'MONERO'),
          bearer: net.join(b32),
          privHex: s.priv,
          self: s.call,
          members: MemberTable(self: b32),
          budget: HistoryBudget(perAsker: 100000, total: 100000),
          run: inline,
          pullEvery: pull,
          askTimeout: const Duration(milliseconds: 900));
      await e.start();
      return (e, s);
    }

    test('meet, post, reply, like and a long post', () async {
      final net = MemNet();
      final (a, _) = await node(net, 'a.b32.i2p', tmp.path);
      final (b, _) = await node(net, 'b.b32.i2p', tmp.path);
      net.answer('slot0.b32.i2p', 'a.b32.i2p');
      a.online('a.b32.i2p', ['slot0.b32.i2p']);
      b.online('b.b32.i2p', ['slot0.b32.i2p']);
      await eventually(() => b.liveCount == 1 && a.liveCount == 1);
      await a.post('who mines on a phone?');
      await eventually(() => b.store.visiblePosts().isNotEmpty);
      final first = b.store.visiblePosts().single;
      await b.post('me, at 2.5 kH/s', replyTo: first);
      await eventually(() => a.store.visiblePosts().length == 2);
      expect(a.store.visiblePosts().last.replyTo, first.id);
      await b.like(first.id, true);
      await eventually(() => a.store.likes(first.id) == 1);
      final long = List.generate(80, (i) => 'word$i').join(' ');
      expect(await a.post(long), Posted.stored);
      // Nine parts at most (section 6.6): about a thousand characters.
      expect(await a.post(List.generate(200, (i) => 'word$i').join(' ')), Posted.tooLong);
      await eventually(() => b.store.visiblePosts().any((p) => p.text == long));
      expect(b.store.identities[a.self], isNotNull);
      await a.close();
      await b.close();
    });

    test('a newcomer catches up on exactly the last two weeks', () async {
      final net = MemNet();
      final (a, sa) = await node(net, 'a.b32.i2p', tmp.path);
      final now = DateTime.now().millisecondsSinceEpoch;
      var inWindow = 0;
      for (var d = 0; d < 20; d++) {
        for (var k = 0; k < 6; k++) {
          final ts = now - d * 86400000 - k * 3600000 - 60000;
          if (a.store.admit(rebuildItem(postAt(sa, 'MONERO', 'day $d post $k', ts))!) == Admit.stored) inWindow++;
        }
      }
      a.store.putIdentity(identityFromWire(sa.idWire)!);
      expect(inWindow, lessThan(120));
      net.answer('slot0.b32.i2p', 'a.b32.i2p');
      a.online('a.b32.i2p', ['slot0.b32.i2p']);
      final (c, _) = await node(net, 'c.b32.i2p', tmp.path);
      c.online('c.b32.i2p', ['slot0.b32.i2p']);
      await eventually(() => c.caughtUp, within: const Duration(seconds: 30));
      expect(c.store.visiblePosts().length, inWindow);
      await a.close();
      await c.close();
    });

    test('eight members with 20% loss all end with every post; a muted author is not passed on', timeout: const Timeout(Duration(minutes: 2)), () async {
      final net = MemNet(loss: 0.2, seed: 7);
      final nodes = <RoomEngine>[];
      for (var i = 0; i < 8; i++) {
        final (e, _) = await node(net, 'n$i.b32.i2p', tmp.path);
        nodes.add(e);
      }
      net.answer('slot0.b32.i2p', 'n0.b32.i2p');
      for (final (i, e) in nodes.indexed) {
        e.online('n$i.b32.i2p', ['slot0.b32.i2p']);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await eventually(() => nodes.every((e) => e.liveCount >= 1), within: const Duration(seconds: 30));
      print('live: ${[for (final e in nodes) e.liveCount]}');
      for (final (i, e) in nodes.indexed) {
        await e.post('hello from node $i');
      }
      final t0 = DateTime.now();
      try {
        await eventually(() => nodes.every((e) => e.store.visiblePosts().length == 8), within: const Duration(seconds: 60));
      } finally {
        print('posts: ${[for (final e in nodes) e.store.visiblePosts().length]} after ${DateTime.now().difference(t0)}, '
            '${net.sent} frames');
      }

      // Node 7 is muted by everybody else: its next post goes nowhere.
      final seven = nodes[7].self;
      for (final e in nodes.take(7)) {
        e.mute(seven);
      }
      await nodes[7].post('buy my coin');
      await Future<void>.delayed(const Duration(seconds: 3));
      for (final e in nodes.take(7)) {
        expect(e.store.visiblePosts().any((p) => p.text == 'buy my coin'), isFalse);
      }
      for (final e in nodes) {
        await e.close();
      }
    });
  });
}
