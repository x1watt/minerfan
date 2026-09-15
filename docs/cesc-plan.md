# Cryptoescudo (CESC): status and resume plan

The approved plan is `~/.claude/plans/i-want-create-a-radiant-wozniak.md`
(miner on the GPU with an effort slider, SPV wallet, all shared code in
reusable packages, Monero on the CPU and CESC on the GPU at the same time).
This file records where the work stands.

## Facts (checked 2026-09-14)

- Network: height about 3.2M, 17 nodes (Escudeiro 1.3.0, protocol 70002),
  difficulty 0.0014, about 48 kH/s. The DNS seeds resolve to one address
  that is not a node; fixed peers from the explorer's peer list work
  (`Cryptoescudo.params.fixedPeers`).
- Consensus from github.com/vdamas/cryptoescudo (1.1.5.1, MIT): see the
  table in the plan and `packages/cesc_core/lib/src/params.dart`.
- Explorer API (for manual checks only): `https://explorer.cryptoescudo.work/api/`
  (`getblockhash?index=`, `getblock?hash=`, `getrawtransaction?txid=&decrypt=1`);
  its certificate does not verify (`curl -k`).

## Done

1. `packages/crypto_core` (SHA-256 moved from `xmr_core`, SHA-512,
   RIPEMD-160, HMAC, PBKDF2, scrypt, secp256k1 ECDSA with RFC 6979,
   Base58Check, BIP39, BIP32) and `packages/net_core` (Transport moved from
   `xmr_core`). 8 tests with independent vectors; `xmr_core` still passes
   its 105 tests. Dart scrypt: about 1100 H/s per core (AOT).
2. `packages/pow_core`: `CompactTarget`, `HeaderPow` (`ScryptPow`,
   `Sha256dPow`), `KimotoGravityWell` (ported with its double math).
3. `packages/utxo_core`: bytes, headers/transactions/blocks, `ChainParams`,
   wire codec and messages, `Peer` (handshake works with live nodes),
   `HeaderChain` (checkpoint, PoW, exact retarget, median time, most-work
   branches, save/restore).
4. `packages/cesc_core`: params, subsidy, checkpoint at 3,202,249
   (`tool/gen_checkpoint.dart`), fixture of the 600 following real headers.
   5 tests: all 600 real headers pass, including the KGW `nBits`.

5. `packages/gpu_core`: OpenCL 1.2 through dart:ffi (`libOpenCL.so.1`),
   devices, context, program build with the driver's log, buffers, kernel
   launch. `tool/devices.dart` finds the RTX 3080 (9868 MiB, 68 CUs, OpenCL
   3.0 CUDA).
6. `pow_core/lib/src/gpu/`: our own OpenCL scrypt kernel (RFC 7914, one
   work item per nonce, V interleaved for coalescing) and `ScryptGpu`.
   `MINERFAN_GPU_TEST=1 dart test test/scrypt_gpu_test.dart`: 64 GPU hashes
   equal the Dart ones and a search over 4096 nonces finds exactly the CPU's
   nonces. Speed (`tool/bench_gpu.dart`): about 600 kH/s at batch 16384
   (27 ms per launch, 277 W), 12 times the whole network. Lookup gap and
   vector width can raise it later.

7. Effort controller (`pow_core`, simulated network test) and
   `GpuScryptMiner` (worker isolate, duty cycle, CPU recheck of every GPU
   result); `utxo_core`: addresses and WIF, block templates (BIP34,
   `/minerfan/` tag), `UtxoNode` (peers, header sync, broadcast),
   `SoloMiner`. BIP44 coin type 111 checked against hdaddressgenerator's
   Cryptoescudo vectors.
