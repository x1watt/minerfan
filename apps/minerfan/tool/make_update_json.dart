// Writes the update.json the app reads from the project's page.
//
//   dart run tool/make_update_json.dart <version> <assets dir> <out file>
//
// The assets directory is the one a release was packed from: every file
// it names is hashed, so the app can tell a whole download from a broken
// one. Nothing here knows the app's name or address beyond what is passed
// in, so a rename or a move is a matter of the arguments.

import 'dart:convert';
import 'dart:io';

import 'package:crypto_core/crypto_core.dart' show Sha256;

/// What each platform's file is called in a release, by the key the app
/// looks for.
const builds = {
  'android': 'minerfan-android.apk',
  'linux-x64': 'minerfan-linux-x64.tar.gz',
  'windows-x64': 'minerfan-windows-x64.zip',
  'macos': 'minerfan-macos.dmg',
};

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln('use: dart run tool/make_update_json.dart <version> <assets dir> <out file> [notes file]');
    exit(2);
  }
  final version = args[0].startsWith('v') ? args[0].substring(1) : args[0];
  final dir = args[1];
  final out = args[2];
  final notes = args.length > 3 && File(args[3]).existsSync() ? File(args[3]).readAsStringSync().trim() : '';

  final app = Platform.environment['UPDATE_APP'] ?? 'minerfan';
  final page = Platform.environment['UPDATE_PAGE'] ?? 'https://x1watt.github.io/minerfan/';
  final base = Platform.environment['UPDATE_BASE'] ??
      'https://github.com/x1watt/minerfan/releases/download/v$version';
  // Set when the check itself moves somewhere else.
  final next = Platform.environment['UPDATE_NEXT'] ?? '';

  final entries = <String, Object?>{};
  for (final e in builds.entries) {
    final f = File('$dir/${e.value}');
    if (!f.existsSync()) {
      stderr.writeln('skipping ${e.key}: no ${e.value} in $dir');
      continue;
    }
    final digest = Sha256();
    await for (final chunk in f.openRead()) {
      digest.update(chunk);
    }
    entries[e.key] = {
      'url': '$base/${e.value}',
      'file': e.value,
      'size': f.lengthSync(),
      'sha256': [for (final b in digest.digest()) b.toRadixString(16).padLeft(2, '0')].join(),
    };
  }
  if (entries.isEmpty) {
    stderr.writeln('no files found in $dir');
    exit(1);
  }

  final json = const JsonEncoder.withIndent('  ').convert({
    'app': app,
    'version': version,
    if (notes.isNotEmpty) 'notes': notes,
    'page': page,
    if (next.isNotEmpty) 'next': next,
    'builds': entries,
  });
  File(out).writeAsStringSync('$json\n');
  stdout.writeln('wrote $out for $app $version with ${entries.length} build(s)');
}
