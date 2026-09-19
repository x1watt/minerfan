// What the site says about the newest version.
//
// The app reads one small JSON file from the project's page. Everything
// that could change later is in the file itself, not baked into the app:
// the app's name, where the next check should go (`next`, when the page
// or even the project moves) and one entry per platform with its own
// download address. The app only has to know a starting address, which
// the user can change too.
//
//   {
//     "app": "minerfan",
//     "version": "0.2.3",
//     "notes": "What changed",
//     "page": "https://x1watt.github.io/minerfan/",
//     "next": "https://elsewhere.example/update.json",
//     "builds": {
//       "linux-x64": {"url": "https://.../minerfan-linux-x64.tar.gz",
//                     "size": 17757586, "sha256": "0a7e..."}
//     }
//   }

import 'dart:convert';
import 'dart:io';

/// One file to download, for one kind of machine.
class UpdateBuild {
  final String platform;
  final String url;

  /// Bytes, or null when the file does not say.
  final int? size;

  /// Lowercase hex, or null. A build without one is downloaded but the
  /// app cannot promise it arrived whole.
  final String? sha256;

  /// What to call the downloaded file.
  final String fileName;

  const UpdateBuild({
    required this.platform,
    required this.url,
    required this.fileName,
    this.size,
    this.sha256,
  });
}

/// The newest version, as the site describes it.
class UpdateManifest {
  /// What the app calls itself now (it may be renamed later).
  final String app;
  final String version;
  final String notes;

  /// The page a person can open to read more.
  final String page;

  /// Where to look next time, when the check moves elsewhere.
  final String? next;

  final Map<String, UpdateBuild> builds;

  const UpdateManifest({
    required this.app,
    required this.version,
    this.notes = '',
    this.page = '',
    this.next,
    this.builds = const {},
  });

  /// The build for this machine, or null when the site offers none.
  UpdateBuild? get mine => builds[currentPlatform];

  static UpdateManifest? parse(String text) {
    try {
      final m = (jsonDecode(text) as Map).cast<String, Object?>();
      final version = '${m['version'] ?? ''}'.trim();
      if (version.isEmpty) return null;
      final builds = <String, UpdateBuild>{};
      for (final e in ((m['builds'] as Map?) ?? const {}).entries) {
        final b = e.value;
        if (b is! Map) continue;
        final url = '${b['url'] ?? ''}'.trim();
        if (url.isEmpty) continue;
        final sha = '${b['sha256'] ?? ''}'.trim().toLowerCase();
        builds['${e.key}'] = UpdateBuild(
          platform: '${e.key}',
          url: url,
          fileName: '${b['file'] ?? ''}'.trim().isNotEmpty ? '${b['file']}'.trim() : _fileNameOf(url),
          size: (b['size'] as num?)?.toInt(),
          sha256: RegExp(r'^[0-9a-f]{64}$').hasMatch(sha) ? sha : null,
        );
      }
      final next = '${m['next'] ?? ''}'.trim();
      return UpdateManifest(
        app: '${m['app'] ?? 'minerfan'}'.trim(),
        version: version,
        notes: '${m['notes'] ?? ''}'.trim(),
        page: '${m['page'] ?? ''}'.trim(),
        next: next.isEmpty ? null : next,
        builds: builds,
      );
    } catch (_) {
      return null;
    }
  }

  static String _fileNameOf(String url) {
    final path = Uri.tryParse(url)?.path ?? '';
    final name = path.split('/').where((p) => p.isNotEmpty).lastOrNull ?? '';
    return name.isEmpty ? 'update.bin' : name;
  }
}

/// The key this machine looks for in `builds`.
String get currentPlatform {
  if (Platform.isAndroid) return 'android';
  if (Platform.isIOS) return 'ios';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isWindows) return 'windows-x64';
  if (Platform.isLinux) return 'linux-x64';
  return 'other';
}

/// What a downloaded file is, for the words shown to the user.
String installHint(String fileName) {
  final n = fileName.toLowerCase();
  if (n.endsWith('.apk')) return 'Open it to install the new version.';
  if (n.endsWith('.dmg')) return 'Open the disk image and drag minerfan to Applications.';
  if (n.endsWith('.zip')) return 'Unpack it over the folder minerfan runs from, with minerfan closed.';
  if (n.endsWith('.tar.gz')) {
    return 'Unpack it and put the minerfan folder in place of the old one, with minerfan closed.';
  }
  return 'Open it to install the new version.';
}
