# Third-party notices

minerfan is original Dart code. Parts of it are ports (translations) of the
following permissively licensed projects. No third-party code is linked or
executed at runtime.

| Area | Ported from | License |
|---|---|---|
| RandomX (Argon2d cache, SuperscalarHash, VM semantics, AES generators, reciprocal) | tevador/RandomX, https://github.com/tevador/RandomX | BSD-3-Clause |
| RandomX JIT compiler for x86-64: instruction encodings and handlers, program prologue/loop/epilogue templates, SuperscalarHash and dataset init code, AES generator and hash routines, CPU tweaks (BMI2, JCC erratum, CFROUND elimination) | xmrig `src/crypto/randomx/` (jit_compiler_x86.cpp, jit_compiler_x86_static.S, aes_hash.cpp), https://github.com/xmrig/xmrig. Copyright (c) 2018-2020 tevador, Copyright (c) 2019-2021 SChernykh, Copyright (c) 2019-2021 XMRig | BSD-3-Clause (these files carry the RandomX BSD-3 header; xmrig's GPL-3.0 files were not used) |
| RandomX JIT compiler for ARM64: handlers, main loop, light-mode and dataset init templates, calc_dataset_item | xmrig `src/crypto/randomx/` (jit_compiler_a64.cpp, jit_compiler_a64_static.S). Copyright (c) 2018-2019 tevador, Copyright (c) 2019 SChernykh, Copyright (c) 2019-2020 XMRig | BSD-3-Clause |
| RandomX JIT template pieces from `src/asm/*.inc` (including the light-mode v2 dataset read) and the ARM64 ISUB_R fix | tevador/RandomX | BSD-3-Clause |
| RandomX float rounding approach (sign of the exact error, one-ulp nudge) | go-randomx by DataHoarder and DERO Foundation, https://git.gammaspectra.live/P2Pool/go-randomx | BSD-3-Clause |
| P2Pool consensus: share format, sidechain, PPLNS, difficulty, fork choice, P2P protocol, merge-mining tree | P2Pool consensus by WeebDataHoarder, https://git.gammaspectra.live/P2Pool/consensus | MIT |
| Monero levin client pieces (portable storage) | go-monero levin client (via P2Pool consensus) | Apache-2.0 |
| Monero serialization, difficulty algorithm, hard fork table, levin and cryptonote protocol definitions, key derivation | monero-project/monero, https://github.com/monero-project/monero | BSD-3-Clause |
| Monero wallet: English mnemonic word list and checksum (src/mnemonics), hash to point (crypto-ops.c), CLSAG (rctSigs.cpp), Bulletproofs+ (bulletproofs_plus.cc), decoy selection (wallet2.cpp gamma_picker), transaction weight and output construction | monero-project/monero, https://github.com/monero-project/monero | BSD-3-Clause |
| I2P node (NTCP2, tunnels, netDB, LeaseSet2, datagrams), used as a library | geograms/i2p-dart (Max Brito), path `../geogram/i2p-dart` | BSD-3-Clause |
| i2p-dart's dependencies: cryptography, pointycastle, archive, crypto | pub.dev packages | Apache-2.0, MIT, MIT/BSD-3, BSD-3-Clause |
| XPRS packets, identifiers, short-Schnorr signatures, sealed bodies, parts, receipts and the transport vocabulary (`packages/xprs_wire`, copied unchanged apart from import paths and the profile key hook) | xprs app (`app/lib/services/xprs/`) and reticulum-dart (`lib/src/util/xprs_crypto.dart`, `nostr_crypto.dart`), Copyright (c) Max Brito and XPRS contributors | BSD-3-Clause |
| xprs_wire's dependencies: pointycastle, crypto, bech32, hex | pub.dev packages | MIT, BSD-3-Clause, MIT, MIT |
| Coin chat rooms (`packages/xprs_room`): history answers adapted from the xprs app's history server (`serveInline`, `_result`) and catch-up guard, the store's admit order from the chat wapp (`apps/chat/room.c`), and the flood guard adapted from reticulum-dart's SpamPolicy | xprs app (`app/lib/services/xprs/xprs_history_server.dart`, `xprs_catchup.dart`, `apps/chat/room.c`) and reticulum-dart (`spam.dart`), Copyright (c) Max Brito and XPRS contributors | BSD-3-Clause |
| Chat view (`apps/minerfan/lib/ui/chat/`): `chat_view.dart` forked from ChatViewField, `chat_palette.dart` and `generated_avatar.dart` copied unchanged | xprs app (`app/lib/wapp/geoui/widgets/`), Copyright (c) Max Brito and XPRS contributors | BSD-3-Clause |
| QR codes: drawing (qr_flutter, qr), reading (zxing2, a Dart port of ZXing), image files (image), camera frames (camera), file dialogs (file_selector), used as libraries | pub.dev packages | BSD-3-Clause (qr_flutter, qr, zxing2, camera, file_selector), MIT (image) |
| Ed25519 field arithmetic layout (ref10) | SUPERCOP ref10 via Monero crypto-ops | Public domain |

xmrig as a whole is GPL-3.0. Only its `src/crypto/randomx/` files, which are
BSD-3-Clause, were ported. The GPL-3.0 parts (`src/crypto/rx/`,
`src/backend/cpu/`, `src/crypto/common/VirtualMemory*`) were not used; their
roles (memory, CPU detection, worker threads) are implemented independently.

SChernykh/p2pool (GPL-3.0) was used only as a behavioural reference and as a
source of expected test values; no code from it was translated. Test fixtures
from its test suite are downloaded at development time by
`packages/xmr_core/tool/fetch_testdata.sh` and are not part of this
repository. Monero's `tests/crypto/tests.txt` (BSD-3-Clause) is included in
`packages/xmr_core/test/data/`, and the commands the wallet uses in
`packages/xmr_core/test/fixtures/monero_crypto_tests.txt`. Wallet address
vectors in `monero_seed_vectors.json` were computed with monero-python
(BSD-3-Clause) as an independent oracle; `monero_blocks.json` holds public
mainnet blocks.

The BSD-3-Clause and MIT license texts of the projects above apply to the
ported portions; see each project for its copyright notice.
