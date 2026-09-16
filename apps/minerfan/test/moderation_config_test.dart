import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minerfan/moderation/config.dart';

void main() {
  tearDown(ModerationConfig.resetToBuiltIn);

  test('the built-in rooms admin is X1WATT and both coins have an address', () {
    expect(ModerationConfig.adminKeyHex, isNotNull);
    expect(ModerationConfig.adminCallsign, 'X1WATT');
    for (final coin in ['monero', 'cryptoescudo']) {
      expect(ModerationConfig.address(coin), isNotNull, reason: '$coin has a room address');
      expect(ModerationConfig.on(coin), isTrue);
    }
  });

  test('a profile file wins over what the app was built with', () async {
    final tmp = await Directory.systemTemp.createTemp('rooms');
    addTearDown(() async => tmp.delete(recursive: true));
    final f = File('${tmp.path}/rooms.json');
    await f.writeAsString(jsonEncode({
      'adminNpub': 'npub14fakyw526kl03mhxfnqwhla5avd32t2ccnqj7l0gkkg2a53qsmss7hjqev',
      'addresses': {'cryptoescudo': 'CtestAddressFromTheProfileFile1234'},
    }));
    await ModerationConfig.loadProfile(path: f.path);
    expect(ModerationConfig.adminCallsign, 'X14FAK');
    expect(ModerationConfig.address('cryptoescudo'), 'CtestAddressFromTheProfileFile1234');
    // What the file leaves out stays as built in.
    expect(ModerationConfig.address('monero'), ModerationConfig.builtInAddresses['monero']);
  });

  test('a first start writes the settings to the profile', () async {
    final tmp = await Directory.systemTemp.createTemp('rooms');
    addTearDown(() async => tmp.delete(recursive: true));
    final path = '${tmp.path}/sub/rooms.json';
    await ModerationConfig.loadProfile(path: path);
    final m = jsonDecode(await File(path).readAsString()) as Map<String, Object?>;
    expect(m['adminNpub'], ModerationConfig.builtInAdminNpub);
    expect((m['addresses']! as Map)['cryptoescudo'], ModerationConfig.builtInAddresses['cryptoescudo']);
  });
}
