import 'dart:collection';
import 'dart:typed_data';

import '../util/bytes.dart';
import '../util/reader.dart';

/// Levin packet framing (contrib/epee/include/net/levin_base.h).
///
/// Every packet is a fixed 33-byte little-endian `bucket_head2` followed by
/// `cb` body bytes. Integers are packed with no padding (#pragma pack(1)).

/// `LEVIN_SIGNATURE` (levin_base.h:39), "Bender's nightmare".
const int levinSignature = 0x0101010101012101;

/// sizeof(bucket_head2): u64 + u64 + u8 + u32 + i32 + u32 + u32.
const int levinHeaderSize = 33;

/// `LEVIN_INITIAL_MAX_PACKET_SIZE` (levin_base.h:63), before the handshake.
const int levinInitialMaxPacketSize = 256 * 1024;

/// `LEVIN_DEFAULT_MAX_PACKET_SIZE` (levin_base.h:64), after the handshake.
const int levinDefaultMaxPacketSize = 100000000;

// Header flags (levin_base.h:66-69).
const int levinPacketRequest = 0x01;
const int levinPacketResponse = 0x02;
const int levinPacketBegin = 0x04;
const int levinPacketEnd = 0x08;

/// `LEVIN_PROTOCOL_VER_1` (levin_base.h:72).
const int levinProtocolVersion1 = 1;

// Return codes (levin_base.h:88-95). Command handlers in monerod return 1 on
// success and the invoking side treats any code <= 0 as a failure
// (levin_abstract_invoke2.h, async_invoke_remote_command2).
const int levinOk = 0;
const int levinErrorConnection = -1;
const int levinErrorConnectionNotFound = -2;
const int levinErrorConnectionDestroyed = -3;
const int levinErrorConnectionTimedOut = -4;
const int levinErrorConnectionNoDuplexProtocol = -5;
const int levinErrorConnectionHandlerNotDefined = -6;
const int levinErrorFormat = -7;

/// Per-command body size cap, mirroring
/// `cryptonote_connection_context::get_max_bytes`
/// (src/cryptonote_basic/connection_context.cpp:36). Returns null when the
/// command has no specific cap.
int? levinMaxBytesForCommand(int command) {
  switch (command) {
    case 1001: // COMMAND_HANDSHAKE
    case 1002: // COMMAND_TIMED_SYNC
      return 65536;
    case 1003: // COMMAND_PING
    case 1007: // COMMAND_REQUEST_SUPPORT_FLAGS
      return 4096;
    case 2001: // NOTIFY_NEW_BLOCK
    case 2002: // NOTIFY_NEW_TRANSACTIONS
    case 2004: // NOTIFY_RESPONSE_GET_OBJECTS
      return 128 * 1024 * 1024;
    case 2003: // NOTIFY_REQUEST_GET_OBJECTS
      return 2 * 1024 * 1024;
    case 2006: // NOTIFY_REQUEST_CHAIN
      return 512 * 1024;
    case 2007: // NOTIFY_RESPONSE_CHAIN_ENTRY
    case 2008: // NOTIFY_NEW_FLUFFY_BLOCK
    case 2010: // NOTIFY_GET_TXPOOL_COMPLEMENT
      return 4 * 1024 * 1024;
    case 2009: // NOTIFY_REQUEST_FLUFFY_MISSING_TX
      return 1024 * 1024;
    default:
      return null;
  }
}

/// One `bucket_head2`.
class LevinHeader {
  /// Body size in bytes (`m_cb`).
  final int bodySize;

  /// `m_have_to_return_data`: true for an invoke that expects a response.
  final bool expectResponse;
  final int command;
  final int returnCode;
  final int flags;
  final int protocolVersion;

  const LevinHeader({
    required this.bodySize,
    required this.expectResponse,
    required this.command,
    this.returnCode = 0,
    required this.flags,
    this.protocolVersion = levinProtocolVersion1,
  });

  bool get isRequest => (flags & levinPacketRequest) != 0;
  bool get isResponse => (flags & levinPacketResponse) != 0;

  /// Noise or fragment packet: neither REQUEST nor RESPONSE is set.
  bool get isFragmentOrNoise => (flags & (levinPacketRequest | levinPacketResponse)) == 0;

