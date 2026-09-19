// Noticing a new version, and fetching it without getting in the way.
//
// The app asks the project's page for a small JSON file (update_manifest)
// once a day, and says so with a line the user can dismiss. Downloading
// is the user's choice; it runs in the background, survives a restart and
// picks up where it stopped (HTTP Range), and the file is checked against
// the checksum the site published before it is offered for installing.
//
// Nothing about the address is fixed in the app beyond a starting point:
// the manifest can send the next check elsewhere, and the user can type
// another address in Settings.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto_core/crypto_core.dart' show Sha256;
import 'package:flutter/foundation.dart';

import 'update_manifest.dart';
import 'version.dart';

/// Where the app looks the first time, when nothing else is set. The
/// manifest can move the check elsewhere and the user can change it.
const defaultUpdateUrl = String.fromEnvironment(
  'UPDATE_URL',
  defaultValue: 'https://x1watt.github.io/minerfan/update.json',
);

/// What the updater is doing.
enum UpdateState {
  /// Nothing to say: this build is the newest the site knows.
  current,
  checking,

  /// A newer version exists and nothing is downloading.
  available,
  downloading,

  /// Downloading stopped part way; the bytes are kept.
  paused,

  /// Downloaded and checked: ready for the user to install.
  ready,
  failed,
}

/// Checks for a new version and fetches it when asked.
class Updater extends ChangeNotifier {
  final String dataDir;

  /// Where the next check goes. Starts at [defaultUpdateUrl]; the site
  /// or the user can move it.
  String url;

  /// What this build is, overridden in tests.
  final String current;

  /// Made once so tests can point it at a local server.
  final HttpClient Function() _client;

  Updater(
    this.dataDir, {
    String? url,
    this.current = appVersion,
    HttpClient Function()? client,
  })  : url = url ?? defaultUpdateUrl,
        _client = client ?? (() => HttpClient()..connectionTimeout = const Duration(seconds: 15));

  UpdateState state = UpdateState.current;
  UpdateManifest? manifest;

  /// Bytes fetched and the whole size, while downloading.
  int received = 0;
  int total = 0;

  String? error;

  /// The version the user said to leave alone.
  String? skipped;

  /// When the site was last asked.
  DateTime? lastCheck;

  /// The finished file, once it is checked.
  String? readyFile;

  bool _busy = false;
  bool _stop = false;

  File get _stateFile => File('$dataDir/update/state.json');
  String get _dir => '$dataDir/update';

  /// The version on offer, when it is newer than this build and the user
  /// has not waved it away.
  String? get newVersion {
    final m = manifest;
    if (m == null || !isNewerVersion(m.version, current)) return null;
    return m.version;
  }

  /// Whether the screens should say something.
  bool get shows => newVersion != null && (state != UpdateState.current) && skipped != newVersion;

  double get progress => total <= 0 ? 0 : (received / total).clamp(0, 1);

  /// Reads what was going on before the app was last closed.
  Future<void> load() async {
    try {
      if (!await _stateFile.exists()) return;
      final m = (jsonDecode(await _stateFile.readAsString()) as Map).cast<String, Object?>();
      url = '${m['url'] ?? url}';
      skipped = m['skipped'] as String?;
      final at = m['lastCheck'];
      if (at is num) lastCheck = DateTime.fromMillisecondsSinceEpoch(at.toInt());
      final text = m['manifest'];
      if (text is String) manifest = UpdateManifest.parse(text);
      final ready = m['readyFile'] as String?;
      if (ready != null && await File(ready).exists()) {
        readyFile = ready;
        state = UpdateState.ready;
      } else if (newVersion != null) {
        // A part file means a download to pick up again.
        final part = await _partOf(manifest?.mine);
        state = part != null && await part.exists() ? UpdateState.paused : UpdateState.available;
        if (part != null && await part.exists()) {
          received = await part.length();
          total = manifest?.mine?.size ?? 0;
        }
      }
      notifyListeners();
    } catch (e) {
      debugPrint('update: $e');
    }
  }

