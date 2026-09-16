import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:minerfan/app_controller.dart';

void main() {
  test('the close button setting is kept and read back', () {
    final s = AppSettings(closeAction: CloseAction.quit);
    final back = AppSettings.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, Object?>);
    expect(back.closeAction, CloseAction.quit);
  });

  test('settings written before the close button setting existed ask', () {
    final old = AppSettings().toJson()..remove('closeAction');
    expect(AppSettings.fromJson(old).closeAction, CloseAction.ask);
  });
}