  Uint8List encode() {
    final out = Uint8List(levinHeaderSize);
    writeU64LE(out, 0, levinSignature);
    writeU64LE(out, 8, bodySize);
    out[16] = expectResponse ? 1 : 0;
    writeU32LE(out, 17, command);
    writeU32LE(out, 21, returnCode);
    writeU32LE(out, 25, flags);
    writeU32LE(out, 29, protocolVersion);
    return out;
  }

  /// Decodes a header at [offset]; throws [FormatError] on a short buffer or
  /// a bad signature.
  static LevinHeader decode(List<int> data, [int offset = 0]) {
    if (data.length - offset < levinHeaderSize) {
      throw FormatError('levin header needs $levinHeaderSize bytes');
    }
    if (readU64LE(data, offset) != levinSignature) {
      throw FormatError('levin signature mismatch');
    }
    final cb = readU64LE(data, offset + 8);
    if (cb < 0) throw FormatError('levin body size overflows');
    final ret = data[offset + 16];
    return LevinHeader(
      bodySize: cb,
      expectResponse: ret != 0,
      command: readU32LE(data, offset + 17),
      returnCode: readU32LE(data, offset + 21).toSigned(32),
      flags: readU32LE(data, offset + 25),
      protocolVersion: readU32LE(data, offset + 29),
    );
  }

  @override
  String toString() =>
      'LevinHeader(cmd=$command, cb=$bodySize, ret=$returnCode, flags=$flags, r?=$expectResponse, v=$protocolVersion)';
}

/// A complete levin packet.
class LevinPacket {
  final LevinHeader header;
  final Uint8List body;

  const LevinPacket(this.header, this.body);

  int get command => header.command;
}

/// Builds a full packet (header plus body).
Uint8List encodeLevinPacket({
  required int command,
  required Uint8List body,
  required int flags,
  bool expectResponse = false,
  int returnCode = 0,
}) {
  final h = LevinHeader(
    bodySize: body.length,
    expectResponse: expectResponse,
    command: command,
    returnCode: returnCode,
    flags: flags,
  );
  return concatBytes([h.encode(), body]);
}

/// An invoke (request that expects a response), `finalize_invoke`.
Uint8List encodeLevinInvoke(int command, Uint8List body) =>
    encodeLevinPacket(command: command, body: body, flags: levinPacketRequest, expectResponse: true);

/// A notification (request without response), `finalize_notify`.
Uint8List encodeLevinNotify(int command, Uint8List body) =>
    encodeLevinPacket(command: command, body: body, flags: levinPacketRequest);

/// A response to an invoke, `finalize_response`.
Uint8List encodeLevinResponse(int command, Uint8List body, int returnCode) =>
    encodeLevinPacket(command: command, body: body, flags: levinPacketResponse, returnCode: returnCode);

/// Incremental packet splitter. Feed arbitrary chunks with [add] and pull
/// complete packets with [next]. Mirrors the receive loop of
/// `async_protocol_handler::handle_recv`
/// (contrib/epee/include/net/levin_protocol_handler_async.h:412): the
/// signature is checked as soon as 8 bytes are buffered, the body size is
/// checked against [maxPacketSize] and the per-command cap, noise packets
/// (BEGIN|END without REQUEST/RESPONSE) are dropped and fragmented packets are
/// reassembled into the inner packet they carry.
///
/// Errors throw [FormatError]; the connection must then be closed.
class LevinDeframer {
  /// Current body size limit; raise it to [levinDefaultMaxPacketSize] once the
  /// handshake has completed.
  int maxPacketSize;

  /// Whether to apply [levinMaxBytesForCommand] on top of [maxPacketSize].
  final bool perCommandLimits;

  final ListQueue<Uint8List> _chunks = ListQueue();
  int _headOffset = 0; // consumed bytes of _chunks.first
  int _buffered = 0;
  LevinHeader? _pending;
  final BytesBuilder _fragment = BytesBuilder(copy: true);

  LevinDeframer({this.maxPacketSize = levinInitialMaxPacketSize, this.perCommandLimits = true});

  /// Bytes buffered but not yet returned as packets.
  int get bufferedBytes => _buffered + _fragment.length;

