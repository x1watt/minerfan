import 'package:flutter_test/flutter_test.dart';
import 'package:minerfan/moderation/config.dart';

void main() {
  test('the built-in rooms admin is X1WATT', () {
    expect(ModerationConfig.adminKeyHex, isNotNull);
    expect(ModerationConfig.adminCallsign, 'X1WATT');
  });

  test('a room has no moderation until its address is set', () {
    for (final coin in ['monero', 'cryptoescudo']) {
      expect(ModerationConfig.on(coin), ModerationConfig.address(coin) != null,
          reason: 'moderation needs both the admin and the address');
    }
  });
}
