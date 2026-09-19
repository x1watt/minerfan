// What version this build is, and how versions compare.
//
// `appVersion` is checked against pubspec.yaml by a test, so bumping the
// pubspec is enough and the two cannot drift.

/// This build's version, the same string as `version:` in pubspec.yaml
/// without the build number.
const appVersion = '0.3.0';

/// Compares two versions of the shape `1.2.3` (a `+build` or a `-beta.1`
/// tail is allowed): negative when [a] is older, zero when they are the
/// same release, positive when [a] is newer.
///
/// A pre-release (`1.0.0-beta.1`) is older than the release it leads to,
/// as semantic versioning says. Anything unreadable counts as 0.
int compareVersions(String a, String b) {
  final (an, apre) = _split(a);
  final (bn, bpre) = _split(b);
  for (var i = 0; i < 3; i++) {
    final d = (i < an.length ? an[i] : 0) - (i < bn.length ? bn[i] : 0);
    if (d != 0) return d < 0 ? -1 : 1;
  }
  if (apre.isEmpty && bpre.isEmpty) return 0;
  if (apre.isEmpty) return 1; // a release beats its own pre-releases
  if (bpre.isEmpty) return -1;
  return apre.compareTo(bpre);
}

/// True when [candidate] is a later release than [current].
bool isNewerVersion(String candidate, String current) => compareVersions(candidate, current) > 0;

(List<int>, String) _split(String v) {
  var s = v.trim();
  if (s.startsWith('v')) s = s.substring(1);
  final plus = s.indexOf('+');
  if (plus >= 0) s = s.substring(0, plus);
  final dash = s.indexOf('-');
  final pre = dash >= 0 ? s.substring(dash + 1) : '';
  if (dash >= 0) s = s.substring(0, dash);
  return ([for (final p in s.split('.')) int.tryParse(p.trim()) ?? 0], pre);
}