  /// Appends received bytes. Throws [FormatError] as soon as the first 8
  /// bytes of a header do not carry the levin signature. Size limits are
  /// checked when a header is decoded by [next]; callers should drain packets
  /// after each chunk so at most one partial packet stays buffered.
  void add(List<int> chunk) {
    if (chunk.isEmpty) return;
    _chunks.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
    _buffered += chunk.length;
    if (_pending == null && _buffered >= 8) {
      final sig = _peek(8);
      if (readU64LE(sig, 0) != levinSignature) throw FormatError('levin signature mismatch');
    }
  }

  /// Convenience: [add] then drain every complete packet.
  List<LevinPacket> feed(List<int> chunk) {
    add(chunk);
    final out = <LevinPacket>[];
    for (var p = next(); p != null; p = next()) {
      out.add(p);
    }
    return out;
  }

  /// Returns the next complete packet, or null when more bytes are needed.
  LevinPacket? next() {
    while (true) {
      if (_pending == null) {
        if (_buffered < levinHeaderSize) {
          if (_buffered >= 8 && readU64LE(_peek(8), 0) != levinSignature) {
            throw FormatError('levin signature mismatch');
          }
          return null;
        }
        final h = LevinHeader.decode(_take(levinHeaderSize));
        _checkSize(h, h.bodySize);
        _pending = h;
      }
      final h = _pending!;
      if (_buffered < h.bodySize) return null;
      final body = _take(h.bodySize);
      _pending = null;
      if (!h.isFragmentOrNoise) return LevinPacket(h, body);

      // Noise and fragments (levin_protocol_handler_async.h:470-513).
      const both = levinPacketBegin | levinPacketEnd;
      if ((h.flags & both) == both) continue; // noise, skip
      if ((h.flags & levinPacketBegin) != 0) _fragment.clear();
      if (_fragment.length + body.length > maxPacketSize + levinHeaderSize) {
        throw FormatError('fragmented levin message too large');
      }
      _fragment.add(body);
      if ((h.flags & levinPacketEnd) == 0) continue;
      final whole = _fragment.takeBytes();
      if (whole.length < levinHeaderSize) throw FormatError('fragmented data too small for levin header');
      final inner = LevinHeader.decode(whole);
      if (whole.length - levinHeaderSize < inner.bodySize) {
        throw FormatError('invalid fragmented buffer size');
      }
      _checkSize(inner, inner.bodySize);
      if (inner.isFragmentOrNoise) throw FormatError('nested levin fragment');
      return LevinPacket(
        inner,
        Uint8List.fromList(Uint8List.sublistView(whole, levinHeaderSize, levinHeaderSize + inner.bodySize)),
      );
    }
  }

  void _checkSize(LevinHeader h, int size) {
    var limit = maxPacketSize;
    if (perCommandLimits && !h.isFragmentOrNoise) {
      final c = levinMaxBytesForCommand(h.command);
      if (c != null && c < limit) limit = c;
    }
    if (size > limit) {
      throw FormatError('levin packet too large: $size > $limit (command ${h.command})');
    }
  }

  /// Copies the first [n] buffered bytes without consuming them.
  Uint8List _peek(int n) {
    final out = Uint8List(n);
    var o = 0;
    var off = _headOffset;
    for (final c in _chunks) {
      final k = (c.length - off) < (n - o) ? c.length - off : n - o;
      out.setRange(o, o + k, c, off);
      o += k;
      off = 0;
      if (o == n) break;
    }
    return out;
  }

  /// Removes and returns the first [n] buffered bytes.
  Uint8List _take(int n) {
    final first = _chunks.isEmpty ? null : _chunks.first;
    if (first != null && _headOffset == 0 && first.length == n) {
      _chunks.removeFirst();
      _buffered -= n;
      return first;
    }
    final out = Uint8List(n);
    var o = 0;
    while (o < n) {
      final c = _chunks.first;
      final avail = c.length - _headOffset;
      final k = avail < n - o ? avail : n - o;
      out.setRange(o, o + k, c, _headOffset);
      o += k;
      _headOffset += k;
      if (_headOffset == c.length) {
        _chunks.removeFirst();
        _headOffset = 0;
      }
    }
    _buffered -= n;
    return out;
  }
}
