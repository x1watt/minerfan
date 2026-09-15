import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:hex/hex.dart';
import 'package:i2p/i2p.dart' show I2pMessage;
import 'package:xprs_wire/xprs_wire.dart';

import 'network_keys.dart';

/// The I2P port XPRS packets travel on (the number of its UDP and TCP port).
const xprsI2pPort = 4242;

/// A packet that arrived over I2P, checked.
class XprsInbound {
  final XprsPacket packet;

  /// The readable body of a message: opened when it was sealed, null when
  /// it could not be opened.
  final String? text;
  final bool sealed;

  /// The sender's I2P address; replies and receipts go back there.
  final String fromB32;
  XprsInbound(this.packet, this.text, this.sealed, this.fromB32);

  String get from => packet['f'] ?? '';
}

/// XPRS packets over I2P: one more bearer, like BLE, LAN and Reticulum in
/// xprs (`XprsBearer`, xprs_publisher.dart). An I2P message on
/// [xprsI2pPort] carries XPRS wire lines joined with `\n` (the 4242
/// framing), always led by the sender's signed `t:identity` so the receiver
/// can bind the callsign to its key (section 6.3).
///
/// I2P authenticates the sending destination and hides where each side is;
/// the packets carry their own signatures (section 9.1) and a direct message
/// is sealed to its recipient (section 9.2), so the relays on the path read
/// who writes to whom and when (`t f d ts`), never what.
///
/// Signing, sealing, verifying and opening are curve math, so they run on a
/// short-lived isolate, never on the UI isolate.
class XprsI2pLink {
  final XprsStation me;
  final Future<bool> Function(String b32, int port, Uint8List payload) _send;
  final void Function(String line)? log;

  /// Callsigns we exchange with: they get receipts (a stranger does not,
  /// section 13.7.1). Sending to someone adds them.
  final contacts = <String>{};

  /// Keys learnt from verified `t:identity` lines or contacts.
  final _keys = <String, Uint8List>{};

  /// The address each callsign last wrote from.
  final _addressOf = <String, String>{};
  final _seen = <String>{};
  final _parts = XprsPartTable();
  final _inbox = StreamController<XprsInbound>.broadcast();
  final _receipts = StreamController<({String id, String state, String from})>.broadcast();
  late final StreamSubscription<I2pMessage> _sub;
  String? _identityLine;
  DateTime? _identityAt;
  String _nick = '';

  /// The name shown next to our callsign (`nick:` on our `t:identity`,
  /// section 6.3.1): 1 to 16 letters, digits, `-` or `_`; anything else is
  /// dropped. Empty for none.
  set nick(String value) {
    final n = xprsNick(value);
    if (n == _nick) return;
    _nick = n;
    _identityLine = null;
  }

  XprsI2pLink(Stream<I2pMessage> messages, this._send, this.me, {this.log}) {
    _sub = messages.where((m) => m.port == xprsI2pPort).listen(_onMessage);
  }

  /// Messages and other packets addressed to us or broadcast, once each.
  Stream<XprsInbound> get received => _inbox.stream;

  /// Receipts for what we sent: the section 5 identifier and `ack`/`read`.
  Stream<({String id, String state, String from})> get receipts => _receipts.stream;

  /// The I2P address [callsign] last wrote from.
  String? addressOf(String callsign) => _addressOf[callsign.toUpperCase()];

  /// Someone we exchange with: their npub gives the key, [b32] where to
  /// reach them.
  void addContact(String npub, {String? b32}) {
    final hex = NostrCrypto.decodeNpub(npub);
    final call = 'X1${NostrCrypto.deriveCallsign(hex)}';
    contacts.add(call);
    _keys[call] = Uint8List.fromList(HEX.decode(hex));
    if (b32 != null) _addressOf[call] = b32;
  }

  Future<String> _identity() async {
    final at = _identityAt;
    if (_identityLine == null || at == null || DateTime.now().difference(at) > const Duration(hours: 1)) {
      final priv = me.privateKeyHex, nick = _nick;
      _identityLine = await Isolate.run(() => signIdentityLine(priv, nick));
      _identityAt = DateTime.now();
    }
    return _identityLine!;
  }

