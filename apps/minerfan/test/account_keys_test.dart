import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minerfan/network/network_keys.dart';
import 'package:minerfan/ui/account_keys.dart';
import 'package:xprs_wire/xprs_wire.dart' show NostrCrypto;

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('account'));
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('an nsec and the bare hex read as the same key', () {
    final k = NostrCrypto.generateKeyPair();
    expect(accountKeyHex(' ${k.nsec} '), k.privateKeyHex.toLowerCase());
    expect(accountKeyHex(k.privateKeyHex.toUpperCase()), k.privateKeyHex.toLowerCase());
    expect(accountKeyHex('npub1${'q' * 20}'), isNull);
    expect(accountKeyHex('not a key'), isNull);
    expect(accountKeyHex('${k.privateKeyHex}ab'), isNull);
  });

  test('an imported account signs under its own callsign and keeps the old key aside', () {
    final first = NetworkKeys.loadOrCreate(tmp.path).station;
    final k = NostrCrypto.generateKeyPair();
    final station = NetworkKeys.importStation(tmp.path, accountKeyHex(k.nsec)!);
    expect(station.callsign, k.callsign);
    expect(station.nsec, k.nsec);

    // The key on disk is the imported one, and the old file is still there.
    final again = NetworkKeys.loadOrCreate(tmp.path).station;
    expect(again.callsign, k.callsign);
    expect(again.privateKeyHex, k.privateKeyHex.toLowerCase());
    final aside = Directory('${tmp.path}/xprs')
        .listSync()
        .where((f) => f.path.contains('identity.key.replaced-'))
        .toList();
    expect(aside, hasLength(1), reason: 'the account that was here stays on disk');
    expect(first.callsign, isNot(k.callsign));
  });

  test('a key that is not 64 hex characters is refused', () {
    expect(() => NetworkKeys.importStation(tmp.path, 'zz'), throwsFormatException);
  });
}
