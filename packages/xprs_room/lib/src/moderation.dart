// Moderation of an open room: a minerfan extension of XPRS.
//
// Section 10 of docs XPRS.md gives closed groups an admin and moderators,
// with one packet type, `t:moderate`, for every act (grant:, revoke:,
// role:mod, until:, r: ... hide:message). Open groups (7.3) have none. A
// coin room borrows those shapes with one built-in admin (a station key
// the app trusts) and terms that are bought:
//
// - admin: `grant:<callsign> role:mod until:<ts + 30 days> paid:<amount>`
//   starts a term; a later grant ends the previous one at once (newest
//   admin grant wins); `revoke:<callsign>` from the admin ends that term;
// - moderator (or admin): `r:<id> hide:message` hides a post for good;
//   `revoke:<callsign> until:<time>` mutes someone, at most until the term
//   ends; `grant:<callsign>` approves someone (and lifts their mute);
//   `r:<id> pin:message`, `set:unpin`, `set:topic m:<text>`,
//   `set:approval`, `set:open` shape the room for the term.
//
// Everything a moderator sets, except hides, belongs to the term it was set
// in and ends with it, by expiry or takeover. Authority is judged at the
// act's `ts:` (10.4). Acts dated in the future are dropped.

import 'package:xprs_wire/xprs_wire.dart';

/// How long a bought term lasts.
const moderatorTerm = Duration(days: 30);

/// How far ahead of our clock an act may be dated.
const _futureSlack = Duration(minutes: 5);

enum ModKind { term, endTerm, hide, mute, approve, pin, unpin, topic, approval, open }

/// One verified `t:moderate` act for this room.
class ModAct {
  final XprsPacket packet;
  final String wire;
  final ModKind kind;
  final String signer;
  final int tsMs;

  /// The callsign acted on (term, endTerm, mute, approve).
  final String? target;

  /// The post acted on (hide, pin).
  final String? postId;

  /// When a term or mute ends as written (capped later).
  final int? untilMs;

  /// The payment behind a term, in the coin's smallest unit.
  final BigInt? paid;

  /// A topic's text.
  final String? text;

  ModAct._(this.packet, this.wire, this.kind, this.signer, this.tsMs,
      {this.target, this.postId, this.untilMs, this.paid, this.text});

  /// The section 5 identifier: ties on `ts:` go to the smaller one.
  late final String id = xprsIdentifier(packet);
}

/// [p] as a moderation act of [room], or null. The signature is the
/// caller's business; this only reads the shape.
ModAct? parseModeration(XprsPacket p, String wire, String room) {
  if (p.type != 'moderate' || (p['d'] ?? '').toUpperCase() != room) return null;
  final signer = (p['f'] ?? '').toUpperCase();
  final ts = xprsParseTs(p['ts']);
  if (signer.isEmpty || ts == null) return null;
  final grant = p['grant']?.toUpperCase();
  final revoke = p['revoke']?.toUpperCase();
  final until = xprsParseTs(p['until']);
  final r = p['r'];
  final set = p['set'];
  if (grant != null && !grant.contains(',')) {
    if (p['role'] == 'mod') {
      final paid = BigInt.tryParse(p['paid'] ?? '0') ?? BigInt.zero;
      return ModAct._(p, wire, ModKind.term, signer, ts, target: grant, untilMs: until, paid: paid);
    }
    return ModAct._(p, wire, ModKind.approve, signer, ts, target: grant);
  }
  if (revoke != null && !revoke.contains(',')) {
    return until == null
        ? ModAct._(p, wire, ModKind.endTerm, signer, ts, target: revoke)
        : ModAct._(p, wire, ModKind.mute, signer, ts, target: revoke, untilMs: until);
  }
  if (r != null && p['hide'] == 'message') return ModAct._(p, wire, ModKind.hide, signer, ts, postId: r);
  if (r != null && p['pin'] == 'message') return ModAct._(p, wire, ModKind.pin, signer, ts, postId: r);
  switch (set) {
    case 'unpin':
      return ModAct._(p, wire, ModKind.unpin, signer, ts);
    case 'topic':
      return ModAct._(p, wire, ModKind.topic, signer, ts, text: (p['m'] ?? '').trim());
    case 'approval':
      return ModAct._(p, wire, ModKind.approval, signer, ts);
    case 'open':
      return ModAct._(p, wire, ModKind.open, signer, ts);
  }
  return null;
}

/// A moderator's term: from the grant until it expires, is taken over or is
/// ended by the admin.
class ModTerm {
  final String callsign;
  final int startMs;
  final int endMs;
  final BigInt paid;
  final ModAct grant;
  ModTerm(this.callsign, this.startMs, this.endMs, this.paid, this.grant);

  bool covers(int ms) => ms >= startMs && ms < endMs;
}

/// The room's moderation at one moment, replayed from verified acts.
class ModerationState {
  final String admin;
  final int nowMs;

  /// Every term, oldest first, each ended by expiry, takeover or the admin.
  final List<ModTerm> terms;

  /// The term running now, if any.
  final ModTerm? term;

  /// Posts hidden for everyone (hides outlive the term that made them).
  final Set<String> hidden;

  /// Callsigns muted now, with when their mute ends.
  final Map<String, int> muted;

  /// Posting needs approval, since [approvalSinceMs].
  final bool approval;
  final int approvalSinceMs;
  final Set<String> approved;
  final String? topic;
  final String? pinned;

  /// The next moment the state changes by itself (a term or mute ending).
  final int? nextChangeMs;

  ModerationState._(this.admin, this.nowMs, this.terms, this.term, this.hidden, this.muted, this.approval,
      this.approvalSinceMs, this.approved, this.topic, this.pinned, this.nextChangeMs);