  /// Send XPRS [wires] to [b32], after our identity. True when the I2P
  /// network took it (delivery is confirmed by a receipt, not here).
  Future<bool> send(String b32, List<String> wires) async {
    final payload = [await _identity(), ...wires].join('\n');
    return _send(b32, xprsI2pPort, Uint8List.fromList(utf8.encode(payload)));
  }

  /// A private direct message to [npub] at [b32]: sealed and signed (split
  /// into up to 9 parts when long). The result names the message (its
  /// identifier is what a receipt will carry) or why it was refused.
  Future<({XprsBodyResult body, bool sent})> sendDirect(String b32, String npub, String text) async {
    addContact(npub, b32: b32);
    final to = 'X1${NostrCrypto.deriveCallsign(NostrCrypto.decodeNpub(npub))}';
    final priv = me.privateKeyHex, self = me.callsign;
    final body = await Isolate.run(() => _buildDirect(priv, self, to, npub, text));
    if (!body.ok) return (body: body, sent: false);
    final sent = await send(b32, [for (final p in body.packets) p.encode()]);
    return (body: body, sent: sent);
  }

  Future<void> _onMessage(I2pMessage m) async {
    final String text;
    try {
      text = utf8.decode(m.payload);
    } catch (_) {
      return;
    }
    final lines = text.split('\n').where((l) => l.startsWith('t:')).take(128).toList();
    if (lines.isEmpty) return;
    // Locals only: a closure naming a field would capture `this`, which
    // cannot cross to the isolate.
    final known = Map.of(_keys);
    final priv = me.privateKeyHex, self = me.callsign;
    final opened = await Isolate.run(() => _open(lines, known, priv, self));
    for (final (call, key) in opened.identities) {
      _keys[call] = key;
    }
    // Only the sender's own identity (the frame's first line) says where
    // that callsign is: the others are authors whose packets it passes on.
    if (opened.lead != null) _addressOf[opened.lead!] = m.fromB32;
    for (final o in opened.packets) {
      final p = XprsPacket.parse(o.wire)!;
      final id = xprsIdentifier(p);
      // A part of a plain split message carries no signature of its own: the
      // last part signs the whole (section 9.1.1), checked once rejoined.
      final plainPart = p.has('n') && !p.has('x');
      // Checked before dedupe: the identifier leaves out `sig:`, so a copy
      // with a bad signature must not stand in for the real packet.
      if (o.state != XprsSigState.verified && !plainPart) {
        log?.call('xprs: dropped ${p.type} $id from ${p['f']}: ${o.state.name}');
        continue;
      }
      // Duplicates by the full hash: the 24-bit identifier collides once a
      // few thousand packets have been seen.
      if (!_seen.add(xprsFullHash(p))) continue;
      if (_seen.length > 4096) _seen.remove(_seen.first);
      if (p.type == 'receipt') {
        final r = o.receipt;
        if (r != null) _receipts.add((id: r.id, state: r.state, from: p['f'] ?? ''));
        continue;
      }
      var packet = p;
      var clear = o.clear;
      if (p.has('n')) {
        final whole = _parts.offer(p, clear: plainPart ? p['m'] ?? '' : clear);
        if (whole == null) continue; // a part; the message is not complete yet
        packet = whole.packet;
        clear = whole.text;
        if (plainPart) {
          final key = _keys[(p['f'] ?? '').toUpperCase()];
          final sig = whole.sig;
          final joined = sig == null ? null : packet.with_('sig', sig).encode();
          if (key == null || joined == null || !await verifyWireInBackground(joined, key)) {
            log?.call('xprs: dropped a split message from ${p['f']}: its signature does not verify');
            continue;
          }
          packet = XprsPacket.parse(joined)!;
        }
      }
      _inbox.add(XprsInbound(packet, clear, p.has('x'), m.fromB32));
      // Receipts are for messages to a station; a group post gets none
      // (section 13.7.1).
      if (packet.type == 'message' && xprsAddressesStation(packet['d'] ?? '')) {
        unawaited(_ack(packet, m.fromB32));
      }
    }
  }

  Future<void> _ack(XprsPacket p, String b32) async {
    final exchanged = contacts.contains((p['f'] ?? '').toUpperCase());
    final wire = p.encode();
    final priv = me.privateKeyHex, self = me.callsign;
    final receipt = await Isolate.run(() => _receipt(wire, priv, self, exchanged));
    if (receipt != null) await send(b32, [receipt]);
  }

