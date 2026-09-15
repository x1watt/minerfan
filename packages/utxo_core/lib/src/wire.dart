import 'dart:math';
import 'dart:typed_data';

import 'package:crypto_core/crypto_core.dart';

import 'block.dart';
import 'bytes.dart';

/// One P2P message: its command and payload.
class WireMessage {
  final String command;
  final Uint8List payload;
  const WireMessage(this.command, this.payload);
}

/// Frames messages as `magic | command[12] | length | checksum | payload`
/// and splits a byte stream back into messages.
class WireCodec {
  final Uint8List magic;
  final BytesBuilder _buf = BytesBuilder(copy: true);
  static const maxPayload = 32 << 20;

  WireCodec(this.magic);

  Uint8List encode(String command, [List<int> payload = const []]) {
    final w = ByteWriter()..bytes(magic);
    final cmd = Uint8List(12)..setRange(0, command.length, command.codeUnits);
    w
      ..bytes(cmd)
      ..u32(payload.length)
      ..bytes(sha256d(payload).sublist(0, 4))
      ..bytes(payload);
    return w.take();
  }

  /// Messages completed by [chunk]. Throws [FormatException] on a bad
  /// frame (the caller drops the peer).
  List<WireMessage> feed(Uint8List chunk) {
    _buf.add(chunk);
    final out = <WireMessage>[];
    var data = _buf.takeBytes();
    var pos = 0;
    while (data.length - pos >= 24) {
      for (var i = 0; i < 4; i++) {
        if (data[pos + i] != magic[i]) throw const FormatException('bad magic');
      }
      final len = ByteData.sublistView(data, pos + 16, pos + 20).getUint32(0, Endian.little);
      if (len > maxPayload) throw const FormatException('message too large');
      if (data.length - pos < 24 + len) break;
      final payload = Uint8List.fromList(data.sublist(pos + 24, pos + 24 + len));
      final sum = sha256d(payload);
      for (var i = 0; i < 4; i++) {
        if (sum[i] != data[pos + 20 + i]) throw const FormatException('bad checksum');
      }
      var end = pos + 4;
      while (end < pos + 16 && data[end] != 0) {
        end++;
      }
      out.add(WireMessage(String.fromCharCodes(data.sublist(pos + 4, end)), payload));
      pos += 24 + len;
    }
    if (pos < data.length) _buf.add(data.sublist(pos));
    data = Uint8List(0);
    return out;
  }
}

/// Inventory types.
abstract final class InvType {
  static const tx = 1;
  static const block = 2;
  static const filteredBlock = 3;
}

class InvItem {
  final int type;
  final Uint8List hash;
  const InvItem(this.type, this.hash);
}

/// Payload builders and parsers of the messages the light client uses.
abstract final class Msg {
  static const nodeNetwork = 1;

  static Uint8List version({
    required int protocolVersion,
    required String userAgent,
    required int startHeight,
    String remoteHost = '0.0.0.0',
    int remotePort = 0,
    bool relay = true,
  }) {
    final w = ByteWriter()
      ..i32(protocolVersion)
      ..u64(0) // services: we serve nothing
      ..i64(DateTime.now().millisecondsSinceEpoch ~/ 1000);
    _netAddr(w, nodeNetwork, remoteHost, remotePort);
    _netAddr(w, 0, '0.0.0.0', 0);
    w
      ..u64(Random.secure().nextInt(1 << 32) << 31 ^ Random.secure().nextInt(1 << 31))
      ..varString(userAgent)
      ..i32(startHeight)
      ..u8(relay ? 1 : 0);
    return w.take();
  }

  static void _netAddr(ByteWriter w, int services, String host, int port) {
    w.u64(services);
    final ip = Uint8List(16);
    final v4 = RegExp(r'^(\d+)\.(\d+)\.(\d+)\.(\d+)$').firstMatch(host);
    if (v4 != null) {
      ip[10] = 0xff;
      ip[11] = 0xff;
      for (var i = 0; i < 4; i++) {
        ip[12 + i] = int.parse(v4.group(i + 1)!);
      }
    }
    w
      ..bytes(ip)
      ..u16be(port);
  }

  /// The peer's version message: protocol version, services, start height
  /// and user agent.
  static ({int version, int services, int startHeight, String userAgent}) parseVersion(Uint8List p) {
    final r = ByteReader(p);
    final version = r.i32();
    final services = r.u64();
    r.i64();
    r.bytes(26);
    r.bytes(26);
    r.u64();
    final ua = r.varString();
    final height = r.remaining >= 4 ? r.i32() : 0;
    return (version: version, services: services, startHeight: height, userAgent: ua);
  }

  static Uint8List getHeaders(int protocolVersion, List<Uint8List> locator, [Uint8List? stop]) {
    final w = ByteWriter()
      ..u32(protocolVersion)
      ..varInt(locator.length);
    for (final h in locator) {
      w.bytes(h);
    }
    w.bytes(stop ?? Uint8List(32));
    return w.take();
  }

  static List<BlockHeader> parseHeaders(Uint8List p) {
    final r = ByteReader(p);
    final n = r.varInt();
    final out = <BlockHeader>[];
    for (var i = 0; i < n; i++) {
      out.add(BlockHeader.read(r));
      r.varInt(); // transaction count, always 0
    }
    return out;
  }

  static Uint8List inv(List<InvItem> items) {
    final w = ByteWriter()..varInt(items.length);
    for (final i in items) {
      w
        ..u32(i.type)
        ..bytes(i.hash);
    }
    return w.take();
  }

  static List<InvItem> parseInv(Uint8List p) {
    final r = ByteReader(p);
    return [for (var i = r.varInt(); i > 0; i--) InvItem(r.u32(), r.bytes(32))];
  }

  static Uint8List ping(int nonce) => (ByteWriter()..u64(nonce)).take();

  /// Peer addresses from an `addr` message, as `host:port`.
  static List<String> parseAddr(Uint8List p) {
    final r = ByteReader(p);
    final out = <String>[];
    for (var i = r.varInt(); i > 0 && r.remaining >= 30; i--) {
      r.u32();
      r.u64();
      final ip = r.bytes(16);
      final port = r.u16be();
      final v4 = ip.sublist(0, 12).every((b) => b == 0) || (ip.sublist(0, 10).every((b) => b == 0) && ip[10] == 0xff && ip[11] == 0xff);
      if (v4) out.add('${ip[12]}.${ip[13]}.${ip[14]}.${ip[15]}:$port');
    }
    return out;
  }
}
