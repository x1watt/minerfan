import 'dart:io';
import 'dart:typed_data';

import 'transport.dart';

/// [Transport] over `dart:io` TCP sockets (all native platforms).
class IoTransport implements Transport {
  @override
  Future<Connection> connect(String host, int port, {Duration timeout = const Duration(seconds: 10)}) async {
    final addr = host.startsWith('[') ? host.substring(1, host.length - 1) : host;
    final s = await Socket.connect(addr, port, timeout: timeout);
    s.setOption(SocketOption.tcpNoDelay, true);
    return _IoConnection(s, host, port);
  }

  @override
  Future<List<String>> resolve(String host) async {
    try {
      final list = await InternetAddress.lookup(host);
      return [for (final a in list) a.type == InternetAddressType.IPv6 ? '[${a.address}]' : a.address];
    } catch (_) {
      return const [];
    }
  }
}

class _IoConnection implements Connection {
  final Socket _s;
  @override
  final String remoteHost;
  @override
  final int remotePort;

  _IoConnection(this._s, this.remoteHost, this.remotePort) {
    // Write failures (connection reset) complete `done` with an error; left
    // unobserved they are uncaught and end the isolate. A failed socket also
    // closes its data stream, which is how callers learn about it.
    _s.done.ignore();
  }

  /// Read errors end the stream like a normal close.
  @override
  late final Stream<Uint8List> data = _s.handleError((Object _) {});

  @override
  void add(Uint8List bytes) {
    try {
      _s.add(bytes);
    } catch (_) {}
  }

  @override
  Future<void> close() async {
    _s.destroy();
  }
}
