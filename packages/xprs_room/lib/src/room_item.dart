import 'package:xprs_wire/xprs_wire.dart';

/// One thing said in a room: a post (`t:message d:ROOM`, possibly sent in
/// parts) or a reaction (`t:reaction d:ROOM r:<id>`), with its signature
/// already checked.
class RoomItem {
  /// The packet as a whole: a split post rejoined, with the signature of
  /// its last part.
  final XprsPacket packet;

  /// The wires as the author sent them (one, or the parts in order): what
  /// history replays, so every receiver can check the author's signature.
  final List<String> wires;

  RoomItem(this.packet, this.wires);

  /// Full sha256 of the canonical text, for duplicates.
  late final String key = NostrCrypto.sha256Hash(xprsSignedText(packet));

  /// The section 5 identifier, what replies (`r:`) and reactions name.
  late final String id = xprsIdentifier(packet);

  String get kind => packet.type;
  String get from => (packet['f'] ?? '').toUpperCase();
  String get room => (packet['d'] ?? '').toUpperCase();
  late final int tsMs = xprsParseTs(packet['ts']) ?? 0;
  String get text => packet['m'] ?? '';

  /// The post this one answers, and the thread's first post (section 7.4).
  String? get replyTo => packet['r'];
  String? get root => packet['root'];

  bool get isPost => kind == 'message';
  bool get isReaction => kind == 'reaction';

  /// For a reaction: whether it adds or removes a like.
  bool get likes => packet['add'] == 'like';

  int get bytes => wires.fold(0, (a, w) => a + w.length + 1);
}

/// Who a callsign is, from its newest signed `t:identity` (section 6.3).
class RoomIdentity {
  final String callsign;
  final String keyHex;
  final String nick;
  final int tsMs;
  final String wire;
  RoomIdentity(this.callsign, this.keyHex, this.nick, this.tsMs, this.wire);

  String get npub => NostrCrypto.encodeNpub(keyHex);
}