  void close() {
    _sub.cancel();
    _inbox.close();
    _receipts.close();
  }
}

// ---- isolate side: pure functions over plain values ----

BigInt _scalar(String hex) => BigInt.parse(hex, radix: 16);

/// Our signed `t:identity` (section 6.3), with `nick:` when there is one.
String signIdentityLine(String privHex, [String nick = '']) {
  final pub = NostrCrypto.derivePublicKey(privHex);
  final p = XprsPacket.parse('t:identity f:X1${NostrCrypto.deriveCallsign(pub)} ts:${xprsNow()} '
      'k:${NostrCrypto.encodeNpub(pub)}${nick.isEmpty ? '' : ' nick:$nick'}')!;
  return xprsSign(p, _scalar(privHex)).encode();
}

/// A nickname as section 6.3.1 allows it: accents dropped, other characters
/// removed, at most 16.
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

/// The full sha256 of a packet's canonical text (without `sig:` and
/// `via:`), for duplicates: the six-character identifier is for replies.
String xprsFullHash(XprsPacket p) => NostrCrypto.sha256Hash(xprsSignedText(p));

/// Whether [wire]'s signature verifies for [key], on a short-lived isolate.
Future<bool> verifyWireInBackground(String wire, Uint8List key) =>
    Isolate.run(() => xprsVerify(XprsPacket.parse(wire)!, key) == XprsSigState.verified);

XprsBodyResult _buildDirect(String privHex, String self, String to, String npub, String text) {
  final head = XprsPacket.parse('t:message f:$self d:$to ts:${xprsNow()}')!;
  return xprsBuildDirect(
      head: head, text: text, private: true, recipientKeyHex: NostrCrypto.decodeNpub(npub), signingKey: _scalar(privHex));
}

String? _receipt(String wire, String privHex, String self, bool exchanged) =>
    XprsReceipt.compose(XprsPacket.parse(wire)!,
            selfCallsign: self, signingKey: _scalar(privHex), exchanged: exchanged)
        ?.encode();

class _Opened {
  final String wire;
  final XprsSigState state;
  final String? clear;
  final ({String id, String state})? receipt;
  _Opened(this.wire, this.state, this.clear, this.receipt);
}

/// Checks [lines]: `t:identity` lines teach keys (self-signed, and the
/// callsign derives from the key), every other packet is verified against
/// the key of its `f:`, sealed bodies addressed to us are opened and
/// receipts are checked.
({List<(String, Uint8List)> identities, String? lead, List<_Opened> packets}) _open(
    List<String> lines, Map<String, Uint8List> known, String privHex, String self) {
  final keys = Map.of(known);
  final identities = <(String, Uint8List)>[];
  String? lead;
  final out = <_Opened>[];
  final d = _scalar(privHex);
  for (final (i, line) in lines.indexed) {
    final p = XprsPacket.parse(line);
    if (p == null) continue;
    final from = (p['f'] ?? '').toUpperCase();
    if (p.type == 'identity') {
      try {
        final hex = NostrCrypto.decodeNpub(p['k'] ?? '');
        final key = Uint8List.fromList(HEX.decode(hex));
        if (NostrCrypto.callsignMatchesKey(from, hex) && xprsVerify(p, key) == XprsSigState.verified) {
          keys[from] = key;
          identities.add((from, key));
          if (i == 0) lead = from;
        }
      } catch (_) {}
      continue;
    }
    final key = keys[from];
    final state = xprsVerify(p, key);
    String? clear;
    ({String id, String state})? receipt;
    if (state == XprsSigState.verified) {
      if (p.type == 'message' && key != null) {
        final forUs = (p['d'] ?? '').toUpperCase() == self;
        clear = forUs || !p.has('x') ? xprsReadBody(p, ownKey: d, senderKeyHex: HEX.encode(key)).clear : null;
      } else if (p.type == 'receipt') {
        receipt = XprsReceipt.release(p, selfCallsign: self, keyOf: (c) => keys[c.toUpperCase()]);
      }
    }
    out.add(_Opened(line, state, clear, receipt));
  }
  return (identities: identities, lead: lead, packets: out);
}
