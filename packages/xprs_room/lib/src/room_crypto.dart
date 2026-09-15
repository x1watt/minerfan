// The curve math of a room, as top-level functions over plain values so
// they run on a short-lived isolate (Isolate.run): signing posts,
// reactions, history asks and our identity, and checking what arrives.
import 'dart:typed_data';

import 'package:hex/hex.dart';
import 'package:xprs_wire/xprs_wire.dart';

import 'room_item.dart';

BigInt _scalar(String hex) => BigInt.parse(hex, radix: 16);

/// A nickname as docs XPRS.md 6.3.1 allows it: accents dropped, spaces as
/// `_`, only letters, digits, `-` and `_`, at most 16.
String xprsNick(String name) {
  const from = 'áàâãäåçéèêëíìîïñóòôõöúùûüýÁÀÂÃÄÅÇÉÈÊËÍÌÎÏÑÓÒÔÕÖÚÙÛÜÝ';
  const to = 'aaaaaaceeeeiiiinooooouuuuyAAAAAACEEEEIIIINOOOOOUUUUY';
  final b = StringBuffer();
  for (final ch in name.trim().replaceAll(' ', '_').split('')) {
    final i = from.indexOf(ch);
    final c = i >= 0 ? to[i] : ch;
    if (RegExp(r'[A-Za-z0-9_-]').hasMatch(c)) b.write(c);
  }
  final s = b.toString();
  return s.length > 16 ? s.substring(0, 16) : s;
}

/// Our signed `t:identity` (section 6.3), with `nick:` when there is one.
String signRoomIdentity(String privHex, String nick) {
  final pub = NostrCrypto.derivePublicKey(privHex);
  final n = xprsNick(nick);
  final p = XprsPacket.parse('t:identity f:X1${NostrCrypto.deriveCallsign(pub)} ts:${xprsNowTs()} '
      'k:${NostrCrypto.encodeNpub(pub)}${n.isEmpty ? '' : ' nick:$n'}')!;
  return xprsSign(p, _scalar(privHex)).encode();
}

/// A post to [room] (section 7.3), split into signed parts when long
/// (section 7.6, 9.1.1). [replyTo] and [root] name the post answered and
/// the thread's first post (section 7.4). Empty when it cannot be built.
List<String> signRoomPost(String privHex, String self, String room, String text, {String? replyTo, String? root}) {
  final extra = [
    if (replyTo != null) 'r:$replyTo',
    if (root != null && root != replyTo) 'root:$root',
  ].join(' ');
  final head = XprsPacket.parse('t:message f:$self d:$room ts:${xprsNowTs()}${extra.isEmpty ? '' : ' $extra'}')!;
  final built = xprsBuildDirect(head: head, text: text.trim(), private: false, signingKey: _scalar(privHex));
  return built.ok ? [for (final p in built.packets) p.encode()] : const [];
}

/// A like, or taking it back (section 7.5), with `ts:` so the newest wins.
String signReaction(String privHex, String self, String room, String postId, bool like) {
  final p = XprsPacket.parse('t:reaction f:$self d:$room ts:${xprsNowTs()} r:$postId ${like ? 'add' : 'remove'}:like')!;
  return xprsSign(p, _scalar(privHex)).encode();
}

/// A catch-up ask (section 11.2) addressed to the room.
String signHistoryAsk(String privHex, String self, String room, int sinceMs, int untilMs) {
  final p = XprsPacket.parse('t:command f:$self d:$room ts:${xprsNowTs()} cmd:history '
      'since:${xprsNowTs(sinceMs)} until:${xprsNowTs(untilMs)} only:$room kind:message,reaction')!;
  return xprsSign(p, _scalar(privHex)).encode();
}

/// What a frame's lines turned out to be.
class CheckedFrame {
  /// Verified identities (self-signed, callsign derived from the key).
  final List<RoomIdentity> identities;

  /// The callsign of the frame's first line when it is a verified
  /// identity: the sender's own.
  final String? lead;

  /// Every other line with its verdict: `ok` (signature verified), `part`
  /// (a part of a plain split post, checked once rejoined), or `bad`.
  final List<(String wire, String verdict)> lines;
  CheckedFrame(this.identities, this.lead, this.lines);
}

/// Checks [lines] against the keys learnt from their own identity lines and
/// [known] (callsign -> x-only key hex).
CheckedFrame checkRoomFrame(List<String> lines, Map<String, String> known) {
  final keys = Map.of(known);
  final ids = <RoomIdentity>[];
  String? lead;
  final out = <(String, String)>[];
  for (final (i, line) in lines.indexed) {
    final p = XprsPacket.parse(line);
    if (p == null) continue;
    final from = (p['f'] ?? '').toUpperCase();
    if (p.type == 'identity') {
      try {
        final hex = NostrCrypto.decodeNpub(p['k'] ?? '');
        if (NostrCrypto.callsignMatchesKey(from, hex) &&
            xprsVerify(p, Uint8List.fromList(HEX.decode(hex))) == XprsSigState.verified) {
          keys[from] = hex;
          ids.add(RoomIdentity(from, hex, p['nick'] ?? '', xprsParseTs(p['ts']) ?? 0, line));
          if (i == 0) lead = from;
        }
      } catch (_) {}
      continue;
    }
    final key = keys[from];
    if (p.has('n') && !p.has('x') && p.type == 'message') {
      out.add((line, 'part'));
      continue;
    }
    final ok = key != null && xprsVerify(p, Uint8List.fromList(HEX.decode(key))) == XprsSigState.verified;
    out.add((line, ok ? 'ok' : 'bad'));
  }
  return CheckedFrame(ids, lead, out);
}

/// Whether a rejoined post's signature verifies for [keyHex].
bool verifyJoined(String wire, String keyHex) {
  final p = XprsPacket.parse(wire);
  return p != null && xprsVerify(p, Uint8List.fromList(HEX.decode(keyHex))) == XprsSigState.verified;
}

/// A moderation act (moderation.dart) for [room], signed by [self]: the
/// act's own [fields] in order, then [text] as `m:` (always last, section
/// 4). [tsMs] pins the time (tests). Empty when the packet does not fit.
String signModAct(String privHex, String self, String room, List<(String, String)> fields,
    {String? text, int? tsMs}) {
  final b = StringBuffer('t:moderate f:$self d:$room ts:${xprsNowTs(tsMs)}');
  for (final (k, v) in fields) {
    b.write(' $k:$v');
  }
  if (text != null && text.trim().isNotEmpty) b.write(' m:${text.trim()}');
  final p = XprsPacket.parse(b.toString());
  if (p == null) return '';
  final signed = xprsSign(p, _scalar(privHex));
  return signed.fits ? signed.encode() : '';
}