  String? get moderator => term?.callsign;

  /// What a new payment has to exceed now: the running term's, else zero.
  BigInt get toBeat => term?.paid ?? BigInt.zero;

  bool isModerator(String callsign) => callsign == admin || callsign == term?.callsign;

  /// Whether [callsign] was muted when it wrote at [tsMs].
  bool mutedAt(String callsign, int tsMs) => _mutes.any((m) => m.$1 == callsign && tsMs >= m.$2 && tsMs < m.$3);
  final List<(String, int, int)> _mutes = [];

  /// A post everyone sees (hidden and held posts are not).
  bool shows(String from, String id, int tsMs) =>
      !hidden.contains(id) && !mutedAt(from, tsMs) && !held(from, tsMs);

  /// A post waiting for the moderator's approval.
  bool held(String from, int tsMs) =>
      approval && tsMs >= approvalSinceMs && !isModerator(from) && !approved.contains(from);

  /// Replays [acts] as of [nowMs]. [admin] is the room's admin callsign.
  factory ModerationState.replay(Iterable<ModAct> acts, String admin, int nowMs) {
    final ordered = [
      for (final a in acts)
        if (a.tsMs <= nowMs + _futureSlack.inMilliseconds) a,
    ]..sort((a, b) => a.tsMs != b.tsMs ? a.tsMs.compareTo(b.tsMs) : a.id.compareTo(b.id));

    // Terms: newest admin grant wins; each grant cuts the one before.
    final terms = <ModTerm>[];
    for (final a in ordered) {
      if (a.signer != admin) continue;
      if (a.kind == ModKind.term) {
        final cap = a.tsMs + moderatorTerm.inMilliseconds;
        final end = a.untilMs == null || a.untilMs! > cap ? cap : a.untilMs!;
        if (end <= a.tsMs) continue;
        _cut(terms, a.tsMs);
        terms.add(ModTerm(a.target!, a.tsMs, end, a.paid ?? BigInt.zero, a));
      } else if (a.kind == ModKind.endTerm) {
        final t = terms.isEmpty ? null : terms.last;
        if (t != null && t.callsign == a.target && t.covers(a.tsMs)) _cut(terms, a.tsMs);
      }
    }
    ModTerm? termAt(int ms) {
      for (final t in terms.reversed) {
        if (t.covers(ms)) return t;
        if (t.startMs <= ms) return null;
      }
      return null;
    }

    final current = termAt(nowMs);
    final hidden = <String>{};
    final mutes = <(String, int, int)>[];
    var approval = false, approvalSince = 0;
    final approved = <String>{};
    String? topic, pinned;
    // Everything but hides belongs to the period it was set in: a term, or
    // the stretch with no term (only the admin acts there). A period's
    // settings apply only while it is the current one.
    ({int start, int end}) periodAt(int ms) {
      final t = termAt(ms);
      if (t != null) return (start: t.startMs, end: t.endMs);
      final before = [for (final x in terms) if (x.endMs <= ms) x.endMs];
      final after = [for (final x in terms) if (x.startMs > ms) x.startMs];
      return (
        start: before.isEmpty ? 0 : before.reduce((a, b) => a > b ? a : b),
        end: after.isEmpty ? 1 << 62 : after.reduce((a, b) => a < b ? a : b),
      );
    }

    final now = periodAt(nowMs);
    for (final a in ordered) {
      if (a.kind == ModKind.term || a.kind == ModKind.endTerm) continue;
      final byAdmin = a.signer == admin;
      final t = termAt(a.tsMs);
      if (!byAdmin && t?.callsign != a.signer) continue; // no authority at ts:
      if (a.kind == ModKind.hide) {
        hidden.add(a.postId!);
        continue;
      }
      final p = periodAt(a.tsMs);
      final isNow = p.start == now.start && p.end == now.end;
      switch (a.kind) {
        case ModKind.mute:
          final end = [a.untilMs!, p.end].reduce((x, y) => x < y ? x : y);
          if (end > a.tsMs) mutes.add((a.target!, a.tsMs, end));
        case ModKind.approve:
          // Approving lifts a mute from that moment on.
          for (var i = 0; i < mutes.length; i++) {
            final m = mutes[i];
            if (m.$1 == a.target && a.tsMs < m.$3) mutes[i] = (m.$1, m.$2, a.tsMs);
          }
          if (isNow) approved.add(a.target!);
        case ModKind.pin:
          if (isNow) pinned = a.postId;
        case ModKind.unpin:
          if (isNow) pinned = null;
        case ModKind.topic:
          if (isNow) topic = a.text!.isEmpty ? null : a.text;
        case ModKind.approval:
          if (isNow && !approval) {
            approval = true;
            approvalSince = a.tsMs;
          }
        case ModKind.open:
          if (isNow) approval = false;
        default:
      }
    }
    final muted = <String, int>{
      for (final m in mutes)
        if (nowMs >= m.$2 && nowMs < m.$3) m.$1: m.$3,
    };
    final changes = [
      if (current != null) current.endMs,
      ...muted.values,
      if (now.end < 1 << 62) now.end,
    ]..sort();
    return ModerationState._(admin, nowMs, terms, current, hidden, muted, approval, approvalSince, approved,
        topic, pinned, changes.isEmpty ? null : changes.first)
      .._mutes.addAll(mutes);
  }

  static void _cut(List<ModTerm> terms, int atMs) {
    if (terms.isEmpty) return;
    final t = terms.last;
    if (t.endMs > atMs) terms[terms.length - 1] = ModTerm(t.callsign, t.startMs, atMs, t.paid, t.grant);
  }
}
