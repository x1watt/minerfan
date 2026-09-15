import 'dart:typed_data';

import 'package:pow_core/pow_core.dart';
import 'package:utxo_core/utxo_core.dart';

/// Cryptoescudo consensus and network parameters, from the reference client
/// (github.com/vdamas/cryptoescudo, Escudeiro 1.1.5.1: src/main.cpp,
/// main.h, base58.h, protocol.h, net.cpp). Blocks on the network (Escudeiro
/// 1.3.0 nodes) follow the same rules.
abstract final class Cryptoescudo {
  static const coin = 100000000;

  /// `bnProofOfWorkLimit(~uint256(0) >> 20)`.
  static final BigInt powLimit = (BigInt.one << 236) - BigInt.one;

  /// `GetBlockValue` without fees.
  static int subsidy(int height) {
    if (height < 11) return 22000000 * coin;
    if (height < 21) return 22500000 * coin;
    if (height < 31) return 500000 * coin;
    if (height < 46) return 20 * coin;
    if (height < 164000) return 600 * coin;
    if (height < 1314046) return 200 * coin;
    return 20 * coin;
  }

  /// `GetNextWorkRequired_KGW`: 2 minute spacing, windows of 6 hours to 7
  /// days (180 to 5040 blocks). In force from height 31.
  static final KimotoGravityWell retarget = KimotoGravityWell.fromSeconds(
    spacingSeconds: 120,
    pastSecondsMin: 60 * 60 * 24 ~/ 4,
    pastSecondsMax: 60 * 60 * 24 * 7,
    powLimit: powLimit,
  );

  static final ChainParams params = ChainParams(
    name: 'Cryptoescudo',
    symbol: 'CESC',
    magic: Uint8List.fromList(const [0xfb, 0xc0, 0xb6, 0xdb]),
    port: 61143,
    dnsSeeds: const [
      'seed1.cryptoescudo.org', 'seed2.cryptoescudo.org', 'seed3.cryptoescudo.org', //
      'seed4.cryptoescudo.org', 'seed5.cryptoescudo.org', 'seed6.cryptoescudo.org',
      'seed7.cryptoescudo.org', 'seed8.cryptoescudo.org', 'seed9.cryptoescudo.org',
    ],
    // Nodes seen on the network on 2026-09-14 (explorer peer list), used
    // when the DNS seeds do not answer.
    fixedPeers: const ['85.214.70.216:61143', '38.45.65.243:61143', '107.172.27.208:61143'],
    protocolVersion: 70002,
    userAgent: '/minerfan:0.1.0/',
    pubKeyHashVersion: 28,
    scriptHashVersion: 88,
    wifVersion: 28 + 128,
    bip44CoinType: 111,
    pow: ScryptPow.new,
    retarget: retarget,
    targetSpacingSeconds: 120,
    subsidy: subsidy,
    coinbaseMaturity: 40,
    minFeePerKb: 100000,
    softDustLimit: 10000000, // DUST_SOFT_LIMIT, 0.1 CESC
    blockVersion: 2,
    bip34: true,
  );
}
