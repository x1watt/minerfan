import 'dart:typed_data';

/// The only network seam of the node. The default implementation uses
/// `dart:io` sockets ([IoTransport]); a host (for example the xprs app) can
/// supply its own.
abstract class Transport {
  Future<Connection> connect(String host, int port, {Duration timeout = const Duration(seconds: 10)});

  /// IPv4/IPv6 addresses for [host] (A/AAAA).
  Future<List<String>> resolve(String host);
}

abstract class Connection {
  String get remoteHost;
  int get remotePort;

  /// Received bytes; completes when the connection closes.
  Stream<Uint8List> get data;

  void add(Uint8List bytes);
  Future<void> close();
}
