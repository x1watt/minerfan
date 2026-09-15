// Adapted from reticulum-dart lib/src/services/social/spam.dart (xprs,
// BSD-3-Clause, Max Brito): SpamPolicy's per-author sliding windows and
// size caps, keyed by XPRS callsign instead of NOSTR public key, with a
// second window per hour and a limit on authors new to a busy room. An open
// room has no moderators (docs XPRS.md 7.3), so this is what keeps a single
// sender from drowning it: a post over a limit is neither kept nor passed on.

/// Why a post was refused, or null.
typedef FloodVerdict = String?;

class FloodGuard {
  final int postsPerMinute;
  final int postsPerHour;
  final int reactionsPerMinute;

  /// When the whole room has taken this many posts in the last minute,
  /// authors first seen in the last [newAuthor] are held back: a burst of
  /// throwaway callsigns cannot push the regulars out.
  final int busyRoomPerMinute;
  final Duration newAuthor;

  final _posts = <String, List<int>>{};
  final _reactions = <String, List<int>>{};
  final _firstSeen = <String, int>{};
  final _room = <int>[];

  FloodGuard({
    this.postsPerMinute = 6,
    this.postsPerHour = 60,
    this.reactionsPerMinute = 30,
    this.busyRoomPerMinute = 30,
    this.newAuthor = const Duration(minutes: 10),
  });

  /// Checks a post or reaction by [callsign] and counts it when accepted.
  FloodVerdict check(String callsign, {required bool reaction, required int nowMs}) {
    final first = _firstSeen.putIfAbsent(callsign, () => nowMs);
    List<int> recent(Map<String, List<int>> m, Duration span) {
      final l = m.putIfAbsent(callsign, () => []);
      l.removeWhere((t) => nowMs - t >= span.inMilliseconds);
      return l;
    }

    if (reaction) {
      final r = recent(_reactions, const Duration(minutes: 1));
      if (r.length >= reactionsPerMinute) return 'too many reactions';
      r.add(nowMs);
      return null;
    }
    final hour = recent(_posts, const Duration(hours: 1));
    final minute = hour.where((t) => nowMs - t < 60000).length;
    if (minute >= postsPerMinute) return 'too many posts this minute';
    if (hour.length >= postsPerHour) return 'too many posts this hour';
    _room.removeWhere((t) => nowMs - t >= 60000);
    if (_room.length >= busyRoomPerMinute && nowMs - first < newAuthor.inMilliseconds) {
      return 'the room is busy and this author is new';
    }
    hour.add(nowMs);
    _room.add(nowMs);
    return null;
  }

  /// Forget authors silent for over an hour (keeps the maps small).
  void sweep(int nowMs) {
    _posts.removeWhere((_, l) => l.every((t) => nowMs - t >= 3600000));
    _reactions.removeWhere((_, l) => l.every((t) => nowMs - t >= 60000));
    if (_firstSeen.length > 5000) _firstSeen.clear();
  }
}
