// End-to-end check of XPRS over I2P between two stations on this machine,
// over the public I2P network, with the app's own classes (NetworkKeys,
// XprsI2pLink): each station keeps its keys, callsign and address in its own
// folder, like the app's data folder.
//
//   dart run tool/xprs_i2p_probe.dart [folder]
//
// Checks: a sealed direct message arrives, opens, and its signed receipt
// comes back; a long message arrives in parts and is rejoined; a packet
// whose sealed body was changed is dropped (the signature fails); the same
// packet sent twice is delivered once.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:i2p/i2p.dart';
import 'package:minerfan/network/network_keys.dart';
import 'package:minerfan/network/xprs_i2p.dart';
import 'package:xprs_wire/xprs_wire.dart';

Future<void> main(List<String> args) async {
  final dir = args.isNotEmpty ? args.first : 'xprs-i2p-probe';
  final sw = Stopwatch()..start();
  String t() => '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s';
  final results = <String, bool>{};

  ({I2pService service, NetworkKeys keys}) station(String name) {
    final d = Directory('$dir/$name')..createSync(recursive: true);
    final keys = NetworkKeys.loadOrCreate(d.path);
    for (final n in keys.notes) {
      print('${t()} [$name] $n');
    }
    final s = I2pService(
        identity: keys.i2pIdentity,
        stateDir: '${d.path}/i2p/state',
        log: (m) {
          if (m.contains('up with') || m.contains('from cache') || m.contains('saved identity')) print('${t()} [$name] $m');
        });
    return (service: s, keys: keys);
  }

  final a = station('a'), b = station('b');
  print('${t()} a is ${a.keys.station.callsign}, b is ${b.keys.station.callsign}');
  final ups = await Future.wait([a.service.ensureStarted(), b.service.ensureStarted()]);
  if (!ups.every((u) => u)) {
    print('${t()} a node did not come up');
    exit(1);
  }
  final aB32 = a.service.b32!, bB32 = b.service.b32!;
  print('${t()} up: a $aB32, b $bB32');

  final logs = <String>[];
  final la = XprsI2pLink(a.service.messages, a.service.send, a.keys.station, log: (l) => print('${t()} [a] $l'));
  final lb = XprsI2pLink(b.service.messages, b.service.send, b.keys.station, log: (l) {
    logs.add(l);
    print('${t()} [b] $l');
  });
  // Contacts both ways, as a messaging screen would after a contact card.
  la.addContact(b.keys.station.npub, b32: bB32);
  lb.addContact(a.keys.station.npub, b32: aB32);

  final inbox = <XprsInbound>[];
  lb.received.listen((m) {
    inbox.add(m);
    print('${t()} [b] got ${m.packet.type} from ${m.from} ${m.sealed ? "sealed" : "plain"}: '
        '"${m.text?.substring(0, m.text!.length.clamp(0, 60))}"');
  });
  final receipts = <String>{};
  la.receipts.listen((r) {
    receipts.add(r.id);
    print('${t()} [a] receipt ${r.state} for ${r.id} from ${r.from}');
  });

  Future<bool> until(bool Function() ok, Duration d) async {
    final end = DateTime.now().add(d);
    while (!ok() && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return ok();
  }

  await Future<void>.delayed(const Duration(seconds: 10)); // lease sets settle

  // 1. A sealed direct message and its receipt (resent until it arrives:
  // I2P is best effort; the copies share an identifier, so b keeps one).
  const hello = 'hello from a over I2P, sealed to b';
  final ids = <String>{}; // each try is a new packet with its own identifier
  for (var i = 0; i < 5 && !inbox.any((m) => m.text == hello); i++) {
    final r = await la.sendDirect(bB32, b.keys.station.npub, hello);
    final id = xprsIdentifier(r.body.identityPacket!);
    ids.add(id);
    print('${t()} sent the message ($id), try ${i + 1}: ${r.sent}');
    await until(() => inbox.any((m) => m.text == hello), const Duration(seconds: 20));
  }
  results['sealed message arrives and opens'] = inbox.any((m) => m.text == hello && m.sealed);
  results['signed receipt comes back'] = await until(() => receipts.any(ids.contains), const Duration(seconds: 60));

  // 2. A long message: parts, each sealed and signed, rejoined by b.
  final long = List.generate(60, (i) => 'word$i').join(' ');
  final before = inbox.length;
  for (var i = 0; i < 5 && !inbox.skip(before).any((m) => m.text == long); i++) {
    final r = await la.sendDirect(bB32, b.keys.station.npub, long);
    print('${t()} sent the long message in ${r.body.packets.length} parts, try ${i + 1}: ${r.sent}');
    await until(() => inbox.skip(before).any((m) => m.text == long), const Duration(seconds: 25));
  }
  results['long message rejoined from parts'] = inbox.skip(before).any((m) => m.text == long);

  // 3. A changed sealed body: signed by a, then one character of x: changed.
  final head = XprsPacket.parse('t:message f:${a.keys.station.callsign} d:${b.keys.station.callsign} '
      'ts:${xprsNow()}')!;
  final built = xprsBuildDirect(
      head: head,
      text: 'this one was changed on the way',
      private: true,
      recipientKeyHex: b.keys.station.publicKeyHex,
      signingKey: a.keys.station.scalar);
  final p = built.packets.single;
  final x = p['x']!;
  final changed = p.with_('x', '${x[0] == 'A' ? 'B' : 'A'}${x.substring(1)}');
  final changedId = xprsIdentifier(changed);
  for (var i = 0; i < 4 && !logs.any((l) => l.contains(changedId)); i++) {
    await la.send(bB32, [changed.encode()]);
    await until(() => logs.any((l) => l.contains(changedId)), const Duration(seconds: 20));
  }
  results['changed packet dropped as forged'] =
      logs.any((l) => l.contains(changedId) && l.contains('forged')) &&
          !inbox.any((m) => m.text?.contains('changed on the way') ?? false);

  // 4. The same signed packet twice (two I2P frames): delivered once.
  final again = xprsBuildDirect(
          head: XprsPacket.parse('t:message f:${a.keys.station.callsign} d:${b.keys.station.callsign} '
              'ts:${xprsNow()}')!,
          text: 'only once please',
          private: true,
          recipientKeyHex: b.keys.station.publicKeyHex,
          signingKey: a.keys.station.scalar)
      .packets
      .single
      .encode();
  for (var i = 0; i < 4 && !inbox.any((m) => m.text == 'only once please'); i++) {
    await la.send(bB32, [again]);
    await until(() => inbox.any((m) => m.text == 'only once please'), const Duration(seconds: 20));
  }
  await la.send(bB32, [again]);
  await la.send(bB32, [again]);
  await Future<void>.delayed(const Duration(seconds: 20));
  final copies = inbox.where((m) => m.text == 'only once please').length;
  results['repeated packet delivered once (got $copies)'] = copies == 1;

  la.close();
  lb.close();
  a.service.stop();
  b.service.stop();
  print('\n${t()} results');
  results.forEach((k, v) => print('  ${v ? "ok  " : "FAIL"} $k'));
  print(jsonEncode({'a': a.keys.station.callsign, 'b': b.keys.station.callsign}));
  exit(results.values.every((v) => v) ? 0 : 1);
}
