import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xmr_core/src/levin/levin_frame.dart';
import 'package:xmr_core/src/levin/levin_peer.dart';
import 'package:xmr_core/src/levin/messages.dart';
import 'package:xmr_core/src/levin/portable_storage.dart';
import 'package:xmr_core/src/monero/block.dart';
import 'package:xmr_core/src/util/bytes.dart';
import 'package:xmr_core/src/util/reader.dart';

// Bodies captured from a mainnet monerod (37.187.74.171:18080).
// NOTIFY_RESPONSE_CHAIN_ENTRY for REQUEST_CHAIN [tip, genesis] at tip 3761092.
const goldenChainEntry =
    '0111010101010201011c1563756d756c61746976655f646966666963756c747905815369a0a54597091b63756d756c61746976655f'
    '646966666963756c74795f746f7036340500000000000000000b66697273745f626c6f636b0a000b6d5f626c6f636b5f6964730a80'
    '5482fce6ccec192ce8a7cdf9578f62ce61e9878673797ba5ae4c39cd54edfaea0f6d5f626c6f636b5f776569676874730a20b42e00'
    '00000000000c73746172745f68656967687405c4633900000000000c746f74616c5f68656967687405c563390000000000';

// NOTIFY_RESPONSE_GET_OBJECTS (prune=true) for block 3761090 (no txs).
const goldenGetObjects =
    '0111010101010201010806626c6f636b738c040c05626c6f636b0ae5021010dbed96d5068b7cd264c009d22fca4d37d31200fd8d79'
    'dd5acf74654bd94de35a1e8336e098e716028f02fec7e50101ffc2c7e5010180e0a596bb1103124596324cc09366f6653cb3b0b909'
    '733080359c4c9d764051ab177ae04d5d3057570321009597fc55fbda811905d7bcade73164631418448462aba3fbf68f84f39be3ab'
    '4b014235e3f9da8b6cf75c084f2fe4b74941cc7b6aac9fe72fca20fce51228909afe0211000000578fd50c00000000000000000000'
    '00000c626c6f636b5f776569676874058d00000000000000067072756e65640b011963757272656e745f626c6f636b636861696e5f'
    '68656967687405c563390000000000';

Uint8List _h(int seed) => Uint8List.fromList(List.generate(32, (i) => (seed * 31 + i * 7) & 0xff));

