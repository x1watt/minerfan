// Adapted from app/lib/services/xprs/xprs_receipt.dart (xprs, BSD-3-Clause,
// Max Brito): XprsReceipt.compose and XprsReceipt.release with the same rules
// (docs XPRS.md 13.7, 13.7.1). What xprs reads from its archive (whether we
// ever exchanged with the sender, and the sender's key) comes from the caller
// here, and the counters, the remembered set and the log are left out.
import 'dart:typed_data';

import 'nostr_crypto.dart';
import 'xprs_id.dart';
import 'xprs_packet.dart';
import 'xprs_sig.dart';

/// Composing and reading `t:receipt ... s:ack`.
class XprsReceipt {
  /// The receipt [p] deserves, or null when section 13.7.1 says not to send
  /// one. [p] must be the packet as it arrived: `r:` is its section 5
  /// identifier. [exchanged] is whether this station has exchanged with the
  /// sender before; a stranger gets no receipt (13.7.1). A receipt is always
  /// signed: without [signingKey] there is none, because an unsigned `s:ack`
  /// is a way to delete mail.
  static XprsPacket? compose(XprsPacket p,
      {required String selfCallsign,
      required BigInt? signingKey,
      bool exchanged = true,
      String state = 'ack'}) {
    if (p.type != 'message') return null;

    final self = _base(selfCallsign);
    final to = _base(p['d'] ?? '');
    final from = (p['f'] ?? '').trim().toUpperCase();
    if (self.isEmpty || from.isEmpty) return null;

    // A broadcast, a regional or a group message, or a receipt: no receipt.
    if (to.isEmpty || to != self) return null;
    if (p.has('dest')) return null;
    if (!_isStation(p['d'] ?? '')) return null;
    if (from == self) return null;
    if (!exchanged) return null;

    final d = signingKey;
    if (d == null) return null;

    final r = XprsPacket.parse(
        't:receipt f:$self d:$from r:${xprsIdentifier(p)} ts:${xprsNow()} '
        's:$state');
    if (r == null) return null;
    final signed = xprsSign(r, d);
    return signed.fits ? signed : null;
  }

  /// Read an inbound `t:receipt`: the identifier it releases and the state
  /// it reports, or null when it releases nothing. [keyOf] resolves a
  /// callsign to its 32-byte x-only key; a signer we cannot check counts as a
  /// bad signature. `read` implies `ack`.
  static ({String id, String state})? release(XprsPacket p,
      {required String selfCallsign, required Uint8List? Function(String) keyOf}) {
    if (p.type != 'receipt') return null;
    final says = (p['s'] ?? '').split(',').map((w) => w.trim()).toSet();
    final read = says.contains('read');
    if (!says.contains('ack') && !read) return null;
    final id = (p['r'] ?? '').trim();
    if (id.length != 6) return null;

    final from = (p['f'] ?? '').trim().toUpperCase();
    if (from.isEmpty || from == _base(selfCallsign)) return null;

    final key = keyOf(from);
    if (!p.has('sig') || key == null) return null;
    if (xprsVerify(p, key) != XprsSigState.verified) return null;
    return (id: id, state: read ? 'read' : 'ack');
  }

  static String _base(String c) => NostrCrypto.bareCallsign(c).toUpperCase();

  /// A station address, not a group (section 6.3).
  static bool _isStation(String d) {
    final s = d.trim().toUpperCase();
    if (s.isEmpty || s.startsWith('#') || s.startsWith('!')) return false;
    return RegExp(r'^(X[1345][A-Z0-9]{2,5}|[A-Z0-9]{1,3}[0-9][A-Z0-9]*)'
            r'(-[0-9]{1,2})?(/[A-Z0-9]+)?$')
        .hasMatch(s);
  }
}

/// The `ts:` value for now: UTC, `2026-08-08_14:26:40` (as `XprsSend._now`).
String xprsNow([DateTime? at]) {
  final t = (at ?? DateTime.now()).toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}_'
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}
