// Live check of the coin rooms over the public I2P network, with the app's
// own classes (PrivateNetwork, ContactBook, RoomService): three stations on
// this machine, each with its own data folder.
//
//   ROOM_PROBE=<folder> flutter test test/live/room_probe_test.dart
//
// a and b join MONERO and find each other through the room's meeting
// addresses; a posts a short and a long message, b replies and likes; a
// fresh c finds the room, catches up on the history, then posts live to a
// and b; b mutes c, and c's next post reaches a but not b's chat.
// Skipped unless ROOM_PROBE is set: it takes minutes and needs the internet.

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minerfan/contacts/contact_book.dart';
import 'package:minerfan/network/private_network.dart';
import 'package:minerfan/network/rooms.dart';
import 'package:xprs_room/xprs_room.dart';

final _sw = Stopwatch()..start();
String _t() => '${(_sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s';

class _Station {
  final String name;
  final String dir;
  late final PrivateNetwork net = PrivateNetwork(dir);
  late final ContactBook contacts = ContactBook(dir);
  late final RoomService rooms = RoomService(
    dataDir: dir,
    net: net,
    contacts: contacts,
    joined: () => {'MONERO'},
    coins: [('monero', 'Monero')],
  );
  int _printed = 0;
  _Station(this.name, this.dir) {
    net.addListener(() {
      // The network log, only the lines about rooms and coming up.
      final l = net.log;
      final from = _printed > l.length ? 0 : _printed;
      for (final line in l.skip(from)) {
        if (line.contains('room') || line.contains('shared') || line.contains('up with') || line.contains('failed')) print('${_t()} [$name] $line');
      }
      _printed = l.length;
    });
  }

  ChatRoom get room => rooms.rooms.single;
  RoomEngine get e => room.engine!;

  Future<void> up() async {
    await contacts.load();
    contacts.myName = name;
    await rooms.start();
    await net.start();
    if (net.state != PrivateNetworkState.up) throw StateError('$name: the network did not come up');
    print('${_t()} [$name] ${e.self} at ${net.address}');
  }

  String? idOf(String text) => e.store.visiblePosts().where((i) => i.text == text).firstOrNull?.id;
  bool has(String id) => e.store.post(id) != null;
}

Future<bool> _until(String what, bool Function() ok, Duration max) async {
  final end = DateTime.now().add(max);
  while (DateTime.now().isBefore(end)) {
    if (ok()) {
      print('${_t()} ok: $what');
      return true;
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  print('${_t()} TIMEOUT: $what');
  return false;
}

void main() {
  final root = Platform.environment['ROOM_PROBE'];
  test('coin room over I2P', () async {
    final results = <String, bool>{};
    void check(String what, bool ok) => results[what] = ok;

    // a and b keep their keys and routers between runs; rooms start empty,
    // and c is new every time.
    for (final n in ['a', 'b', 'c']) {
      final rooms = Directory('$root/$n/rooms');
      if (rooms.existsSync()) rooms.deleteSync(recursive: true);
    }
    final cDir = Directory('$root/c');
    if (cDir.existsSync()) cDir.deleteSync(recursive: true);

    final a = _Station('a', '$root/a'), b = _Station('b', '$root/b');
    await Future.wait([a.up(), b.up()]);
    check(
        'a and b meet',
        await _until('a and b see each other', () => a.e.liveCount >= 1 && b.e.liveCount >= 1,
            const Duration(minutes: 6)));

    const short = 'hello from a: anyone else on P2Pool mini?';
    final long = List.generate(90, (i) => 'word$i').join(' ');
    await a.e.post(short);
    await a.e.post(long);
    final shortId = a.idOf(short)!, longId = a.idOf(long)!;
    check('b gets the short post', await _until('b has the short post', () => b.has(shortId), const Duration(minutes: 3)));
    check('b gets the long post (parts)',
        await _until('b has the long post', () => b.has(longId), const Duration(minutes: 3)));

    const reply = 'b here, 3 shares today';
    await b.e.post(reply, replyTo: b.e.store.post(shortId));
    await b.e.like(shortId, true);
    final replyId = b.idOf(reply)!;
    check('a gets the reply', await _until('a has the reply', () => a.has(replyId), const Duration(minutes: 3)));
    check('the reply names its post', a.e.store.post(replyId)?.replyTo == shortId);
    check('a sees the like', await _until('a counts the like', () => a.e.store.likes(shortId) == 1, const Duration(minutes: 3)));
    check('the nick came along', a.e.store.identities[b.e.self]?.nick == 'b');

    final c = _Station('c', '$root/c');
    await c.up();
    check(
        'c catches up on the history',
        await _until('c has the three posts and the like',
            () => c.has(shortId) && c.has(longId) && c.has(replyId) && c.e.store.likes(shortId) == 1,
            const Duration(minutes: 8)));

    const hi = 'hi from c';
    await c.e.post(hi);
    final hiId = c.idOf(hi)!;
    check('a and b get c live',
        await _until('a and b have c\'s post', () => a.has(hiId) && b.has(hiId), const Duration(minutes: 3)));

    b.e.mute(c.e.self);
    const second = 'second from c';
    await c.e.post(second);
    final secondId = c.idOf(second)!;
    check('a gets c after b muted c', await _until('a has c\'s second post', () => a.has(secondId), const Duration(minutes: 3)));
    await Future<void>.delayed(const Duration(seconds: 20));
    check('b keeps nothing from c once muted', !b.has(secondId) && !b.e.store.visiblePosts().any((i) => i.from == c.e.self));

    print('\n${_t()} results:');
    results.forEach((k, v) => print('  ${v ? 'ok  ' : 'FAIL'} $k'));
    for (final s in [a, b, c]) {
      await s.rooms.close();
      s.net.stop();
    }
    expect(results.values.every((v) => v), isTrue);
  }, skip: root == null ? 'set ROOM_PROBE=<folder> to run' : false, timeout: const Timeout(Duration(minutes: 30)));
}
