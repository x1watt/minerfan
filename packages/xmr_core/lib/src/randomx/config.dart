/// RandomX parameters (tevador/RandomX `configuration.h`, BSD-3-Clause).
library;

const int rxArgonMemory = 262144; // 1 KiB blocks = 256 MiB
const int rxArgonIterations = 3;
const List<int> rxArgonSalt = [0x52, 0x61, 0x6e, 0x64, 0x6f, 0x6d, 0x58, 0x03]; // "RandomX\x03"
const int rxCacheAccesses = 8;
const int rxSuperscalarLatency = 170;
const int rxSuperscalarMaxSize = 3 * rxSuperscalarLatency + 2;

const int rxDatasetBaseSize = 2147483648;
const int rxDatasetExtraSize = 33554368;
const int rxDatasetItemCount = (rxDatasetBaseSize + rxDatasetExtraSize) ~/ 64; // 34078719

const int rxProgramSizeV1 = 256;
const int rxProgramSizeV2 = 384;
const int rxProgramMaxSize = rxProgramSizeV2;
const int rxProgramIterations = 2048;
const int rxProgramCount = 8;

const int rxScratchpadL1 = 16384;
const int rxScratchpadL2 = 262144;
const int rxScratchpadL3 = 2097152;

const int rxJumpBits = 8;
const int rxJumpOffset = 8;

const int cacheLineSize = 64;
const int cacheSizeBytes = rxArgonMemory * 1024;
const int cacheLineCount = cacheSizeBytes ~/ cacheLineSize; // 4194304
const int cacheLineAlignMask = (rxDatasetBaseSize - 1) & ~(cacheLineSize - 1);
const int datasetExtraItems = rxDatasetExtraSize ~/ cacheLineSize;
const int conditionMask = (1 << rxJumpBits) - 1;
const int conditionOffset = rxJumpOffset;
const int storeL3Condition = 14;

const int scratchpadL1Mask = (rxScratchpadL1 ~/ 8 - 1) * 8;
const int scratchpadL2Mask = (rxScratchpadL2 ~/ 8 - 1) * 8;
const int scratchpadL3Mask = (rxScratchpadL3 ~/ 8 - 1) * 8;
const int scratchpadL3Mask64 = (rxScratchpadL3 ~/ 64 - 1) * 64;

const int registerNeedsDisplacement = 5;

const int mantissaSize = 52;
const int mantissaMask = (1 << mantissaSize) - 1;
const int exponentMask = (1 << 11) - 1;
const int exponentBias = 1023;
const int dynamicMantissaMask = (1 << (mantissaSize + 4)) - 1;
const int constExponentBits = 0x300;

const int superscalarMul0 = 6364136223846793005;
const List<int> superscalarAdd = [
  0,
  -9148333072579190276, // 9298411001130361340
  -6381431487974942650, // 12065312585734608966
  -9140414860584924836, // 9306329213124626780
  5281919268842080866,
  -7910590639137690612, // 10536153434571861004
  3398623926847679864,
  -8897639553701190322, // 9549104520008361294
];

/// Instruction frequencies, in opcode order (sum 256).
const List<int> rxFrequencies = [
  16, 7, 16, 7, 16, 4, 4, 1, 4, 1, 8, 2, 15, 5, 8, 2, 4, //
  4, 16, 5, 16, 5, 6, 32, 4, 6, 25, 1, 16,
];
