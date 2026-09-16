import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:xprs_room/xprs_room.dart';
import 'package:xprs_wire/xprs_wire.dart';

Future<R> inline<R>(R Function() f) async => f();

class _Net {
  final _boxes = <String, StreamController<RoomFrame>>{};
  final _meeting = <String, String>{};
  final rng = Random(3);
  _Bearer join(String b32) => _Bearer(this, b32, _boxes.putIfAbsent(b32, () => StreamController.broadcast()));
  Future<bool> deliver(String from, String to, String payload) async {
    final box = _boxes[_meeting[to] ?? to];
    if (box == null) return false;
    await Future<void>.delayed(Duration(milliseconds: 1 + rng.nextInt(5)));
    box.add(RoomFrame(from, to, payload));
    return true;
  }
}

class _Bearer implements RoomBearer {
  final _Net net;
  final String b32;
  final StreamController<RoomFrame> box;
  _Bearer(this.net, this.b32, this.box);
  @override
  Stream<RoomFrame> get frames => box.stream;
  @override
  Future<bool> send(String to, String payload) => net.deliver(b32, to, payload);
}

Future<void> eventually(bool Function() ok, {Duration within = const Duration(seconds: 15)}) async {
  final end = DateTime.now().add(within);
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('condition not met in $within');
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('modroom'));
  tearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('the admin grants a term, the moderator hides, mutes and holds posts, a larger payment takes over, '
      'and the room opens again when the term ends', () async {
    final net = _Net();
    final adminKey = NostrCrypto.generateKeyPair();
    var shift = 0; // days added to the clock
    int clock() => DateTime.now().millisecondsSinceEpoch + shift * 86400000;

    Future<RoomEngine> node(String b32, NostrKeyPair k) async {
      final e = RoomEngine(
        room: 'MONERO',
        store: RoomStore('${tmp.path}/$b32', 'MONERO', now: clock),
        bearer: net.join(b32),
        privHex: k.privateKeyHex,
        self: k.callsign,
        members: MemberTable(self: b32),
        run: inline,
        now: clock,
        pullEvery: const Duration(milliseconds: 500),
        askTimeout: const Duration(milliseconds: 900),
        admin: adminKey.callsign,
        adminKeyHex: adminKey.publicKeyHex,
      );
      await e.start();
      e.online(b32, ['slot.b32.i2p']);
      return e;
    }

    net._meeting['slot.b32.i2p'] = 'admin.b32.i2p';
    final admin = await node('admin.b32.i2p', adminKey);
    final alice = await node('alice.b32.i2p', NostrCrypto.generateKeyPair());
    final bob = await node('bob.b32.i2p', NostrCrypto.generateKeyPair());
    await eventually(() => admin.liveCount >= 2 && alice.liveCount >= 1 && bob.liveCount >= 1);

    // Alice buys the term.
    expect(await alice.moderate([('r', 'aaaaaa'), ('hide', 'message')]), Moderated.notAllowed);
    expect(await admin.grantTerm(alice.self, BigInt.from(1000)), Moderated.done);
    await eventually(() => [admin, alice, bob].every((e) => e.moderation.moderator == alice.self));
    expect(bob.moderation.toBeat, BigInt.from(1000));

    // She hides a post of Bob's for everyone.
    await bob.post('buy my coin');
    await eventually(() => admin.visiblePosts().any((p) => p.text == 'buy my coin'));
    final spam = admin.visiblePosts().firstWhere((p) => p.text == 'buy my coin');
    expect(await alice.moderate([('r', spam.id), ('hide', 'message')]), Moderated.done);
    await eventually(() => admin.visiblePosts().every((p) => p.id != spam.id));

    // She mutes Bob: his next post is not kept by anyone else.
    expect(
        await alice.moderate([('revoke', bob.self), ('until', xprsNowTs(clock() + 86400000))]), Moderated.done);
    await eventually(() => admin.moderation.muted.containsKey(bob.self));
    await bob.post('still here');
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(admin.visiblePosts().any((p) => p.text == 'still here'), isFalse);

    // Approval mode; a newcomer learns it all when joining.
    expect(await alice.moderate([('set', 'approval')]), Moderated.done);
    final carol = await node('carol.b32.i2p', NostrCrypto.generateKeyPair());
    await eventually(() => carol.moderation.moderator == alice.self && carol.moderation.approval);
    expect(carol.moderation.hidden, contains(spam.id));
    await carol.post('hello, first time here');
    await eventually(() => alice.heldPosts().any((p) => p.text == 'hello, first time here'));
    expect(admin.visiblePosts().any((p) => p.text == 'hello, first time here'), isFalse);
    expect(await alice.moderate([('grant', carol.self)]), Moderated.done);
    await eventually(() => admin.visiblePosts().any((p) => p.text == 'hello, first time here'));

    // Carol pays more: her term starts, Alice's mute and approval mode end.
    expect(await admin.grantTerm(carol.self, BigInt.from(2000)), Moderated.done);
    await eventually(() => [admin, alice, bob, carol].every((e) => e.moderation.moderator == carol.self));
    expect(admin.moderation.muted, isEmpty);
    expect(admin.moderation.approval, isFalse);
    expect(admin.moderation.hidden, contains(spam.id), reason: 'hides outlive the term');
    expect(await alice.moderate([('r', 'bbbbbb'), ('hide', 'message')]), Moderated.notAllowed);

    // Thirty days on with no larger payment: no moderator, nothing to beat.
    shift = 31;
    expect(admin.moderation.moderator, isNull);
    expect(bob.moderation.toBeat, BigInt.zero);

    for (final e in [admin, alice, bob, carol]) {
      await e.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('roster answers go only to the asker and stop at the bound', () async {
    final net = _Net();
    final adminKey = NostrCrypto.generateKeyPair();
    final engine = RoomEngine(
      room: 'MONERO',
      store: RoomStore('${tmp.path}/admin', 'MONERO'),
      bearer: net.join('admin.b32.i2p'),
      privHex: adminKey.privateKeyHex,
      self: adminKey.callsign,
      members: MemberTable(self: 'admin.b32.i2p'),
      run: inline,
      admin: adminKey.callsign,
      adminKeyHex: adminKey.publicKeyHex,
      rosterBudget: HistoryBudget(perAsker: 2, total: 10),
    );
    await engine.start();
    engine.online('admin.b32.i2p', const []);
    expect(await engine.grantTerm('X1MOD1', BigInt.from(10)), Moderated.done);

    // A member that keeps greeting: it is answered twice, then no more.
    final asker = NostrCrypto.generateKeyPair();
    final probe = net.join('probe.b32.i2p');
    final rosters = <RoomFrame>[];
    final other = net.join('other.b32.i2p');
    final strays = <RoomFrame>[];
    final subs = [
      probe.frames.listen((f) {
        if (f.payload.contains('t:moderate')) rosters.add(f);
      }),
      other.frames.listen(strays.add),
    ];
    final hello = jsonEncode({
      'v': 1,
      'type': 'hello',
      'room': 'MONERO',
      'id': signRoomIdentity(asker.privateKeyHex, 'probe'),
    });
    for (var i = 0; i < 4; i++) {
      await probe.send('admin.b32.i2p', hello);
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    expect(rosters, hasLength(2), reason: 'two answers allowed, the rest refused');
    expect(strays, isEmpty, reason: 'the roster is never broadcast');

    for (final s in subs) {
      await s.cancel();
    }
    await engine.close();
  }, timeout: const Timeout(Duration(minutes: 1)));
}