  Future<void> _save() async {
    try {
      await Directory(_dir).create(recursive: true);
      final tmp = File('${_stateFile.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({
          'url': url,
          if (skipped != null) 'skipped': skipped,
          if (lastCheck != null) 'lastCheck': lastCheck!.millisecondsSinceEpoch,
          if (_manifestText != null) 'manifest': _manifestText,
          if (readyFile != null) 'readyFile': readyFile,
        }),
        flush: true,
      );
      await tmp.rename(_stateFile.path);
    } catch (e) {
      debugPrint('update: $e');
    }
  }

  String? _manifestText;

  /// Asks the site, at most once a day unless [force].
  Future<void> check({bool force = false}) async {
    if (_busy || state == UpdateState.downloading) return;
    if (!force && lastCheck != null && DateTime.now().difference(lastCheck!) < const Duration(hours: 24)) return;
    _busy = true;
    if (state != UpdateState.ready) state = UpdateState.checking;
    error = null;
    notifyListeners();
    try {
      // One hop only, so a moved manifest cannot send the app in circles.
      var text = await _get(url);
      var parsed = UpdateManifest.parse(text);
      final next = parsed?.next;
      if (next != null && next != url) {
        try {
          final moved = await _get(next);
          final m2 = UpdateManifest.parse(moved);
          if (m2 != null) {
            url = next;
            text = moved;
            parsed = m2;
          }
        } catch (_) {
          // The old address still answered: keep using it this time.
        }
      }
      if (parsed == null) throw const FormatException('the update file could not be read');
      manifest = parsed;
      _manifestText = text;
      lastCheck = DateTime.now();
      if (state != UpdateState.ready) {
        state = newVersion == null ? UpdateState.current : UpdateState.available;
      }
      await _save();
    } catch (e) {
      error = '$e';
      if (state == UpdateState.checking) state = newVersion == null ? UpdateState.current : UpdateState.available;
      debugPrint('update: $e');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Starts or picks up the download for this machine.
  Future<void> download() async {
    final build = manifest?.mine;
    if (build == null || state == UpdateState.downloading) return;
    _stop = false;
    state = UpdateState.downloading;
    error = null;
    notifyListeners();
    IOSink? sink;
    try {
      await Directory(_dir).create(recursive: true);
      final part = File('$_dir/${build.fileName}.part');
      var have = await part.exists() ? await part.length() : 0;
      final client = _client();
      final request = await client.getUrl(Uri.parse(build.url));
      if (have > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
      final response = await request.close();
      if (response.statusCode == HttpStatus.ok && have > 0) {
        // The server ignored the range: start over rather than mix bytes.
        have = 0;
      } else if (response.statusCode != HttpStatus.ok && response.statusCode != HttpStatus.partialContent) {
        throw HttpException('the download answered ${response.statusCode}');
      }
      total = (response.contentLength > 0 ? response.contentLength + have : build.size ?? 0);
      received = have;
      sink = part.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
      var since = DateTime.now();
      await for (final chunk in response) {
        if (_stop) break;
        sink.add(chunk);
        received += chunk.length;
        // The screen does not need every packet.
        if (DateTime.now().difference(since) > const Duration(milliseconds: 250)) {
          since = DateTime.now();
          notifyListeners();
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      client.close();
      if (_stop) {
        state = UpdateState.paused;
        notifyListeners();
        return;
      }
      final done = File('$_dir/${build.fileName}');
      if (await done.exists()) await done.delete();
      await part.rename(done.path);

      final sum = build.sha256;
      if (sum != null) {
        final got = await _sha256File(done.path);
        if (got != sum) {
          await done.delete();
          received = 0;
          throw const FormatException('the downloaded file does not match the checksum on the site');
        }
      }
      readyFile = done.path;
      state = UpdateState.ready;
      await _save();
    } catch (e) {
      try {
        await sink?.close();
      } catch (_) {}
      error = '$e';
      state = UpdateState.paused;
      debugPrint('update: $e');
    } finally {
      notifyListeners();
    }
  }

  /// Stops the download, keeping what came in.
  void pause() {
    if (state != UpdateState.downloading) return;
    _stop = true;
  }

  /// Forgets this version until a newer one appears.
  Future<void> skip() async {
    skipped = newVersion;
    await _save();
    notifyListeners();
  }

  /// Throws away a download (the part file and the finished one).
  Future<void> discard() async {
    final build = manifest?.mine;
    for (final f in [
      if (build != null) File('$_dir/${build.fileName}.part'),
      if (build != null) File('$_dir/${build.fileName}'),
      if (readyFile != null) File(readyFile!),
    ]) {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    readyFile = null;
    received = 0;
    state = newVersion == null ? UpdateState.current : UpdateState.available;
    await _save();
    notifyListeners();
  }

  /// Points the check somewhere else (Settings).
  Future<void> setUrl(String v) async {
    final next = v.trim();
    if (next.isEmpty || next == url) return;
    url = next;
    manifest = null;
    _manifestText = null;
    lastCheck = null;
    state = UpdateState.current;
    await _save();
    notifyListeners();
    await check(force: true);
  }

  Future<File?> _partOf(UpdateBuild? build) async =>
      build == null ? null : File('$_dir/${build.fileName}.part');

  Future<String> _get(String address) async {
    final client = _client();
    try {
      final r = await client.getUrl(Uri.parse(address));
      r.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await r.close();
      if (response.statusCode != HttpStatus.ok) throw HttpException('the site answered ${response.statusCode}');
      return await response.transform(utf8.decoder).join();
    } finally {
      client.close();
    }
  }
}

// Hashing a hundred megabytes is not for the UI isolate, and a top-level
// function keeps the closure down to the path.
Future<String> _sha256File(String path) => Isolate.run(() async {
      final digest = Sha256();
      // A megabyte at a time: a release is tens of megabytes and none of
      // it needs to be held at once.
      await for (final chunk in File(path).openRead()) {
        digest.update(chunk);
      }
      return _hex(digest.digest());
    });

String _hex(List<int> b) => [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