void main() {
  group('levin header', () {
    test('round trip and exact layout', () {
      const h = LevinHeader(bodySize: 0x1234, expectResponse: true, command: 1001, returnCode: -7, flags: 1);
      final e = h.encode();
      expect(e.length, 33);
      expect(
        toHex(e),
        '0121010101010101'
        '3412000000000000'
        '01'
        'e9030000'
        'f9ffffff'
        '01000000'
        '01000000',
      );
      final d = LevinHeader.decode(e);
      expect(d.bodySize, 0x1234);
      expect(d.expectResponse, isTrue);
      expect(d.command, 1001);
      expect(d.returnCode, -7);
      expect(d.flags, 1);
      expect(d.protocolVersion, 1);
      expect(d.isRequest, isTrue);
      expect(d.isResponse, isFalse);
    });

    test('bad signature and short buffer', () {
      final e = const LevinHeader(bodySize: 0, expectResponse: false, command: 1, flags: 1).encode();
      e[3] ^= 1;
      expect(() => LevinHeader.decode(e), throwsA(isA<FormatError>()));
      expect(() => LevinHeader.decode(Uint8List(10)), throwsA(isA<FormatError>()));
    });
  });

  group('deframer', () {
    List<Uint8List> packets() => [
      encodeLevinInvoke(1001, Uint8List.fromList(List.generate(300, (i) => i & 0xff))),
      encodeLevinNotify(2002, Uint8List(0)),
      encodeLevinResponse(1002, Uint8List.fromList([1, 2, 3]), 1),
      encodeLevinNotify(2004, Uint8List.fromList(List.generate(5000, (i) => (i * 13) & 0xff))),
    ];

    test('reassembles packets from arbitrary chunks', () {
      final all = concatBytes(packets());
      final rnd = Random(7);
      for (final maxChunk in [1, 2, 5, 33, 34, 100, 4096, all.length]) {
        final d = LevinDeframer(maxPacketSize: levinDefaultMaxPacketSize);
        final got = <LevinPacket>[];
        var o = 0;
        while (o < all.length) {
          final n = min(all.length - o, 1 + rnd.nextInt(maxChunk));
          got.addAll(d.feed(Uint8List.sublistView(all, o, o + n)));
          o += n;
        }
        expect(got.length, 4, reason: 'chunk $maxChunk');
        expect(got.map((p) => p.command), [1001, 2002, 1002, 2004]);
        expect(got[0].body.length, 300);
        expect(got[0].header.expectResponse, isTrue);
        expect(got[1].body, isEmpty);
        expect(got[2].header.isResponse, isTrue);
        expect(got[2].header.returnCode, 1);
        expect(got[3].body[4999], (4999 * 13) & 0xff);
        expect(d.bufferedBytes, 0);
      }
    });

    test('size limits', () {
      final big = encodeLevinNotify(2002, Uint8List(300 * 1024));
      final d = LevinDeframer();
      expect(() => d.feed(Uint8List.sublistView(big, 0, 40)), throwsA(isA<FormatError>()));
      // Per-command cap: a 5000-byte PING exceeds 4096.
      final ping = encodeLevinInvoke(1003, Uint8List(5000));
      expect(() => LevinDeframer(maxPacketSize: levinDefaultMaxPacketSize).feed(ping), throwsA(isA<FormatError>()));
      expect(LevinDeframer(maxPacketSize: levinDefaultMaxPacketSize, perCommandLimits: false).feed(ping).length, 1);
    });

    test('signature checked after 8 bytes', () {
      final d = LevinDeframer();
      expect(() => d.feed(Uint8List.fromList([1, 0x21, 1, 1, 1, 1, 1, 2])), throwsA(isA<FormatError>()));
    });

    test('noise is skipped and fragments are reassembled', () {
      final noise = encodeLevinPacket(command: 0, body: Uint8List(64), flags: levinPacketBegin | levinPacketEnd);
      final inner = encodeLevinNotify(2002, Uint8List.fromList(List.generate(250, (i) => i)));
      // Split like make_fragmented_notify: fragments of 100 payload bytes.
      final frags = <Uint8List>[];
      for (var o = 0; o < inner.length; o += 100) {
        final end = min(inner.length, o + 100);
        final flags = (o == 0 ? levinPacketBegin : 0) | (end == inner.length ? levinPacketEnd : 0);
        frags.add(encodePacket(Uint8List.sublistView(inner, o, end), flags));
      }
      final d = LevinDeframer();
      final got = d.feed(concatBytes([noise, ...frags, encodeLevinNotify(2001, Uint8List(1))]));
      expect(got.map((p) => p.command), [2002, 2001]);
      expect(got[0].body, List.generate(250, (i) => i));
    });
  });

  group('portable storage', () {
    test('varint boundaries', () {
      for (final (v, len) in [
        (0, 1),
        (63, 1),
        (64, 2),
        (16383, 2),
        (16384, 4),
        (1073741823, 4),
        (1073741824, 8),
        ((1 << 62) - 1, 8),
      ]) {
        final b = BytesBuilder();
        writePsVarint(b, v);
        final bytes = b.takeBytes();
        expect(bytes.length, len, reason: '$v');
        expect(bytes[0] & 3, {1: 0, 2: 1, 4: 2, 8: 3}[len]);
        expect(readPsVarint(ByteReader(bytes)), v);
      }
      expect(() => writePsVarint(BytesBuilder(), 1 << 62), throwsArgumentError);
    });

    test('all scalar types, nested sections and arrays round trip', () {
      final root = <String, Object?>{
        'i64': const PsI64(-5),
        'i32': const PsI32(-70000),
        'i16': const PsI16(-300),
        'i8': const PsI8(-2),
        'u64': const PsU64(-1), // 0xffffffffffffffff
        'u32': const PsU32(0xfedcba98),
        'u16': const PsU16(0xabcd),
        'u8': const PsU8(0xfe),
        'dbl': const PsDouble(3.25),
        'str': PsString(Uint8List.fromList([0, 1, 2, 255])),
        'empty': PsString(Uint8List(0)),
        'bool': const PsBool(true),
        'obj': {
          'inner': {'deep': const PsU8(1)},
          'x': const PsBool(false),
        },
        'a_u64': const PsArray(psTypeUint64, [PsU64(1), PsU64(-2)]),
        'a_i8': const PsArray(psTypeInt8, [PsI8(-1), PsI8(1)]),
        'a_u16': const PsArray(psTypeUint16, [PsU16(7)]),
        'a_dbl': const PsArray(psTypeDouble, [PsDouble(-0.5)]),
        'a_bool': const PsArray(psTypeBool, [PsBool(true), PsBool(false)]),
        'a_str': PsArray(psTypeString, [
          PsString(Uint8List.fromList([9])),
          PsString(Uint8List(0)),
        ]),
        'a_obj': PsArray(psTypeObject, [
          {'k': const PsU32(1)},
          <String, Object?>{},
        ]),
        'a_arr': const PsArray(psTypeArray, [
          PsArray(psTypeUint8, [PsU8(1), PsU8(2)]),
          PsArray(psTypeInt32, [PsI32(-1)]),
        ]),
        'a_empty': const PsArray(psTypeUint32, []),
      };
      final enc = encodePortableStorage(root);
      expect(toHex(enc.sublist(0, 9)), '011101010101020101');
      final dec = decodePortableStorage(enc, limits: PsLimits.unlimited);
      expect(psValueEquals(dec, root), isTrue);
      expect(dec.keys.toList(), root.keys.toList());
      expect((dec['u64'] as PsU64).value, -1);
      expect(encodePortableStorage(dec), enc);
    });

    test('plain Dart values are accepted when encoding', () {
      final enc = encodePortableStorage({
        's': 'hi',
        'b': Uint8List.fromList([1]),
        'f': true,
        'a': const PsArray(psTypeUint32, [1, 2]),
      });
      final dec = decodePortableStorage(enc);
      expect((dec['s'] as PsString).text, 'hi');
      expect(dec['a'], const PsArray(psTypeUint32, [PsU32(1), PsU32(2)]));
      expect(() => encodePortableStorage({'x': 1}), throwsArgumentError);
    });

    test('sortKeys writes std::map order', () {
      final enc = encodePortableStorage({'b': const PsU8(1), 'a': const PsU8(2), 'ab': const PsU8(3)}, sortKeys: true);
      expect(decodePortableStorage(enc).keys.toList(), ['a', 'ab', 'b']);
    });

    test('known bytes decode', () {
      // {"x": u32 5, "s": "ok", "arr": [u8 1, u8 2]}
      final bytes = fromHex(
        '011101010101020101'
        '0c'
        '0178'
        '06'
        '05000000'
        '0173'
        '0a'
        '08'
        '6f6b'
        '03617272'
        '88'
        '08'
        '0102',
      );
      final d = decodePortableStorage(bytes);
      expect(d['x'], const PsU32(5));
      expect((d['s'] as PsString).text, 'ok');
      expect(d['arr'], const PsArray(psTypeUint8, [PsU8(1), PsU8(2)]));
      // The alternative array encoding (type 13 then flagged element type).
      final alt = fromHex(
        '011101010101020101'
        '04'
        '0161'
        '0d'
        '88'
        '04'
        '07',
      );
      expect(decodePortableStorage(alt)['a'], const PsArray(psTypeUint8, [PsU8(7)]));
    });

    test('malformed input is rejected', () {
      void bad(String hex) =>
          expect(() => decodePortableStorage(fromHex(hex)), throwsA(isA<FormatError>()), reason: hex);
      bad(
        '011101010101020102'
        '00',
      ); // version
      bad(
        '011101010101020201'
        '00',
      ); // signature
      bad('011101010101020101'); // empty payload
      bad(
        '011101010101020101'
        '08'
        '0161'
        '0b01'
        '0161'
        '0b01',
      ); // duplicate key
      bad(
        '011101010101020101'
        '04'
        '0161'
        '0b02',
      ); // bool value 2
      bad(
        '011101010101020101'
        '04'
        '00'
        '0b01',
      ); // empty name
      bad(
        '011101010101020101'
        '04'
        '0161'
        '0a08'
        '41',
      ); // string past end
      bad(
        '011101010101020101'
        '04'
        '0161'
        '0e',
      ); // unknown type
      bad(
        '011101010101020101'
        '04'
        '0161'
        '85'
        'fd000000',
      ); // array sanity check
      bad(
        '011101010101020101'
        '04'
        '0161'
        '0d'
        '08',
      ); // type 13 without flag
      // Object limit.
      final many = encodePortableStorage({'a': PsArray(psTypeObject, List.generate(10, (_) => <String, Object?>{}))});
      expect(() => decodePortableStorage(many, limits: const PsLimits(maxObjects: 5)), throwsA(isA<FormatError>()));
      // Depth limit.
      Map<String, Object?> nest(int n) => n == 0 ? {} : {'n': nest(n - 1)};
      expect(() => decodePortableStorage(encodePortableStorage(nest(40))), throwsA(isA<FormatError>()));
      expect(decodePortableStorage(encodePortableStorage(nest(20))), isNotEmpty);
    });

    test('POD blob helpers', () {
      final hashes = [_h(1), _h(2), _h(3)];
      final blob = packHashes(hashes);
      expect(blob.length, 96);
      expect(unpackHashes(blob), hashes);
      expect(() => unpackHashes(Uint8List(33)), throwsA(isA<FormatError>()));
      final u = [0, 1, -1, 0x0123456789abcdef];
      final ub = packU64s(u);
      expect(toHex(ub.sublist(8, 16)), '0100000000000000');
      expect(unpackU64s(ub), u);
      expect(() => unpackU64s(Uint8List(7)), throwsA(isA<FormatError>()));
      final s = {'h': PsString(blob), 'w': PsString(ub)};
      expect(psHashList(s, 'h'), hashes);
      expect(psU64List(s, 'w'), u);
      expect(psHashList(s, 'missing'), isEmpty);
    });
  });

  group('messages', () {
    test('handshake request layout and round trip', () {
      final node = BasicNodeData(networkId: mainnetNetworkId, peerId: 0x1234567890abcdef);
      final body = HandshakeRequest(node, CoreSyncData.genesis()).encode();
      final s = decodePortableStorage(body);
      expect(s.keys.toList(), ['node_data', 'payload_data']);
      final nd = s['node_data'] as Map<String, Object?>;
      expect(nd.keys.toList(), ['my_port', 'network_id', 'peer_id', 'support_flags']);
      expect(nd['my_port'], const PsU32(0));
      expect(nd['support_flags'], const PsU32(1));
      final pd = s['payload_data'] as Map<String, Object?>;
      expect(pd.keys.toList(), [
        'cumulative_difficulty',
        'cumulative_difficulty_top64',
        'current_height',
        'top_id',
        'top_version',
      ]);
      expect(pd['top_version'], const PsU8(1));
      final back = HandshakeRequest.decode(body);
      expect(back.nodeData.peerId, 0x1234567890abcdef);
      expect(back.nodeData.networkId, mainnetNetworkId);
      expect(back.payload.topId, mainnetGenesisId);
      expect(back.payload.currentHeight, 1);
    });

    test('core sync data with 128-bit cumulative difficulty', () {
      final cd = (BigInt.from(0x1234) << 64) + BigInt.parse('fedcba9876543210', radix: 16);
      final c = CoreSyncData(
        currentHeight: 3000000,
        cumulativeDifficulty: cd,
        topId: _h(9),
        topVersion: 16,
        pruningSeed: 0x183,
      );
      final s = c.toSection();
      expect(s['cumulative_difficulty'], PsU64(BigInt.parse('fedcba9876543210', radix: 16).toSigned(64).toInt()));
      expect(s['cumulative_difficulty_top64'], const PsU64(0x1234));
      final back = CoreSyncData.fromSection(decodePortableStorage(encodePortableStorage(s)));
      expect(back.cumulativeDifficulty, cd);
      expect(back.currentHeight, 3000000);
      expect(back.topVersion, 16);
      expect(back.pruningSeed, 0x183);
      // Integer fields accept any wire width, like epee's convert_t.
      final loose = CoreSyncData.fromSection({'current_height': const PsU32(5), 'top_version': const PsU64(16)});
      expect(loose.currentHeight, 5);
      expect(loose.topVersion, 16);
    });

    test('handshake response with IPv4 and IPv6 peers', () {
      final v6 = Uint8List.fromList([0x20, 0x01, 0x0d, 0xb8, ...List.filled(11, 0), 1]);
      final peers = [
        PeerlistEntry(ip: Uint8List.fromList([192, 99, 8, 110]), port: 18080, id: 42, lastSeen: 1700000000),
        PeerlistEntry(ip: v6, port: 18089, id: -5, pruningSeed: 0x181, rpcPort: 18081),
      ];
      final rsp = HandshakeResponse(
        BasicNodeData(networkId: mainnetNetworkId, peerId: 77, myPort: 18080),
        CoreSyncData(currentHeight: 10, cumulativeDifficulty: BigInt.from(99), topId: _h(1), topVersion: 16),
        peers,
      );
      final body = rsp.encode();
      final raw = decodePortableStorage(body);
      final first = (raw['local_peerlist_new'] as PsArray).items.first as Map<String, Object?>;
      final adr = first['adr'] as Map<String, Object?>;
      expect(adr['type'], const PsU8(1));
      // First octet in the low byte of m_ip.
      expect((adr['addr'] as Map)['m_ip'], PsU32(192 | (99 << 8) | (8 << 16) | (110 << 24)));
      final back = HandshakeResponse.decode(body);
      expect(back.peers.length, 2);
      expect(back.peers[0].toString(), '192.99.8.110:18080');
      expect(back.peers[0].lastSeen, 1700000000);
      expect(back.peers[1].isIpv6, isTrue);
      expect(back.peers[1].toString(), '[2001:db8:0:0:0:0:0:1]:18089');
      expect(back.peers[1].rpcPort, 18081);
      expect(back.peers[1].id, -5);
      expect(back.nodeData.myPort, 18080);
      expect(back.payload.currentHeight, 10);
      // Unsupported address types are skipped.
      final tor = {
        'local_peerlist_new': PsArray(psTypeObject, [
          {
            'adr': {
              'type': const PsU8(4),
              'addr': {'host': 'x.onion', 'port': const PsU16(1)},
            },
            'id': const PsU64(1),
          },
        ]),
      };
      expect(parsePeerlist(tor), isEmpty);
    });

    test('timed sync, ping and support flags', () {
      final c = CoreSyncData(currentHeight: 7, cumulativeDifficulty: BigInt.from(8), topId: _h(2), topVersion: 16);
      expect(TimedSyncRequest.decode(TimedSyncRequest(c).encode()).payload.currentHeight, 7);
      final ts = TimedSyncResponse.decode(TimedSyncResponse(c).encode());
      expect(ts.payload.topId, _h(2));
      expect(ts.peers, isEmpty);
      expect(decodePortableStorage(TimedSyncResponse(c).encode()).containsKey('local_peerlist_new'), isFalse);
      final p = PingResponse.decode(PingResponse(123).encode());
      expect(p.status, 'OK');
      expect(p.peerId, 123);
      expect(SupportFlagsResponse.decode(SupportFlagsResponse(1).encode()).supportFlags, 1);
      expect(decodePortableStorage(encodeEmptySection()), isEmpty);
    });

    test('request chain and sparse history', () {
      final ids = [_h(5), _h(4), mainnetGenesisId];
      final body = RequestChain(ids, prune: true).encode();
      final s = decodePortableStorage(body);
      expect((s['block_ids'] as PsString).bytes.length, 96);
      expect(s['prune'], const PsBool(true));
      final back = RequestChain.decode(body);
      expect(back.blockIds, ids);
      expect(back.prune, isTrue);
      expect(decodePortableStorage(RequestChain(ids).encode()).containsKey('prune'), isFalse);

      final heights = <int>[];
      sparseChainHistory(100, (h) {
        heights.add(h);
        return _h(h);
      });
      expect(heights, [100, 99, 98, 97, 96, 95, 94, 93, 92, 91, 90, 88, 84, 76, 60, 28, 0]);
      final one = <int>[];
      sparseChainHistory(0, (h) {
        one.add(h);
        return _h(h);
      });
      expect(one, [0]);
    });

    test('golden RESPONSE_CHAIN_ENTRY from monerod', () {
      final body = fromHex(goldenChainEntry);
      final e = ResponseChainEntry.decode(body);
      expect(e.startHeight, 3761092);
      expect(e.totalHeight, 3761093);
      expect(e.blockIds.map(toHex), ['5482fce6ccec192ce8a7cdf9578f62ce61e9878673797ba5ae4c39cd54edfaea']);
      expect(e.blockWeights, [11956]);
      expect(e.firstBlock, isNull);
      expect(e.cumulativeDifficulty, BigInt.parse('691097645487838081'));
      // Byte-identical re-encoding.
      expect(toHex(e.encode()), goldenChainEntry);
    });

    test('golden RESPONSE_GET_OBJECTS from monerod', () {
      final body = fromHex(goldenGetObjects);
      final r = ResponseGetObjects.decode(body);
      expect(r.currentBlockchainHeight, 3761093);
      expect(r.missedIds, isEmpty);
      expect(r.blocks.length, 1);
      final e = r.blocks.first;
      expect(e.pruned, isTrue);
      expect(e.blockWeight, 141);
      expect(e.txs, isEmpty);
      final b = MoneroBlock.parse(e.block);
      expect(b.height, 3761090);
      expect(toHex(b.id()), 'b66648412727405e857aec08902725b4250d67af231e7ea1f30c6aede9a2926c');
      expect(toHex(r.encode()), goldenGetObjects);
    });

    test('get objects request and block entries (pruned and not)', () {
      final req = RequestGetObjects([_h(1), _h(2)], prune: true);
      final rb = RequestGetObjects.decode(req.encode());
      expect(rb.blocks, [_h(1), _h(2)]);
      expect(rb.prune, isTrue);

      final pruned = BlockCompleteEntry(
        block: Uint8List.fromList([1, 2, 3]),
        pruned: true,
        blockWeight: 500,
        txs: [
          TxBlobEntry(Uint8List.fromList([4]), _h(7)),
        ],
      );
      final full = BlockCompleteEntry(
        block: Uint8List.fromList([5]),
        txs: [
          TxBlobEntry(Uint8List.fromList([6, 6])),
        ],
      );
      final rsp = ResponseGetObjects(blocks: [pruned, full], missedIds: [_h(3)], currentBlockchainHeight: 1000);
      final body = rsp.encode();
      final raw = decodePortableStorage(body);
      final rawBlocks = (raw['blocks'] as PsArray).items.cast<Map<String, Object?>>();
      expect((rawBlocks[0]['txs'] as PsArray).elementType, psTypeObject);
      expect((rawBlocks[1]['txs'] as PsArray).elementType, psTypeString);
      expect(rawBlocks[1].containsKey('pruned'), isFalse);
      expect(rawBlocks[1].containsKey('block_weight'), isFalse);
      final back = ResponseGetObjects.decode(body);
      expect(back.currentBlockchainHeight, 1000);
      expect(back.missedIds, [_h(3)]);
      expect(back.blocks[0].pruned, isTrue);
      expect(back.blocks[0].blockWeight, 500);
      expect(back.blocks[0].txs.single.prunableHash, _h(7));
      expect(back.blocks[1].pruned, isFalse);
      expect(back.blocks[1].txs.single.blob, [6, 6]);
      expect(back.blocks[1].txs.single.prunableHash, isNull);
    });

    test('fluffy block, new transactions and missing tx request', () {
      final n = NewBlockNotify(
        BlockCompleteEntry(block: Uint8List.fromList([9, 9]), txs: [TxBlobEntry(Uint8List(3))]),
        55,
      );
      final nb = NewBlockNotify.decode(n.encode());
      expect(nb.b.block, [9, 9]);
      expect(nb.b.txs.length, 1);
      expect(nb.currentBlockchainHeight, 55);

      final t = NotifyNewTransactions([
        Uint8List.fromList([1]),
        Uint8List.fromList([2, 3]),
      ]);
      final raw = decodePortableStorage(t.encode());
      expect(raw['_'], PsString(Uint8List(0))); // always present
      expect(raw.containsKey('dandelionpp_fluff'), isFalse); // default true omitted
      final stem = NotifyNewTransactions.decode(
        NotifyNewTransactions([Uint8List(1)], padding: Uint8List(4), dandelionppFluff: false).encode(),
      );
      expect(stem.dandelionppFluff, isFalse);
      expect(stem.padding.length, 4);
      expect(NotifyNewTransactions.decode(t.encode()).txs, [
        [1],
        [2, 3],
      ]);

      final m = RequestFluffyMissingTx.decode(RequestFluffyMissingTx(_h(4), 77, [0, 5]).encode());
      expect(m.blockHash, _h(4));
      expect(m.currentBlockchainHeight, 77);
      expect(m.missingTxIndices, [0, 5]);
    });
  });

  group('peer state machine', () {
    /// Parses what [peer] sent into packets.
    List<LevinPacket> sent(Uint8List bytes) =>
        LevinDeframer(maxPacketSize: levinDefaultMaxPacketSize, perCommandLimits: false).feed(bytes);

    Uint8List handshakeResponse({Uint8List? networkId, int peerId = 99, int code = 1}) => encodeLevinResponse(
      cmdHandshake,
      HandshakeResponse(
        BasicNodeData(networkId: networkId ?? mainnetNetworkId, peerId: peerId, myPort: 18080),
        CoreSyncData(currentHeight: 3000001, cumulativeDifficulty: BigInt.from(5), topId: _h(8), topVersion: 16),
        [
          PeerlistEntry(ip: Uint8List.fromList([1, 2, 3, 4]), port: 18080),
        ],
      ).encode(),
      code,
    );

    LevinPeer ready() {
      final p = LevinPeer(peerId: 1);
      p.startHandshake(0);
      final ev = p.receive(handshakeResponse(), 10);
      expect(ev.single, isA<HandshakeDone>());
      return p;
    }

    test('handshake request and completion', () {
      final p = LevinPeer(peerId: 1);
      final hs = sent(p.startHandshake(0)).single;
      expect(hs.command, cmdHandshake);
      expect(hs.header.expectResponse, isTrue);
      expect(hs.header.flags, levinPacketRequest);
      final req = HandshakeRequest.decode(hs.body);
      expect(req.nodeData.myPort, 0);
      expect(req.nodeData.supportFlags, p2pSupportFlagFluffyBlocks);
      expect(req.payload.topId, mainnetGenesisId);
      final ev = p.receive(handshakeResponse(), 5);
      final done = ev.single as HandshakeDone;
      expect(done.coreSync.currentHeight, 3000001);
      expect(done.peers.single.toString(), '1.2.3.4:18080');
      expect(p.isReady, isTrue);
    });

    test('handshake failures close', () {
      for (final bad in [
        handshakeResponse(networkId: Uint8List(16)),
        handshakeResponse(peerId: 1),
        handshakeResponse(code: -1),
      ]) {
        final p = LevinPeer(peerId: 1)..startHandshake(0);
        final ev = p.receive(bad);
        expect(ev.single, isA<LevinClosed>());
        expect(p.isClosed, isTrue);
      }
      final p = LevinPeer(peerId: 1)..startHandshake(0);
      expect(p.tick(5000), isEmpty);
      expect(p.tick(20000).single, isA<LevinClosed>());
    });

    test('answers timed sync, ping and support flags; rejects stray responses', () {
      final p = ready();
      p.setLocalSync(3000001, BigInt.from(5), _h(8), 16);
      final ev = p.receive(
        concatBytes([
          encodeLevinInvoke(
            cmdTimedSync,
            TimedSyncRequest(
              CoreSyncData(currentHeight: 3000002, cumulativeDifficulty: BigInt.one, topId: _h(9), topVersion: 16),
            ).encode(),
          ),
          encodeLevinInvoke(cmdPing, encodeEmptySection()),
          encodeLevinInvoke(cmdRequestSupportFlags, encodeEmptySection()),
          encodeLevinInvoke(4242, encodeEmptySection()),
        ]),
      );
      expect((ev.first as CoreSyncUpdate).coreSync.currentHeight, 3000002);
      final out = sent(p.takeOutgoing());
      expect(out.map((x) => x.command), [cmdTimedSync, cmdPing, cmdRequestSupportFlags, 4242]);
      expect(out.every((x) => x.header.isResponse && !x.header.expectResponse), isTrue);
      expect(out.take(3).every((x) => x.header.returnCode == 1), isTrue);
      expect(out[3].header.returnCode, levinErrorConnectionHandlerNotDefined);
      final ts = TimedSyncResponse.decode(out[0].body);
      expect(ts.payload.currentHeight, 3000001);
      expect(ts.payload.topId, _h(8));
      expect(PingResponse.decode(out[1].body).peerId, 1);
      expect(SupportFlagsResponse.decode(out[2].body).supportFlags, 1);
      expect(p.remoteSync!.currentHeight, 3000002);

      final stray = p.receive(encodeLevinResponse(cmdTimedSync, TimedSyncResponse(p.localSync).encode(), 1));
      expect(stray.single, isA<LevinClosed>());
    });

    test('periodic timed sync and its response', () {
      final p = ready();
      expect(p.tick(30000), isEmpty);
      expect(p.hasOutgoing, isFalse);
      p.tick(60010);
      final out = sent(p.takeOutgoing()).single;
      expect(out.command, cmdTimedSync);
      expect(out.header.expectResponse, isTrue);
      final ev = p.receive(
        encodeLevinResponse(
          cmdTimedSync,
          TimedSyncResponse(
            CoreSyncData(currentHeight: 3000005, cumulativeDifficulty: BigInt.two, topId: _h(3), topVersion: 16),
          ).encode(),
          1,
        ),
        60100,
      );
      expect((ev.single as CoreSyncUpdate).coreSync.currentHeight, 3000005);
      // Idle timeout.
      expect(p.tick(60100 + 300001).single, isA<LevinClosed>());
    });

    test('requests and notifications', () {
      final p = ready();
      p.requestChain([_h(1), mainnetGenesisId]);
      p.requestObjects([_h(2)]);
      p.broadcastFluffyBlock(Uint8List.fromList([7]), [
        Uint8List.fromList([8]),
      ], 12);
      final out = sent(p.takeOutgoing());
      expect(out.map((x) => x.command), [cmdNotifyRequestChain, cmdNotifyRequestGetObjects, cmdNotifyNewFluffyBlock]);
      expect(out.every((x) => !x.header.expectResponse && x.header.flags == levinPacketRequest), isTrue);
      expect(RequestChain.decode(out[0].body).prune, isTrue);
      expect(RequestGetObjects.decode(out[1].body).blocks, [_h(2)]);
      final fb = NewBlockNotify.decode(out[2].body);
      expect(fb.currentBlockchainHeight, 12);
      expect(fb.b.txs.single.blob, [8]);
      expect(() => p.requestObjects(List.generate(101, _h)), throwsArgumentError);

      final ev = p.receive(
        concatBytes([
          encodeLevinNotify(cmdNotifyResponseChainEntry, fromHex(goldenChainEntry)),
          encodeLevinNotify(cmdNotifyResponseGetObjects, fromHex(goldenGetObjects)),
          encodeLevinNotify(cmdNotifyNewTransactions, NotifyNewTransactions([Uint8List(2)]).encode()),
          encodeLevinNotify(cmdNotifyRequestChain, RequestChain([mainnetGenesisId]).encode()),
          encodeLevinNotify(
            cmdNotifyNewFluffyBlock,
            NewBlockNotify(BlockCompleteEntry(block: Uint8List.fromList([1, 2])), 5).encode(),
          ),
        ]),
      );
      expect(ev.map((e) => e.runtimeType), [ChainEntry, ObjectsResponse, NewTransactions, UnhandledNotify, NewBlock]);
      final objs = ev[1] as ObjectsResponse;
      expect(toHex(objs.blocks.single.block!.id()), 'b66648412727405e857aec08902725b4250d67af231e7ea1f30c6aede9a2926c');
      final nb = ev[4] as NewBlock;
      expect(nb.fluffy, isTrue);
      expect(nb.block.block, isNull);
      expect(nb.block.parseError, isNotNull);
    });

    test('malformed body closes the connection', () {
      final p = ready();
      final ev = p.receive(encodeLevinNotify(cmdNotifyResponseGetObjects, Uint8List.fromList([1, 2, 3])));
      expect(ev.single, isA<LevinClosed>());
      expect(p.receive(encodeLevinNotify(cmdNotifyNewTransactions, encodeEmptySection())), isEmpty);
    });

    test('packet limit is 256 KiB until the handshake completes', () {
      final p = LevinPeer(peerId: 1)..startHandshake(0);
      final big = encodeLevinNotify(cmdNotifyNewTransactions, NotifyNewTransactions([Uint8List(300 * 1024)]).encode());
      expect(p.receive(big).single, isA<LevinClosed>());
      final q = LevinPeer(peerId: 1)..startHandshake(0);
      final ev = q.receive(concatBytes([handshakeResponse(), big]));
      expect(ev.map((e) => e.runtimeType), [HandshakeDone, NewTransactions]);
    });
  });
}

/// A raw fragment packet (no REQUEST/RESPONSE flag).
Uint8List encodePacket(Uint8List body, int flags) => encodeLevinPacket(command: 0, body: body, flags: flags);
