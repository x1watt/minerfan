import 'dart:async';
import 'dart:typed_data';

import 'package:net_core/net_core.dart';

import 'bytes.dart';
import 'params.dart';
import 'wire.dart';

/// One P2P connection: handshake, pings, and the messages it receives.
class Peer {
  final ChainParams params;
  final Connection _conn;
  final WireCodec _codec;
  final StreamController<WireMessage> _messages = StreamController.broadcast();
  final Completer<void> _ready = Completer();
  final Completer<void> _closed = Completer();
  StreamSubscription<Uint8List>? _sub;

  int version = 0;
  int services = 0;
  int startHeight = 0;
  String userAgent = '';
  int lastActiveMs = DateTime.now().millisecondsSinceEpoch;

  Peer._(this.params, this._conn) : _codec = WireCodec(params.magic);

  String get address => '${_conn.remoteHost}:${_conn.remotePort}';
  Stream<WireMessage> get messages => _messages.stream;
  Future<void> get closed => _closed.future;
  bool get isOpen => !_closed.isCompleted;

  /// Connects and completes the version handshake, or throws.
  static Future<Peer> connect(
    Transport transport,
    ChainParams params,
    String host,
    int port, {
    required int startHeight,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final conn = await transport.connect(host, port, timeout: timeout);
    final p = Peer._(params, conn);
    p._start(startHeight, host, port);
    try {
      await p._ready.future.timeout(timeout);
    } catch (e) {
      await p.close();
      rethrow;
    }
    return p;
  }

  void _start(int startHeight, String host, int port) {
    _sub = _conn.data.listen(_onData, onDone: () => close(), cancelOnError: true);
    send('version', Msg.version(
      protocolVersion: params.protocolVersion,
      userAgent: params.userAgent,
      startHeight: startHeight,
      remoteHost: host,
      remotePort: port,
    ));
  }

  void _onData(Uint8List chunk) {
    List<WireMessage> msgs;
    try {
      msgs = _codec.feed(chunk);
    } on FormatException {
      close();
      return;
    }
    lastActiveMs = DateTime.now().millisecondsSinceEpoch;
    for (final m in msgs) {
      switch (m.command) {
        case 'version':
          try {
            final v = Msg.parseVersion(m.payload);
            version = v.version;
            services = v.services;
            startHeight = v.startHeight;
            userAgent = v.userAgent;
          } on FormatException {
            close();
            return;
          }
          send('verack');
        case 'verack':
          if (!_ready.isCompleted) _ready.complete();
        case 'ping':
          send('pong', m.payload);
      }
      if (!_messages.isClosed) _messages.add(m);
    }
  }

  void send(String command, [List<int> payload = const []]) {
    if (!isOpen) return;
    _conn.add(_codec.encode(command, payload));
  }

  /// Sends a request and waits for the first matching reply.
  Future<WireMessage> request(
    String command,
    List<int> payload,
    bool Function(WireMessage) match, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final f = messages.firstWhere(match).timeout(timeout);
    send(command, payload);
    return f;
  }

  Future<void> close() async {
    if (_closed.isCompleted) return;
    _closed.complete();
    if (!_ready.isCompleted) _ready.completeError(StateError('connection to $address closed'));
    await _sub?.cancel();
    await _messages.close();
    await _conn.close();
  }

  @override
  String toString() => '$address ($userAgent, height $startHeight)';
}

/// Parses `host:port` (IPv4, a name, or `[ipv6]:port`).
(String, int) splitHostPort(String s, int defaultPort) {
  if (s.startsWith('[')) {
    final end = s.indexOf(']');
    final port = s.length > end + 2 ? int.tryParse(s.substring(end + 2)) : null;
    return (s.substring(0, end + 1), port ?? defaultPort);
  }
  final i = s.lastIndexOf(':');
  if (i < 0) return (s, defaultPort);
  return (s.substring(0, i), int.tryParse(s.substring(i + 1)) ?? defaultPort);
}

String hexOf(List<int> b) => toHex(b);
