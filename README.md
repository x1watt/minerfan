# minerfan

A multi-miner written entirely in Dart and Flutter.

**Monero**, like Gupax: it runs its
own P2Pool node with your wallet, follows the Monero chain with its own light
peer, and computes RandomX in Dart. On x86-64 and ARM64 a port of xmrig's
RandomX JIT turns each RandomX program into machine code at run time (about
3 kH/s on an 8-core desktop); elsewhere a pure Dart interpreter runs. There are no native
libraries, no bundled binaries (no monerod, p2pool or xmrig) and no servers.

**Cryptoescudo** (CESC, a Portuguese Litecoin fork): solo mining on its own
light node, scrypt on the GPU in our own OpenCL kernel (about 600 kH/s on an
RTX 3080, where the whole network is about 50 kH/s), held to a chosen share
of the network by the effort slider (25% by default), and an SPV wallet
that sends and receives with its keys encrypted by your password. It runs
next to Monero: Monero keeps the CPU, Cryptoescudo takes the GPU.

- `packages/xmr_core`: the Monero node (pure Dart, no runtime dependencies)
- `packages/crypto_core`, `net_core`, `gpu_core`, `pow_core`, `utxo_core`:
  shared by every coin (hashes, keys, OpenCL, proof of work, the Bitcoin
  family's P2P, light chain, solo miner and SPV wallet)
- `packages/cesc_core`: Cryptoescudo's parameters and checkpoint
- `docs/cesc-plan.md`: the Cryptoescudo work and what was validated live
- `apps/minerfan`: the Flutter app (Linux, Windows, macOS, Android, iOS)
- `docs/architecture.md`: how it works, what was validated, performance
- `docs/xprs-integration.md`: running it inside xprs as a core service plus a wapp

## How you get paid

P2Pool has no pool wallet and nothing to collect. Every share you find stays
in the PPLNS window (about 6 hours on mini, the default; about 1 hour on main; 18
hours on nano). Whenever any P2Pool miner finds
a Monero block, its coinbase pays every wallet with shares in the window
directly. The Rewards tab lists those payouts per day; they appear in your
wallet like any other incoming transfer.

## Running

```sh
cd packages/xmr_core
dart pub get
dart test                                  # unit tests
sh tool/fetch_testdata.sh && dart test     # plus upstream P2Pool fixtures
dart run tool/node_cli.dart --wallet 4...  # headless node

cd packages/cesc_core
dart test                                  # Cryptoescudo: chain, keys, transactions
dart run tool/cesc_cli.dart --address C... --effort 25   # headless solo miner (GPU)
```

The app: `cd apps/minerfan && flutter run` (on this machine through
`~/bin/android-build-locked`).

Choose a primary address (starting with 4). Mini is the default sidechain
(as in Gupax); nano has a lower share difficulty still. Desktop builds default to shared memory
(one RandomX cache for all threads), fast mode (the 2 GiB dataset, built in
seconds by the JIT) and one mining thread per physical core. The RandomX
engine setting chooses between the JIT and the interpreter; `auto` uses the
JIT when the CPU supports it and it passes its self-test.

## Platform notes

- Flutter web cannot run the node: browsers do not allow TCP sockets.
- Google Play and the App Store forbid on-device mining apps; Android builds
  are distributed as APK or through F-Droid, iOS only by sideloading.
- Mining uses a lot of CPU and power. It starts only when you press Start.

## Licenses

BSD-3-Clause. Ported parts and their licenses are listed in
`licenses/THIRD_PARTY_NOTICES.md`.
