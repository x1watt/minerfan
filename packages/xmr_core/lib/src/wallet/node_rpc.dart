import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../levin/portable_storage.dart';
import '../util/bytes.dart';
import '../util/varint.dart';

/// A Monero node's RPC (src/rpc/core_rpc_server.cpp, BSD-3), restricted
/// mode is enough. The wallet asks it only for what the P2P protocol has no
/// message for: decoy outputs (the output distribution and ring members) and
/// the fee estimate; it also submits signed transactions to get the node's
/// verdict. It never gets keys.
class MoneroRpc {
  final Uri base;
  final Duration timeout;
  final HttpClient _http = HttpClient()..connectionTimeout = const Duration(seconds: 15);

  MoneroRpc(String url, {this.timeout = const Duration(seconds: 60)}) : base = Uri.parse(url.endsWith('/') ? url : '$url/');

  /// Public nodes the app starts with (restricted RPC); the user can pick
  /// another in the settings.
  static const defaultNodes = [
    'https://xmr-node.cakewallet.com:18081',
    'http://nodes.hashvault.pro:18081',
    'http://monero.stackwallet.com:18081',
  ];

  Future<List<int>> _post(String path, List<int> body, String type) async {
    final req = await _http.postUrl(base.resolve(path)).timeout(timeout);
    req.headers.contentType = ContentType.parse(type);
    // monerod's HTTP server does not read chunked request bodies.
    req.contentLength = body.length;
    req.add(body);
    final res = await req.close().timeout(timeout);
    final bytes = await res.fold<BytesBuilder>(BytesBuilder(copy: false), (b, d) => b..add(d)).timeout(timeout);
    if (res.statusCode != 200) throw MoneroRpcException('HTTP ${res.statusCode} from $path');
    return bytes.takeBytes();
  }

  Future<Map<String, Object?>> _json(String path, Map<String, Object?> body) async {
    final raw = await _post(path, utf8.encode(jsonEncode(body)), 'application/json');
    final m = jsonDecode(utf8.decode(raw)) as Map<String, Object?>;
    final status = m['status'];
    if (status != null && status != 'OK') throw MoneroRpcException('$path: $status ${m['reason'] ?? ''}'.trim());
    return m;
  }

  Future<Map<String, Object?>> _rpc(String method, [Map<String, Object?> params = const {}]) async {
    final m = await _json('json_rpc', {'jsonrpc': '2.0', 'id': '0', 'method': method, 'params': params});
    final err = m['error'] as Map?;
    if (err != null) throw MoneroRpcException('$method: ${err['message']}');
    final r = m['result']! as Map<String, Object?>;
    if (r['status'] != null && r['status'] != 'OK') throw MoneroRpcException('$method: ${r['status']}');
    return r;
  }

  /// Chain height (number of blocks).
  Future<int> height() async => (await _rpc('get_info'))['height']! as int;

  /// Fee per byte for the four priorities and the quantization mask.
  Future<(List<int>, int)> feeEstimate() async {
    final r = await _rpc('get_fee_estimate');
    final fees = (r['fees'] as List?)?.cast<int>() ?? [r['fee']! as int];
    return (fees, (r['quantization_mask'] as int?) ?? 1);
  }

  /// Per-block counts of RingCT outputs from [fromHeight] on (binary and
  /// compressed: one varint per block).
  Future<(int, List<int>)> outputCounts({int fromHeight = 0}) async {
    final body = encodePortableStorage({
      'amounts': const PsArray(psTypeUint64, [PsU64(0)]),
      'from_height': PsU64(fromHeight),
      'to_height': const PsU64(0),
      'cumulative': const PsBool(false),
      'binary': const PsBool(true),
      'compress': const PsBool(true),
    });
    final raw = await _post('get_output_distribution.bin', body, 'application/octet-stream');
    final m = decodePortableStorage(Uint8List.fromList(raw), limits: PsLimits.unlimited);
    final status = utf8.decode(psBytes(m, 'status') ?? const []);
    if (status != 'OK') throw MoneroRpcException('output distribution: $status');
    final d = psSectionList(m, 'distributions').single;
    final start = psInt(d, 'start_height') ?? fromHeight;
    final data = psBytes(d, 'compressed_data') ?? Uint8List(0);
    final counts = <int>[];
    var pos = 0;
    while (pos < data.length) {
      final r = readVarint(data, pos) ?? (throw MoneroRpcException('bad compressed distribution'));
      counts.add(r.$1);
      pos += r.$2;
    }
    return (start, counts);
  }

  /// Output keys and commitments by global index.
  Future<List<({Uint8List key, Uint8List mask, bool unlocked, int height})>> outputs(List<int> indices) async {
    final r = await _json('get_outs', {
      'outputs': [for (final i in indices) {'amount': 0, 'index': i}],
      'get_txid': false,
    });
    return [
      for (final o in (r['outs']! as List).cast<Map<String, Object?>>())
        (
          key: fromHex(o['key']! as String),
          mask: fromHex(o['mask']! as String),
          unlocked: o['unlocked'] == true,
          height: (o['height'] as int?) ?? 0,
        ),
    ];
  }

  /// Submits a signed transaction; throws with the node's reason when it is
  /// rejected.
  Future<void> submit(Uint8List tx) async {
    final r = await _json('send_raw_transaction', {'tx_as_hex': toHex(tx), 'do_not_relay': false});
    if (r['not_relayed'] == true) throw MoneroRpcException('the node did not relay it');
  }

  void close() => _http.close(force: true);
}

class MoneroRpcException implements Exception {
  final String message;
  MoneroRpcException(this.message);
  @override
  String toString() => message;
}

/// The cumulative RingCT output count per block (what decoy selection
/// needs), kept in a file and extended from the node as the chain grows.
class OutputDistribution {
  /// cumulative[h] = RingCT outputs in blocks 0..h.
  final List<int> cumulative;
  OutputDistribution(this.cumulative);

  int get height => cumulative.length;

  static OutputDistribution? load(File f) {
    try {
      if (!f.existsSync()) return null;
      final b = f.readAsBytesSync();
      final v = ByteData.sublistView(b);
      return OutputDistribution([for (var i = 0; i + 8 <= b.length; i += 8) v.getUint64(i, Endian.little)]);
    } catch (_) {
      return null;
    }
  }

  void save(File f) {
    final b = ByteData(cumulative.length * 8);
    for (var i = 0; i < cumulative.length; i++) {
      b.setUint64(i * 8, cumulative[i], Endian.little);
    }
    f.writeAsBytesSync(b.buffer.asUint8List());
  }

  /// Brings [known] up to the node's tip (re-fetching the last 100 blocks
  /// in case of a reorganization).
  static Future<OutputDistribution> update(MoneroRpc rpc, OutputDistribution? known) async {
    final keep = known == null ? 0 : (known.height - 100).clamp(0, known.height);
    final (start, counts) = await rpc.outputCounts(fromHeight: keep);
    final cum = known == null ? <int>[] : known.cumulative.sublist(0, start.clamp(0, keep));
    while (cum.length < start) {
      cum.add(cum.isEmpty ? 0 : cum.last);
    }
    for (final c in counts) {
      cum.add((cum.isEmpty ? 0 : cum.last) + c);
    }
    return OutputDistribution(cum);
  }
}
