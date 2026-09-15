import 'dart:math';

/// Someone in a room: where they are (I2P address), their callsign, and
/// when they were last heard. [live] once a frame from that address carried
/// a verified identity (so the callsign really answers there); until then a
/// listed member is only a candidate that someone else passed on.
class Member {
  final String b32;
  String callsign;
  int lastSeenMs;
  bool live;
  Member(this.b32, this.callsign, this.lastSeenMs, {this.live = false});

  Map<String, Object?> toJson() => {'b': b32, 'c': callsign, 's': lastSeenMs ~/ 1000, if (live) 'l': true};

  static Member? fromJson(Map<String, Object?> m) {
    final b = m['b'] as String?;
    if (b == null || !b.endsWith('.b32.i2p')) return null;
    return Member(b, '${m['c'] ?? ''}', ((m['s'] as num?) ?? 0).toInt() * 1000, live: m['l'] == true);
  }
}

/// A room's members, capped at [cap] (the least recently heard go first).
class MemberTable {
  final int cap;

  /// Our own address (never listed as a member); known once online.
  String? self;
  final _byB32 = <String, Member>{};
  MemberTable({this.cap = 200, this.self});

  Iterable<Member> get all => _byB32.values;
  Member? operator [](String b32) => _byB32[b32];

  /// A frame with a verified identity came from [b32].
  void heard(String b32, String callsign, int nowMs) {
    if (b32 == self) return;
    final m = _byB32[b32];
    if (m == null) {
      _byB32[b32] = Member(b32, callsign, nowMs, live: true);
    } else {
      m
        ..callsign = callsign
        ..lastSeenMs = nowMs
        ..live = true;
    }
    _trim();
  }

  /// Someone listed [b32] as a member: a candidate unless known already.
  void offer(String b32, String callsign, int lastSeenMs) {
    if (b32 == self || !b32.endsWith('.b32.i2p')) return;
    final m = _byB32[b32];
    if (m == null) {
      _byB32[b32] = Member(b32, callsign, lastSeenMs);
      _trim();
    } else if (!m.live && lastSeenMs > m.lastSeenMs) {
      m.lastSeenMs = lastSeenMs;
    }
  }

  /// Members heard within [within], newest first.
  List<Member> recent(int nowMs, {Duration within = const Duration(minutes: 45), bool liveOnly = true}) => [
        for (final m in _byB32.values)
          if ((!liveOnly || m.live) && nowMs - m.lastSeenMs <= within.inMilliseconds) m,
      ]..sort((a, b) => b.lastSeenMs.compareTo(a.lastSeenMs));

  /// Up to [n] random members from [from], skipping [exclude] addresses
  /// and callsigns.
  static List<Member> sample(List<Member> from, int n, Random rng, {Set<String> exclude = const {}}) {
    final pool = [
      for (final m in from)
        if (!exclude.contains(m.b32) && !exclude.contains(m.callsign)) m,
    ]..shuffle(rng);
    return pool.take(n).toList();
  }

  void forget(String b32) => _byB32.remove(b32);

  void _trim() {
    if (_byB32.length <= cap) return;
    final byAge = _byB32.values.toList()..sort((a, b) => a.lastSeenMs.compareTo(b.lastSeenMs));
    for (final m in byAge.take(_byB32.length - cap)) {
      _byB32.remove(m.b32);
    }
  }

  List<Map<String, Object?>> toJson() => [for (final m in _byB32.values) m.toJson()];

  void load(List<Object?> json) {
    for (final e in json) {
      if (e is Map) {
        final m = Member.fromJson(e.cast<String, Object?>());
        if (m != null && m.b32 != self) _byB32[m.b32] = m;
      }
    }
    _trim();
  }
}
