import 'package:test/test.dart';
import 'package:xprs_room/xprs_room.dart';
import 'package:xprs_wire/xprs_wire.dart';

class _Who {
  final String priv;
  final String call;
  _Who._(this.priv, this.call);
  factory _Who() {
    final k = NostrCrypto.generateKeyPair();
    return _Who._(k.privateKeyHex, 'X1${NostrCrypto.deriveCallsign(k.publicKeyHex)}');
  }
}

const room = 'MONERO';
const day = 24 * 3600 * 1000;
final t0 = DateTime.utc(2026, 9, 1).millisecondsSinceEpoch;

ModAct act(_Who by, int at, List<(String, String)> fields, {String? text}) {
  final wire = signModAct(by.priv, by.call, room, fields, text: text, tsMs: at);
  expect(wire, isNotEmpty);
  return parseModeration(XprsPacket.parse(wire)!, wire, room)!;
}

ModAct term(_Who admin, _Who buyer, int at, int paid) => act(admin, at, [
      ('grant', buyer.call),
      ('role', 'mod'),
      ('until', xprsNowTs(at + 30 * day)),
      ('paid', '$paid'),
    ]);

void main() {
  final admin = _Who(), alice = _Who(), bob = _Who(), eve = _Who();
  ModerationState at(List<ModAct> acts, int ms) => ModerationState.replay(acts, admin.call, ms);

  test('a bought term lasts 30 days, then the room is open and the price drops to zero', () {
    final acts = [term(admin, alice, t0, 1000)];
    var s = at(acts, t0 + 29 * day);
    expect(s.moderator, alice.call);
    expect(s.toBeat, BigInt.from(1000));
    s = at(acts, t0 + 30 * day + 1);
    expect(s.moderator, isNull);
    expect(s.toBeat, BigInt.zero);
  });

  test('a larger payment takes over and restarts the 30 days', () {
    final acts = [term(admin, alice, t0, 1000), term(admin, bob, t0 + 20 * day, 2000)];
    expect(at(acts, t0 + 25 * day).moderator, bob.call);
    expect(at(acts, t0 + 45 * day).moderator, bob.call, reason: 'bob\'s term runs 30 days from his grant');
    expect(at(acts, t0 + 51 * day).moderator, isNull);
  });

  test('only the admin grants; a term cannot be longer than 30 days', () {
    final forged = act(eve, t0, [('grant', eve.call), ('role', 'mod'), ('until', xprsNowTs(t0 + 30 * day)), ('paid', '9')]);
    expect(at([forged], t0 + day).moderator, isNull);
    final long = act(admin, t0, [('grant', alice.call), ('role', 'mod'), ('until', xprsNowTs(t0 + 90 * day)), ('paid', '1')]);
    expect(at([long], t0 + 31 * day).moderator, isNull);
  });

  test('moderator acts count only inside the signer\'s term', () {
    final grant = term(admin, alice, t0 + day, 1000);
    final early = act(alice, t0, [('r', 'aaaaaa'), ('hide', 'message')]);
    final inside = act(alice, t0 + 2 * day, [('r', 'bbbbbb'), ('hide', 'message')]);
    final stranger = act(eve, t0 + 2 * day, [('r', 'cccccc'), ('hide', 'message')]);
    final s = at([grant, early, inside, stranger], t0 + 3 * day);
    expect(s.hidden, {'bbbbbb'});
  });

  test('mutes, approval, topic and pin end with the term; hides stay', () {
    final acts = [
      term(admin, alice, t0, 1000),
      act(alice, t0 + day, [('r', 'bbbbbb'), ('hide', 'message')]),
      act(alice, t0 + day, [('revoke', eve.call), ('until', xprsNowTs(t0 + 60 * day))]),
      act(alice, t0 + day, [('set', 'approval')]),
      act(alice, t0 + day, [('r', 'dddddd'), ('pin', 'message')]),
      act(alice, t0 + day, [('set', 'topic')], text: 'Share your hashrates here'),
    ];
    var s = at(acts, t0 + 2 * day);
    expect(s.muted.keys, [eve.call]);
    expect(s.approval, isTrue);
    expect(s.topic, 'Share your hashrates here');
    expect(s.pinned, 'dddddd');
    expect(s.held(bob.call, t0 + 2 * day), isTrue);
    expect(s.shows(eve.call, 'eeeeee', t0 + 2 * day), isFalse);
    // Expiry: everything but the hide is gone.
    s = at(acts, t0 + 31 * day);
    expect(s.muted, isEmpty);
    expect(s.approval, isFalse);
    expect(s.topic, isNull);
    expect(s.pinned, isNull);
    expect(s.hidden, {'bbbbbb'});
    // Takeover: the new moderator's room starts open too.
    final taken = [...acts, term(admin, bob, t0 + 5 * day, 2000)];
    s = at(taken, t0 + 6 * day);
    expect(s.moderator, bob.call);
    expect(s.muted, isEmpty);
    expect(s.approval, isFalse);
    expect(s.hidden, {'bbbbbb'});
  });

  test('approving lets a callsign post in approval mode and lifts its mute', () {
    final acts = [
      term(admin, alice, t0, 1000),
      act(alice, t0 + day, [('set', 'approval')]),
      act(alice, t0 + day, [('revoke', bob.call), ('until', xprsNowTs(t0 + 10 * day))]),
      act(alice, t0 + 2 * day, [('grant', bob.call)]),
    ];
    final s = at(acts, t0 + 3 * day);
    expect(s.muted, isEmpty);
    expect(s.held(bob.call, t0 + 3 * day), isFalse);
    expect(s.held(eve.call, t0 + 3 * day), isTrue);
    expect(s.mutedAt(bob.call, t0 + day + 1000), isTrue, reason: 'what he wrote while muted stays muted');
  });

  test('an old act sent again changes nothing', () {
    final aliceTerm = term(admin, alice, t0, 1000);
    final aliceMute = act(alice, t0 + day, [('revoke', eve.call), ('until', xprsNowTs(t0 + 20 * day))]);
    final bobTerm = term(admin, bob, t0 + 10 * day, 2000);
    final acts = [aliceTerm, aliceMute, bobTerm];
    final s = at(acts, t0 + 15 * day);
    expect(s.moderator, bob.call);
    expect(s.muted, isEmpty);

    // The same wires again, whoever relays them: authority is read at each
    // act's ts:, so the picture at t0 + 15 days is the same one.
    final replayed = at([...acts, aliceTerm, aliceMute, bobTerm, aliceTerm], t0 + 15 * day);
    expect(replayed.moderator, bob.call);
    expect(replayed.toBeat, s.toBeat);
    expect(replayed.muted, isEmpty);
    expect(replayed.term!.startMs, s.term!.startMs);
    expect(replayed.term!.endMs, s.term!.endMs);
  });

  test('the admin can end a term; acts from the future are ignored', () {
    final acts = [term(admin, alice, t0, 1000), act(admin, t0 + 3 * day, [('revoke', alice.call)])];
    expect(at(acts, t0 + 4 * day).moderator, isNull);
    final future = [term(admin, bob, t0 + 10 * day, 5)];
    expect(at(future, t0 + day).moderator, isNull);
  });
}
