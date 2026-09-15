import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xmr_core/src/p2pool/consensus.dart';
import 'package:xmr_core/src/p2pool/pool_block.dart';
import 'package:xmr_core/src/crypto/ed25519.dart';
import 'package:xmr_core/src/p2pool/sidechain.dart';
import 'package:xmr_core/src/p2pool/template.dart';
import 'package:xmr_core/src/util/bytes.dart';

/// Replays the upstream P2Pool sidechain dumps (tool/fetch_testdata.sh) and
/// checks the resulting tip against pool_block_tests.cpp expectations.
class _FixedMain implements MainChainView {
  final BigInt diff;
  _FixedMain(this.diff);
  @override
  BigInt? difficultyAt(int height) => diff;
  @override
  MainChainBlock? byId(Uint8List id) => null;
  @override
  MainChainBlock? get tip => null;
}

List<PoolBlock> loadDump(String path, P2PoolConsensus c) {
  final data = File(path).readAsBytesSync();
  final out = <PoolBlock>[];
  var o = 0;
  while (o + 4 <= data.length) {
    final n = readU32LE(data, o);
    o += 4;
    out.add(PoolBlock.parse(Uint8List.sublistView(data, o, o + n), c));
    o += n;
  }
  return out;
}

void main() {
  // Difficulty of Monero block 3454976 (the seed height of the dumps' tip).
  final mainDiff = BigInt.from(625461936742);

  for (final (name, file, consensus, tipSide, nextShares) in [
    ('nano', 'test/fixtures/sidechain_dump_nano.dat', P2PoolConsensus.nano, 188542, 115),
    ('main', 'test/fixtures/sidechain_dump.dat', P2PoolConsensus.main, 11704382, 53),
  ]) {
    test('$name dump syncs to the expected tip', () {
      final sw = Stopwatch()..start();
      final blocks = loadDump(file, consensus);
      final parseMs = sw.elapsedMilliseconds;
      final s = SideChain(consensus, _FixedMain(mainDiff));
      for (final b in blocks) {
        final r = s.externalVerify(b);
        expect(r.invalid, isNull, reason: 'external verify: ${r.invalid}');
        final a = s.addBlock(b);
        expect(a.invalid, isNull, reason: 'add block at ${b.side.height}: ${a.invalid}');
      }
      final tip = s.tip!;
      print('$name: ${blocks.length} blocks, parse ${parseMs}ms, total ${sw.elapsedMilliseconds}ms');
      expect(tip.verified, isTrue);
      expect(tip.invalid, isFalse);
      expect(tip.main.genHeight, 3456189);
      expect(tip.side.height, tipSide);
      for (final b in s.allBlocks) {
        expect(b.verified && !b.invalid, isTrue, reason: 'block ${b.side.height}');
      }
      // The tip pays exactly its PPLNS window. (Upstream's $nextShares counts a
      // new template on top of the tip, which adds the template's own miner.)
      expect(s.getShares(tip).length, tip.main.outputs.length);
      expect(tip.main.outputs.length, nextShares - 1);

      // A restart reloads the verified shares from disk without verifying
      // them again and lands on the same tip.
      final cached = [for (final b in s.allBlocks) PoolBlock.parse(b.serialize(), consensus)];
      final reload = SideChain(consensus, _FixedMain(mainDiff));
      final rsw = Stopwatch()..start();
      expect(reload.addTrusted(cached), cached.length);
      print('$name: trusted reload of ${cached.length} shares ${rsw.elapsedMilliseconds}ms');
      expect(toHex(reload.tip!.templateId(consensus)), toHex(tip.templateId(consensus)));
      expect(reload.difficulty, s.difficulty);
      expect(reload.getShares(reload.tip!).length, tip.main.outputs.length);

      // The on-disk cache format: compact against the parent, oldest first;
      // reading it back resolves every transaction and template id.
      final ordered = s.allBlocks.toList()..sort((a, b) => a.side.height.compareTo(b.side.height));
      var fullBytes = 0, compactBytes = 0;
      final blobs = <Uint8List>[];
      for (final b in ordered) {
        fullBytes += b.serialize().length;
        final c = b.serializeCompactAgainst(s.parentOf(b));
        compactBytes += c.length;
        blobs.add(c);
      }
      final byId = <String, PoolBlock>{};
      var resolved = 0;
      for (var i = 0; i < blobs.length; i++) {
        final b = PoolBlock.parse(blobs[i], consensus, compact: true);
        if (b.main.txParentIndices.any((p) => p != 0)) {
          final parent = byId[toHex(b.side.parent)];
          if (parent == null || !b.fillCompactFrom(parent)) continue;
        }
        final id = toHex(b.templateId(consensus));
        expect(id, toHex(ordered[i].templateId(consensus)));
        byId[id] = b;
        resolved++;
      }
      expect(resolved, ordered.length);
      print('$name: share cache ${fullBytes ~/ 1024} KiB full, ${compactBytes ~/ 1024} KiB compact');

      // A template for a new wallet on top of the tip pays one more share and
      // passes the sidechain's own verification when added.
      final spend = scalarMultBase(scReduce32(List<int>.filled(32, 7))).encode();
      final view = scalarMultBase(scReduce32(List<int>.filled(32, 9))).encode();
      final md = MinerData(
        majorVersion: 16,
        height: tip.main.genHeight,
        prevId: tip.main.prevId,
        seedHash: Uint8List(32),
        difficulty: mainDiff,
        medianTimestamp: tip.main.timestamp - 60,
      );
      final tpl = TemplateBuilder(s, spend, view).build(md, nowSeconds: tip.main.timestamp + consensus.targetBlockTime);
      expect(tpl.block.main.outputs.length, nextShares);
      expect(tpl.nonceOffset, 39);
      final share = PoolBlock.parse(tpl.finish(12345).serialize(), consensus);
      expect(s.externalVerify(share).isOk, isTrue, reason: s.externalVerify(share).invalid);
      final added = s.addBlock(share);
      expect(added.isOk, isTrue, reason: '${added.invalid} ${added.cantVerify}');
      expect(identical(s.tip, share), isTrue);
    }, timeout: const Timeout(Duration(minutes: 20)), skip: File(file).existsSync() ? null : 'run tool/fetch_testdata.sh');
  }

  test('sliced verification (small time budget) reaches the same tip', () {
    const file = 'test/fixtures/sidechain_dump.dat';
    final blocks = loadDump(file, P2PoolConsensus.main);
    final s = SideChain(P2PoolConsensus.main, _FixedMain(mainDiff))..verifyBudgetMs = 5;
    var slices = 0;
    for (final b in blocks) {
      expect(s.externalVerify(b).invalid, isNull);
      expect(s.addBlock(b).invalid, isNull);
    }
    while (s.verificationPending) {
      s.continueVerification();
      slices++;
    }
    expect(slices, greaterThan(0));
    expect(s.tip!.side.height, 11704382);
    for (final b in s.allBlocks) {
      expect(b.verified && !b.invalid, isTrue, reason: 'block ${b.side.height}');
    }
  }, timeout: const Timeout(Duration(minutes: 10)),
      skip: File('test/fixtures/sidechain_dump.dat').existsSync() ? null : 'run tool/fetch_testdata.sh');

  // During a real sync shares arrive in any order: most are added while
  // their parent is still unverified, with earlier work left over. No single
  // add may then run for long.
  test('sliced verification with shares in random order: no long calls', () {
    const file = 'test/fixtures/sidechain_dump.dat';
    final blocks = loadDump(file, P2PoolConsensus.main)..shuffle(Random(7));
    final s = SideChain(P2PoolConsensus.main, _FixedMain(mainDiff))..verifyBudgetMs = 5;
    var longest = 0;
    for (final b in blocks) {
      expect(s.externalVerify(b).invalid, isNull);
      final sw = Stopwatch()..start();
      expect(s.addBlock(b).invalid, isNull);
      if (sw.elapsedMilliseconds > longest) longest = sw.elapsedMilliseconds;
      if (s.verificationPending) s.continueVerification();
    }
    while (s.verificationPending) {
      s.continueVerification();
    }
    expect(s.tip!.side.height, 11704382);
    expect(longest, lessThan(1000), reason: 'longest addBlock took $longest ms');
  }, timeout: const Timeout(Duration(minutes: 10)),
      skip: File('test/fixtures/sidechain_dump.dat').existsSync() ? null : 'run tool/fetch_testdata.sh');
}
