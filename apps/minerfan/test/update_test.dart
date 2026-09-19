import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto_core/crypto_core.dart' show Sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:minerfan/update/update_manifest.dart';
import 'package:minerfan/update/updater.dart';
import 'package:minerfan/update/version.dart';

/// A stand-in for the project's page: serves the manifest and the file,
/// understands Range, and can cut the connection part way to prove the
/// download picks up again.
class FakeSite {
  late HttpServer server;
  late Uint8List payload;
  String manifest = '';

  /// Bytes to send before dropping the connection, or null to serve all.
  int? cutAfter;
  int downloads = 0;
  final ranges = <String>[];

  Future<void> start({int size = 200000}) async {
    payload = Uint8List.fromList(List.generate(size, (i) => (i * 31 + 7) % 251));
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      if (r.uri.path == '/update.json') {
        r.response.headers.contentType = ContentType.json;
        r.response.write(manifest);
        await r.response.close();
        return;
      }
      if (r.uri.path == '/app.bin') {
        downloads++;
        var from = 0;
        final range = r.headers.value(HttpHeaders.rangeHeader);
        if (range != null) {
          ranges.add(range);
          from = int.tryParse(RegExp(r'bytes=(\d+)-').firstMatch(range)?.group(1) ?? '0') ?? 0;
          r.response.statusCode = HttpStatus.partialContent;
          r.response.headers.set(
              HttpHeaders.contentRangeHeader, 'bytes $from-${payload.length - 1}/${payload.length}');
        }
        final rest = payload.sublist(from);
        final cut = cutAfter;
        if (cut != null && cut < rest.length) {
          // A real broken transfer: promise the whole length, send part
          // of it, then pull the socket out.
          final socket = await r.response.detachSocket(writeHeaders: false);
          socket.add(utf8.encode([
            'HTTP/1.1 ${from > 0 ? '206 Partial Content' : '200 OK'}',
            'Content-Length: ${rest.length}',
            if (from > 0) 'Content-Range: bytes $from-${payload.length - 1}/${payload.length}',
            '',
            '',
          ].join('\r\n')));
          socket.add(rest.sublist(0, cut));
          await socket.flush();
          socket.destroy();
          return;
        }
        r.response.add(rest);
        await r.response.close();
        return;
      }
      r.response.statusCode = HttpStatus.notFound;
      await r.response.close();
    });
  }

  String get base => 'http://${server.address.address}:${server.port}';
  Future<void> stop() async => server.close(force: true);
}

