/// Monero mainnet hard fork heights (src/hardforks/hardforks.cpp).
library;

const List<(int version, int height)> mainnetHardForks = [
  (1, 1),
  (2, 1009827),
  (3, 1141317),
  (4, 1220516),
  (5, 1288616),
  (6, 1400000),
  (7, 1546000),
  (8, 1685555),
  (9, 1686275),
  (10, 1788000),
  (11, 1788720),
  (12, 1978433),
  (13, 2210000),
  (14, 2210720),
  (15, 2688888),
  (16, 2689608),
];

/// Highest major version this code knows how to mine and verify.
const int supportedMajorVersion = 16;

/// Ideal hard fork version for a block at [height].
int majorVersionAt(int height) {
  var v = 1;
  for (final (version, h) in mainnetHardForks) {
    if (height >= h) v = version;
  }
  return v;
}

/// RandomX seed height for a block at [height] (`rx_seedheight`).
int seedHeight(int height) {
  const epochBlocks = 2048, lag = 64;
  if (height <= epochBlocks + lag) return 0;
  return (height - lag - 1) & ~(epochBlocks - 1);
}
