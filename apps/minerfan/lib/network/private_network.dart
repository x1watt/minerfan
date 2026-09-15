import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto_core/crypto_core.dart' show Sha256;
import 'package:flutter/foundation.dart';
import 'package:i2p/i2p.dart';

import 'network_keys.dart';
import 'xprs_i2p.dart';

enum PrivateNetworkState { off, starting, up, failed }

/// Blobs the node serves and fetches, as files named by their sha256
/// (base64url, no padding) under the app's data folder.
class _FileStore implements I2pContentStore {
  final Directory dir;
  _FileStore(this.dir);

  @override
  Future<Uint8List?> get(String sha256B64u) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(sha256B64u)) return null;
    final f = File('${dir.path}/$sha256B64u');
    return await f.exists() ? f.readAsBytes() : null;
  }

  @override
  Future<void> put(Uint8List bytes, String ext) async {
    final key = base64Url.encode(Sha256.hash(bytes)).replaceAll('=', '');
    await dir.create(recursive: true);
    await File('${dir.path}/$key').writeAsBytes(bytes, flush: true);
  }
}

/// This app's own I2P node (geograms/i2p-dart: pure Dart, its own isolate,
/// no router to install): NTCP2 to the public I2P network, inbound and
/// outbound tunnels, a LeaseSet in the network database, and a `.b32.i2p`
/// address that stays the same across starts. Other clients (minerfan and
/// xprs) reach this device there with XPRS packets ([link]), signed with
/// this device's station key and sealed to their recipient. The coins' chat
/// rooms travel on it too ([RoomService] in rooms.dart).
class PrivateNetwork extends ChangeNotifier {
  final String dataDir;
  I2pService? _service;
  PrivateNetworkState state = PrivateNetworkState.off;
  String? _address;
  DateTime? upSince;
  final List<String> log = [];
  NetworkKeys? _keys;
  XprsI2pLink? _link;

  /// Inbound tunnel gateways the node reported when it came up.
  int gateways = 0;

  /// Whether the last start used the routers saved by an earlier run.
  bool fromCache = false;

  PrivateNetwork(this.dataDir);

  /// Our address, `<52 chars>.b32.i2p`, while up.
  String? get address => _address;

  /// This device's XPRS station (callsign and npub), once loaded.
  XprsStation? get station => _keys?.station;

  /// XPRS packets over I2P, while up.
  XprsI2pLink? get link => _link;

  /// Counts how many times the node came up: a new start is a new node,
  /// so anything registered with the old one (shared destinations, message
  /// listeners) must be registered again.
  int generation = 0;

  /// Application messages arriving at this node (all ports), while up.
  Stream<I2pMessage>? get messages => _service?.messages;

  /// Sends raw bytes to [b32] on [port]; false while the node is down.
  Future<bool> sendRaw(String b32, int port, Uint8List bytes) async => await _service?.send(b32, port, bytes) ?? false;

  /// Answers for a shared destination too (a chat room's meeting address).
  Future<String?> addShared(Uint8List encSeed, Uint8List signSeed) async =>
      _service?.addSharedDestination(encSeed, signSeed);

  /// Stops answering for a shared destination.
  Future<void> removeShared(String b32) async => _service?.removeSharedDestination(b32);

  /// Adds a line to the network log (the rooms write theirs here).
  void note(String line) => _log(line);

  Future<NetworkKeys>? _loading;

  /// This device's station key and I2P seeds, loaded (or made) once: file
  /// reads, a device-key unseal and curve math, so off the UI isolate. The
  /// contacts' own card is signed with the same station key.
  Future<NetworkKeys> keys() {
    return _loading ??= _loadKeys(dataDir).then((k) {
      _keys = k;
      k.notes.forEach(_log);
      k.notes.clear();
      notifyListeners();
      return k;
    }, onError: (Object e) {
      _loading = null;
      throw e;
    });
  }

  // Its own function: an Isolate.run closure sharing a scope with the
  // callbacks above would carry `this` along and could not be sent.
  static Future<NetworkKeys> _loadKeys(String dir) => Isolate.run(() => NetworkKeys.loadOrCreate(dir));

  void _log(String line) {
    final stamped = '${DateTime.now().toIso8601String().substring(11, 19)} $line';
    // Also on the console (logcat on Android), where a whole run can be read.
    debugPrint('network: $stamped');
    log.add(stamped);
    if (log.length > 300) log.removeRange(0, log.length - 300);
    final m = RegExp(r'up with (\d+) gateway').firstMatch(line);
    if (m != null) gateways = int.parse(m.group(1)!);
    if (line.contains('routers from cache')) fromCache = true;
    notifyListeners();
  }

  /// Joins the I2P network: about a minute on a desktop the first time
  /// (reseed over HTTPS, then tunnels), faster later from the saved routers.
  Future<void> start() async {
    if (state == PrivateNetworkState.starting || state == PrivateNetworkState.up) return;
    state = PrivateNetworkState.starting;
    gateways = 0;
    fromCache = false;
    notifyListeners();
    NetworkKeys keys;
    try {
      keys = await this.keys();
    } catch (e) {
      _log('keys: $e');
      state = PrivateNetworkState.failed;
      notifyListeners();
      return;
    }
    // A new service per start: the worker isolate is not reused after stop.
    final s = _service = I2pService(
      store: _FileStore(Directory('$dataDir/i2p/content')),
      log: _log,
      identity: keys.i2pIdentity,
      stateDir: '$dataDir/i2p/state',
    );
    bool up;
    try {
      up = await s.ensureStarted();
    } catch (e) {
      _log('start failed: $e');
      up = false;
    }
    if (_service != s) return; // stopped meanwhile
    if (up) {
      _address = s.b32;
      upSince = DateTime.now();
      _link = XprsI2pLink(s.messages, s.send, keys.station, log: _log);
      generation++;
      state = PrivateNetworkState.up;
    } else {
      state = PrivateNetworkState.failed;
      s.stop();
      _service = null;
    }
    notifyListeners();
  }

  void stop() {
    final s = _service;
    _service = null;
    _link?.close();
    _link = null;
    s?.stop();
    _address = null;
    upSince = null;
    gateways = 0;
    state = PrivateNetworkState.off;
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