String manifestJson({
  required String base,
  String version = '9.9.9',
  String? sha256,
  int? size,
  String? next,
}) =>
    jsonEncode({
      'app': 'minerfan',
      'version': version,
      'notes': 'Coffee shops and faster blocks',
      'page': '$base/',
      ?next == null ? null : 'next': next,
      'builds': {
        currentPlatform: {
          'url': '$base/app.bin',
          'file': 'app.bin',
          ?size == null ? null : 'size': size,
          ?sha256 == null ? null : 'sha256': sha256,
        },
      },
    });

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('update'));
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('versions compare the way releases do', () {
    expect(isNewerVersion('0.2.3', '0.2.2'), isTrue);
    expect(isNewerVersion('0.3.0', '0.2.9'), isTrue);
    expect(isNewerVersion('1.0.0', '0.9.9'), isTrue);
    expect(isNewerVersion('0.2.2', '0.2.2'), isFalse);
    expect(isNewerVersion('0.2.1', '0.2.2'), isFalse);
    expect(isNewerVersion('v0.2.3', '0.2.2'), isTrue, reason: 'a tag with its v');
    expect(isNewerVersion('0.2.3+4', '0.2.3+3'), isFalse, reason: 'the build number is not the release');
    expect(isNewerVersion('1.0.0', '1.0.0-beta.1'), isTrue);
    expect(isNewerVersion('1.0.0-beta.1', '1.0.0'), isFalse);
    expect(isNewerVersion('nonsense', '0.2.2'), isFalse);
  });

  test('this build says the same version as the pubspec', () async {
    final text = await File('pubspec.yaml').readAsString();
    final line = RegExp(r'^version:\s*(.+)$', multiLine: true).firstMatch(text)!.group(1)!.trim();
    expect(line.split('+').first, appVersion);
  });

  test('a manifest is read, and says where to look next time', () {
    final m = UpdateManifest.parse(manifestJson(base: 'https://example.test', sha256: 'a' * 64, size: 42))!;
    expect(m.app, 'minerfan');
    expect(m.version, '9.9.9');
    expect(m.mine!.url, 'https://example.test/app.bin');
    expect(m.mine!.sha256, 'a' * 64);
    expect(m.mine!.size, 42);
    expect(m.next, isNull);

    final moved = UpdateManifest.parse(manifestJson(base: 'https://example.test', next: 'https://new.test/u.json'))!;
    expect(moved.next, 'https://new.test/u.json');
    // A checksum that is not a checksum is ignored rather than trusted.
    expect(UpdateManifest.parse(manifestJson(base: 'https://e.test', sha256: 'nope'))!.mine!.sha256, isNull);
    expect(UpdateManifest.parse('{"app":"x"}'), isNull, reason: 'no version, nothing to offer');
    expect(UpdateManifest.parse('not json'), isNull);
  });

  test('a file name comes from the address when the site does not give one', () {
    final m = UpdateManifest.parse(jsonEncode({
      'version': '1.0.0',
      'builds': {
        currentPlatform: {'url': 'https://e.test/downloads/minerfan-linux-x64.tar.gz'},
      },
    }))!;
    expect(m.mine!.fileName, 'minerfan-linux-x64.tar.gz');
  });

  test('a newer version is noticed, an older one is not', () async {
    final site = FakeSite();
    await site.start();
    addTearDown(site.stop);
    site.manifest = manifestJson(base: site.base, version: '9.9.9');

    final up = Updater(tmp.path, url: '${site.base}/update.json', current: '0.2.2');
    await up.check();
    expect(up.newVersion, '9.9.9');
    expect(up.state, UpdateState.available);
    expect(up.shows, isTrue);

    // The same app, already up to date.
    final current = Updater(tmp.path, url: '${site.base}/update.json', current: '9.9.9');
    await current.check(force: true);
    expect(current.newVersion, isNull);
    expect(current.state, UpdateState.current);
    expect(current.shows, isFalse);
  });

  test('a version waved away stays quiet until a newer one turns up', () async {
    final site = FakeSite();
    await site.start();
    addTearDown(site.stop);
    site.manifest = manifestJson(base: site.base, version: '1.0.0');
    final up = Updater(tmp.path, url: '${site.base}/update.json', current: '0.2.2');
    await up.check();
    await up.skip();
    expect(up.shows, isFalse);

    site.manifest = manifestJson(base: site.base, version: '1.1.0');
    await up.check(force: true);
    expect(up.shows, isTrue, reason: 'a later version speaks up again');
  });

  test('the check follows the site when it moves', () async {
    final oldSite = FakeSite();
    final newSite = FakeSite();
    await oldSite.start();
    await newSite.start();
    addTearDown(oldSite.stop);
    addTearDown(newSite.stop);
    newSite.manifest = manifestJson(base: newSite.base, version: '2.0.0');
    oldSite.manifest = manifestJson(base: oldSite.base, version: '1.0.0', next: '${newSite.base}/update.json');

    final up = Updater(tmp.path, url: '${oldSite.base}/update.json', current: '0.2.2');
    await up.check();
    expect(up.url, '${newSite.base}/update.json', reason: 'the next check goes to the new address');
    expect(up.newVersion, '2.0.0');
  });

  test('a download that is cut off carries on from where it stopped', () async {
    final site = FakeSite();
    await site.start(size: 120000);
    addTearDown(site.stop);
    final sum = _sha256(site.payload);
    site.manifest = manifestJson(base: site.base, sha256: sum, size: site.payload.length);
    site.cutAfter = 40000;

    final up = Updater(tmp.path, url: '${site.base}/update.json', current: '0.2.2');
    await up.check();
    await up.download();
    expect(up.state, UpdateState.paused, reason: 'the connection died part way');
    final part = File('${tmp.path}/update/app.bin.part');
    expect(await part.exists(), isTrue);
    final got = await part.length();
    expect(got, greaterThan(0));
    expect(got, lessThan(site.payload.length));

    // The site comes back and the rest is fetched with a Range request.
    final again = FakeSite();
    await again.start(size: 120000);
    addTearDown(again.stop);
    again.payload = site.payload;
    again.manifest = manifestJson(base: again.base, sha256: sum, size: site.payload.length);
    up.manifest = UpdateManifest.parse(again.manifest);
    await up.download();

    expect(up.state, UpdateState.ready, reason: up.error ?? '');
    expect(again.ranges.single, 'bytes=$got-');
    final done = File('${tmp.path}/update/app.bin');
    expect(await done.readAsBytes(), site.payload, reason: 'the two halves join up exactly');
    expect(up.readyFile, done.path);
  });

  test('a file that does not match the checksum is thrown away', () async {
    final site = FakeSite();
    await site.start(size: 5000);
    addTearDown(site.stop);
    site.manifest = manifestJson(base: site.base, sha256: 'b' * 64, size: 5000);

    final up = Updater(tmp.path, url: '${site.base}/update.json', current: '0.2.2');
    await up.check();
    await up.download();
    expect(up.state, UpdateState.paused);
    expect(up.error, contains('checksum'));
    expect(await File('${tmp.path}/update/app.bin').exists(), isFalse);
  });

  test('what was going on is picked up after a restart', () async {
    final site = FakeSite();
    await site.start(size: 90000);
    addTearDown(site.stop);
    site.manifest = manifestJson(base: site.base, sha256: _sha256(site.payload), size: 90000);
    site.cutAfter = 30000;

    final up = Updater(tmp.path, url: '${site.base}/update.json', current: '0.2.2');
    await up.check();
    await up.download();
    final part = await File('${tmp.path}/update/app.bin.part').length();

    // A new app on the same folder knows there is a download to finish.
    final after = Updater(tmp.path, url: '${site.base}/update.json', current: '0.2.2');
    await after.load();
    expect(after.newVersion, '9.9.9');
    expect(after.state, UpdateState.paused);
    expect(after.received, part);
    expect(after.url, '${site.base}/update.json');
  });

  test('a download can be thrown away', () async {
    final site = FakeSite();
    await site.start(size: 4000);
    addTearDown(site.stop);
    site.manifest = manifestJson(base: site.base, sha256: _sha256(site.payload), size: 4000);
    final up = Updater(tmp.path, url: '${site.base}/update.json', current: '0.2.2');
    await up.check();
    await up.download();
    expect(up.state, UpdateState.ready);
    await up.discard();
    expect(up.state, UpdateState.available);
    expect(up.readyFile, isNull);
    expect(await File('${tmp.path}/update/app.bin').exists(), isFalse);
  });

  test('a site that is not there leaves the app alone', () async {
    final up = Updater(tmp.path, url: 'http://127.0.0.1:1/update.json', current: '0.2.2');
    await up.check();
    expect(up.state, UpdateState.current);
    expect(up.error, isNotNull);
    expect(up.shows, isFalse);
  });
}

/// The app's own hash, so the test checks what the updater checks.
String _sha256(List<int> bytes) =>
    [for (final b in Sha256.hash(bytes)) b.toRadixString(16).padLeft(2, '0')].join();