8. **First block, 2026-09-14 17:51:** `tool/cesc_cli.dart --effort 25`
   found block 3,202,858 (`8c96af86...`), accepted by the network (explorer:
   2 confirmations, coinbase 20 CESC to `CSqd18riXQjBy6vUNcnfi7kwHS7fDGUFE2`,
   the key of `~/.local/share/minerfan/cryptoescudo/wallet-mnemonic.txt`,
   m/44'/111'/0'/0/0). The GPU ran at about 2% duty (13 kH/s) for a 25%
   target while the Monero app mined on the CPU.

9. SPV wallet (`utxo_core/lib/src/wallet.dart`): BIP44 account watched by
   its xpub, BIP37 bloom filter loaded into every peer, filtered blocks in
   batches of 200 with partial merkle tree checks, mempool, coinbase
   maturity, persistence of public data only. Found both mined coinbases
   from live peers. Transactions: coin selection, the Litecoin 0.8 fee rule
   (per started kB, one more base fee per output under 0.1 CESC, the change
   included), legacy sighash, RFC 6979 signatures (`TxBuilder.plan/pay`).
10. Keys at rest (`crypto_core`): Argon2 d/i/id (RFC 9106 vectors) and
    ChaCha20-Poly1305 (RFC 8439 vector, cross-checked with Python's
    cryptography); `PasswordBox` seals a secret with Argon2id (64 MiB, t=3,
    about 0.5 s) and a fresh salt per seal.
11. `pow_core`: `HeaderMiner` interface, `GpuScryptMiner` and
    `CpuHeaderMiner` (isolates, split nonce space, duty cycle). `SoloMiner`
    drives several devices at once, each with its own template.
12. `utxo_core/lib/src/chain_service.dart`: `ChainHandle`, one isolate per
    chain with the light node, the solo miner and any SPV wallets; status
    every 2 s; requests for mining, effort, wallets, fee preview and send.
    The node now prefers peers that completed a handshake before
    (`good-peers.txt`) and backs off from dead gossiped addresses for 30
    minutes (it sat at 0 peers for minutes before).
13. App: `UtxoChain` and `UtxoCoin` (`lib/chains/`), `UtxoMiner` (payout from
    the first wallet or an address, effort slider applied live, GPU and CPU
    threads, eco halves effort and threads), `UtxoWallet` (create with a new
    12-word phrase or restore, password sealed, Argon2/PBKDF2 on
    `Isolate.run`), wallet page with send (fee preview, password) and
    history, a one-time import of the CLI's plain text phrase (then deleted),
    the device planner card on the dashboard, CESC in the catalog with a
    per-coin hardware class (`gpu`). On Xvfb the app found block 3,202,877
    (accepted, 20 CESC to `CSqd18ri...`). The chain and GPU miner isolates
    use about 2% of one core.
14. Reuse: a test checks that the shared packages mention no Cryptoescudo
    constants; Litecoin (scrypt) and Bitcoin (sha256d) genesis headers and
    addresses check with test-only parameters.

15. Wallets without steps (user request): created or imported at startup,
    sealed with the device key, password optional (set, change or remove
    from the wallet page), backup reminder instead of a blocking step. The
    desktop app imported the mined wallet (`CSqd18ri...`) and deleted the
    plain text phrase file.

16. **Send confirmed on chain:** 5 CESC from the mined wallet to its own
    receive address, tx `841be35e...` in block 3,202,899 (fee 0.001 CESC,
    change 14.999). It exposed an SPV bug, now fixed: peers do not resend a
    transaction after its merkleblock when they know we have it (we
    broadcast it), so the wallet now confirms known transactions from the
    merkle proof itself. A send is also recorded as spent coins (net -fee)
    instead of as a receipt.

17. **Incident, 2026-09-14 21:00 to 21:52:** the desktop miner took about
    70% of the blocks (97 accepted and 19 self-orphaned between heights
    3,202,921 and 3,203,060) at a 25% effort, and the difficulty doubled.
    Cause: any message to the GPU miner (new work, a duty update) ended its
    rest early, so when blocks came fast the GPU ran at full speed whatever
    the duty (131 kH/s at a 2% duty with new work every 300 ms), which made
    blocks come faster still; Kimoto Gravity Well took 55 blocks to react.
    Fixes: only stop or a higher duty ends a rest (12.5 kH/s at 2% now, in
    the same test); the network hashrate comes from the work of the last 60
    blocks over the time they took, not from the difficulty alone; a
    fair-share guard counts our blocks among the last 30 and slows down
    above the target (pauses at twice it); after finding a block the miner
    adds it to its own chain and mines on top of it (no self-orphans); a
    block counts as accepted only with two blocks on top.
18. Android: the C61 (Unisoc T606, Mali-G57) exposes OpenCL to apps
    (`libOpenCL.so` in the vendor's public libraries); Android 12+ needs
    `<uses-native-library android:name="libOpenCL.so" android:required="false"/>`
    in the manifest. Our kernel passes the GPU self-test there (hashes equal
    to the CPU's) at about 2.2 kH/s, 128 MiB of scratch. Every start runs
    the self-test (a guard file turns GPU mining off if a driver ever
    crashes the app); a warm phone caps the duty (thermal control).
    Phones without OpenCL mine on the CPU (Vulkan compute later).
19. App: "Mine on the CPU" is its own switch next to the GPU; a payout
    picker (any wallet of the coin, or another address) for both miners;
    coins mined per miner on the dashboard; a dedicated page to add as many
    wallets as wanted (create, restore, view-only, watch), rename, grouped
    by blockchain.

## Next
- Android: CPU mining only (no OpenCL for apps); GPU through Vulkan later.
- Wallets restored from a phrase see transactions from the checkpoint on;
  older history would need headers further back.
- Flexible CPU/RAM mining does not yet apply to CESC CPU threads, and GPU
  load from other programs (games) is not detected (NVML later).
