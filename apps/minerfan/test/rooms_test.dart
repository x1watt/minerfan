import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minerfan/network/rooms.dart';
import 'package:minerfan/ui/chat/chat_view.dart';

void main() {
  test('frames reach the rooms they name', () {
    expect(roomNamesIn('{"v":1,"type":"hello","room":"MONERO","id":"t:identity f:X1ABC"}'), {'MONERO'});
    expect(roomNamesIn('{"v":1,"type":"hello"}'), isEmpty);
    expect(
      roomNamesIn('t:identity f:X1AAAA ts:x k:npub1\n'
          't:message f:X1AAAA d:MONERO ts:x sig:y m:hello\n'
          't:command f:X1AAAA d:CRYPTOESCUDO ts:x cmd:history only:CRYPTOESCUDO'),
      {'MONERO', 'CRYPTOESCUDO'},
    );
    // A bare result names a station, not a room we are in.
    expect(roomNamesIn('t:result f:X1BBBB d:X1AAAA ts:x r:abc123 code:404'), {'X1AAAA'});
    // Only the fields: text inside m: after a space would match, harmlessly.
    expect(roomNamesIn('not xprs d:MONERO'), isEmpty);
  });

  testWidgets('chat view: bubbles, days, replies, likes and the menu', (tester) async {
    final now = DateTime.now();
    final msgs = [
      ChatMessage(
          id: 'aaaaaa',
          callsign: 'X1ALIC',
          name: 'alice',
          text: 'Anyone on P2Pool mini?',
          time: now.subtract(const Duration(days: 1))),
      ChatMessage(id: 'bbbbbb', callsign: 'X1BOBB', text: 'Yes, 3 shares today', parent: 'aaaaaa', time: now, likes: 2),
      ChatMessage(id: 'cccccc', callsign: 'X1MEEE', text: 'Same here', outgoing: true, time: now),
    ];
    final sent = <(String, String?)>[];
    final liked = <(String, bool)>[];
    final hidden = <String>[];
    final muted = <String>[];
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: ChatView(
          messages: msgs,
          onSend: (text, to) async {
            sent.add((text, to?.id));
            return true;
          },
          onLike: (m, like) => liked.add((m.id, like)),
          onHide: (m) => hidden.add(m.id),
          onMute: (m) => muted.add(m.callsign),
          onAddContact: (_) {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('alice'), findsWidgets);
    expect(find.text('X1ALIC'), findsWidgets);
    // The reply quotes what it answers, and the first post counts its reply.
    expect(find.textContaining('alice: Anyone on P2Pool'), findsOneWidget);
    expect(find.text('1 reply'), findsOneWidget);

    // Like someone else's post.
    await tester.tap(find.byIcon(Icons.favorite_border).first);
    expect(liked, [('aaaaaa', true)]);

    // Reply to bob, then send.
    await tester.tap(find.text('Reply').at(1));
    await tester.pump();
    expect(find.textContaining('Replying to X1BOBB'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'nice');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    expect(sent, [('nice', 'bbbbbb')]);
    expect(find.textContaining('Replying to'), findsNothing);

    // The menu: mute bob.
    await tester.longPress(find.text('Yes, 3 shares today'));
    await tester.pumpAndSettle();
    expect(find.text('Add X1BOBB to contacts'), findsOneWidget);
    await tester.tap(find.text('Mute X1BOBB'));
    await tester.pumpAndSettle();
    expect(muted, ['X1BOBB']);

    // Our own post offers no mute.
    await tester.longPress(find.text('Same here'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Mute'), findsNothing);
    await tester.tap(find.text('Hide this message'));
    await tester.pumpAndSettle();
    expect(hidden, ['cccccc']);
  });
}
