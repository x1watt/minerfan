# minerfan architecture

A multi-miner written in pure Dart and Flutter. Monero like Gupax: its own
P2Pool node, its own Monero light peer, and RandomX in Dart. Cryptoescudo:
solo on its own light node, scrypt on the GPU through OpenCL, with an SPV
wallet. No bundled native libraries (OpenCL is the graphics driver's), no
external processes, no servers.

## Packages

```
packages/crypto_core   hashes (SHA-2, BLAKE2b, RIPEMD-160), HMAC, PBKDF2, scrypt,
                       secp256k1 ECDSA (RFC 6979), Base58Check, BIP39, BIP32,
                       Argon2 and ChaCha20-Poly1305 (keys at rest, PasswordBox)
packages/net_core      Transport seam (dart:io sockets by default)
packages/gpu_core      OpenCL through dart:ffi (driver loader, devices, programs)
packages/pow_core      header PoW (scrypt, sha256d), compact targets, retargets
                       (Kimoto Gravity Well), GPU scrypt kernel, header miners
                       (GPU and CPU isolates), the effort controller
packages/utxo_core     Bitcoin family: wire protocol, peers, light header chain,
                       blocks and transactions, templates, solo miner, SPV HD
                       wallet, the chain service isolate (ChainHandle); coins
                       plug in with ChainParams
packages/cesc_core     Cryptoescudo: parameters, reward schedule, checkpoint
packages/xprs_wire     XPRS packets, identifiers, signatures, sealed bodies,
                       parts and receipts (vendored from the xprs app)
packages/xprs_room     coin chat rooms on XPRS open groups: room names and
                       meeting addresses, the two-week store, history
                       catch-up, members, flood guard, the room engine
packages/xmr_core      Monero, pure Dart, no runtime dependencies
  crypto/              keccak, argon2d, soft AES, ed25519, Monero keys
  randomx/             cache, superscalar, VM (v1 and v2), rounding emulation,
                       memory backends, hash pool (isolates)
  randomx/jit/         x86-64 and ARM64 JITs (port of xmrig): assemblers,
                       templates, compilers, hardware AES routines, exec
                       memory, CPU features
  monero/              address, block and coinbase, tree hash, difficulty,
                       hard forks, checkpoint, light chain
  levin/               Monero P2P: framing, portable storage, messages, peer
  p2pool/              consensus, share codec, sidechain, template, P2P peer
  node/                Monero and P2Pool network managers, node, isolate host
apps/minerfan          the Flutter app: Dashboard, Miners (each miner has its own
                       page), Wallets, Settings (power profile, theme color, web server/API)
```

## App (minerfan)

The app is named minerfan. The package id keeps its first name so installs
update in place; the data folder is `minerfan` (`~/.local/share/minerfan`
on Linux, `files/minerfan` on Android), and an old `xmr-dart` folder is
moved there once at startup (`migrateDataDir`). It is built to host
several miners:
- `lib/miners/miner.dart`: the `Miner` interface the dashboard and the
  Miners list use (name, ticker, detail, status line, hashrate, start,
  stop). `MoneroMiner` (`lib/miners/monero_miner.dart`) owns its settings
  (`settings.json`), the node handle, thermal control and the notification
  text. `UtxoMiner` (`lib/miners/utxo_miner.dart`) is solo mining on any
  Bitcoin-family coin (Cryptoescudo today, `<coin>-miner.json`): payout
  address (default: the coin's first wallet), effort (target share of the
  network, adjustable, applied at once), GPU and CPU threads.
- `lib/chains/utxo_chain.dart`: `UtxoCoin` (parameters and checkpoint; one
  per coin) and `UtxoChain`, which runs the coin's `ChainHandle` isolate
  while its miner or any of its wallets needs it.
- Device planner (`lib/devices.dart`, the dashboard's Devices card): which
  miner uses the CPU and which the GPU, with warnings when CPU threads add
  up to more than the machine has or two miners share a GPU. Defaults
  follow the catalog: RandomX keeps the CPU, a GPU coin takes the GPU with
  no CPU threads.
- `lib/app_controller.dart`: app settings (`app.json`: power profile,
  accent color, thermal control, sustained performance, web server/API),
  the miner list, and the Android foreground service (started by the first
  running miner, stopped with the last).
- Switches: a master Mining switch on the dashboard and one switch per
  miner. The master switch starts every enabled miner and stops them all;
  a miner's own switch enables or disables just that miner (turning one on
  also turns the master on). The master switch is saved, so when the app
  starts again after being closed, killed by the system or a reboot, it
  resumes mining by itself.
- Wallets (`lib/wallets/`, `wallets.json`): independent from the miners;
  one `Wallet` per chain account with a list of assets (the coin, later
  tokens). Monero wallets (`MoneroWallet`: full or view-only, keys sealed
  like the others) run in the Monero wallet service (`lib/chains/
  monero_chain.dart`, `xmr_core` `MoneroWalletHandle`): balance, locked and
  incoming amounts, history, send (decoys from the node in Settings). An
  address without keys stays a `MoneroWatchWallet` (receive only). See
  `docs/wallets-plan.md`. `UtxoWallet` is a BIP44
  SPV wallet; the xpub watches the chain and the phrase is opened only to
  sign a payment or show it for a backup (on `Isolate.run`). Every coin the
  app mines gets a wallet at startup without asking: the plain text phrase
  left by the command-line miner is imported and deleted, otherwise a new
  12-word wallet is created. Phrases are sealed with the device key
  (`device.key`, 32 random bytes, owner-only; `KeyBox`) unless the user
  sets a password (`PasswordBox`: Argon2id), which is then asked for every
  payment. A reminder stays on the wallet until the user confirms writing
  the recovery words down. Prices in USD come from
  Kraken, then KuCoin, then CoinGecko (`lib/prices.dart`).
  The wallets the app makes by itself (one per mined coin, the Monero
  payout address) are made once, recorded in `app.json` `autoWallets`;
  removing a wallet deletes its sealed keys and its scan state
  (`wallet-<id>.json`) and it does not come back. The remove dialog warns
  when a miner's typed payout address is that wallet. A wallet's page has
  two tabs: the wallet (balance, receive, send) and its history.
- Contacts (`lib/contacts/`, `contacts.json`, the Contacts button on the
  Wallets tab): a contact's identity is a NOSTR public key (npub) with the
  XPRS callsign derived from it (docs XPRS.md section 3); the rest is a
  name, a note and any number of fields, each a free type (`monero`,
  `cryptoescudo`, `i2p`, `website`, `irc`, or anything typed in) with a
  value and a label. Every level of the JSON keeps keys a version does
  not know, so newer data survives an older app. `lib/ui/field_types.dart`
  lists the types the app knows (icons, hints, address checks); a wallet
  field's type is the wallet's chain id, which is how a send form offers
  contacts (only valid addresses). This device's own card uses the XPRS
  station key: `xprs-contact:1.<payload>.<signature>`, base64url JSON
  signed with the XPRS short Schnorr over sha256 of the text before the
  signature, so a scanned card's addresses are the key holder's. The app
  fills the first card with its own wallets' addresses. Cards travel as QR
  codes (qr_flutter), read on phones from camera frames (the `camera`
  plugin) and elsewhere from a paste or an image file (`file_selector`),
  decoded in pure Dart (zxing2) on `Isolate.run`. A few QR layouts in a
  hundred defeat zxing2's finder-pattern search, so the app re-signs its
  card with the next second until its own camera reader finds the code.
  Contacts with an `i2p` field are handed to the XPRS link (their key
  verifies what they send; they get receipts).
- Mining catalog (`assets/mining_catalog.json`, `lib/catalog.dart`):
  20 algorithms and 24 coins, each algorithm with its hardware class (CPU,
  GPU, disk, other for ASIC and FPGA), the coins' price ids and the app's
  miner and wallet ids. Categorization only, for a later comparison of what
  is worth mining; the Miners list shows each miner's class and algorithm.
- Private network (`lib/network/`): the app's own I2P node from
  x1watt/i2p-dart (pure Dart, its own isolate, no router to install):
  NTCP2 to the public I2P network, inbound and outbound 1-hop tunnels, a
  LeaseSet2 in the netDB and a `.b32.i2p` address. On by default on
  desktops, off on phones; a switch, the status, the callsign, npub and
  address, and the node's log are in Settings.
  - Identities (`network_keys.dart`): an XPRS station key (secp256k1; npub
    and an `X1` callsign) in `xprs/identity.key` and the I2P destination and
    router seeds in `i2p/identity.key`, both made on first use and sealed
    with the device key like wallets. Loaded on `Isolate.run`. The address
    and callsign stay the same across starts; the routers the node saw are
    cached in `i2p/state/routers.bin`, so later starts skip the reseed (up
    in about 20 s instead of about 75 s).
  - Messages (`xprs_i2p.dart`, `XprsI2pLink`): XPRS packets (docs XPRS.md)
    over I2P, as one more bearer next to xprs's BLE, LAN and Reticulum.
    An i2p-dart application message on port 4242 carries XPRS wire lines
    joined with `\n`, led by the sender's signed `t:identity`; the receiver
    binds the callsign to its key (only the first line of a frame speaks for
    the sender's address), verifies every packet, dedupes by the sha256 of
    the signed text, opens sealed bodies (section 9.2), rejoins parts (a
    plain split post is checked once rejoined, since only its last part is
    signed) and answers a direct message to this station from a contact
    with a signed `t:receipt`.
    Signing, sealing and verifying run on `Isolate.run`. The XPRS code is
    `packages/xprs_wire`, vendored from the xprs app and reticulum-dart
    (`dart run tool/sync_check.dart` there reports drift).
  - What the relays see: i2p-dart datagrams are signed, not encrypted, so
    the two transit routers of a path read the XPRS cleartext fields
    (`t f d ts`), as any XPRS bearer does; bodies are sealed. XPRS sealing
    is static ECDH with AES-CBC and no forward secrecy (spec section 9.2).
  - Coin rooms: see below.
- Coin rooms (`packages/xprs_room`, `lib/network/rooms.dart`, the Chat tab
  of each miner's page): one chat per mined coin, so people mining it can
  share how it goes. No server and no moderators.
  - A room is an XPRS open group (docs XPRS.md 7.3): `t:message f:<callsign>
    d:MONERO ts:.. sig:.. m:..`, replies with `r:`/`root:` (7.4), likes as
    `t:reaction r:<id> add:like` (7.5). Room names are the coin's name in
    capitals (`MONERO`, `CRYPTOESCUDO`), so xprs users posting to the same
    group over other bearers are in the same room.
  - Finding each other: every room has four meeting addresses, I2P
    destinations whose seeds are `sha256("minerfan-room/v1|ROOM|k|enc")`
    and `..|sign"`, the same for everyone. i2p-dart 0.3.0 lets a node answer
    for such a shared destination: each member publishes a LeaseSet2 for
    one of the four (chosen by its own address) pointing at its own
    tunnels, and a newcomer greets all four; whoever the netDB returns
    answers. App frames (version 2) carry the sender's leases, so the answer
    needs no netDB lookup. Two things make this work between devices whose
    view of the network differs (a phone and a desktop reseed separately):
    lease set stores carry a reply token, so the floodfills flood them to
    their peers closest to the key, and lookups follow the closer floodfills
    that search replies name. Tests on one machine share one view and hide
    this; the phone and desktop check in September 2026 found it. Remembered members and contacts with an `i2p`
    field are greeted too.
  - Frames on I2P port 4244: JSON control frames (`hello`, answered with
    `members`: up to 30 addresses with callsigns and last seen), and XPRS
    lines led by the sender's signed `t:identity` (with `nick:`, the name
    from Contacts). A listed member is a candidate until a frame from that
    address carries a verified identity. Members are kept in
    `rooms/<ROOM>/members.json` (at most 200).
  - A post is at most nine XPRS parts of 250 bytes (section 6.6), about
    870 to 1060 characters depending on the room name and whether it is a
    reply; the composer stops at 850.
  - Spreading: a post is signed once and pushed to up to 10 live members and
    one candidate. Every 5 minutes (plus up to a fifth, at random) a member
    asks a random live member for what is new (catch-up, XPRS 11.2), which
    fills whatever a push missed. With more than 10 live members, receivers
    also pass fresh posts on to 2 others (`via:`, at most three hops).
  - Two weeks: every member keeps 14 days and serves nothing older, so a
    newcomer sees exactly the last two weeks. Joining asks the newest seven
    days, then the seven before (one ask covers at most seven days, 12.10);
    answers are `t:result code:202`, the authors' own signed wires newest
    first, then `200`, or `206` to go on from the oldest time (`until:`),
    `404`, or `429` when the responder's budget (30 pages an hour per asker,
    240 in all) is spent. A page is at most 50 posts or 28 KB including the
    authors' identity lines, which ride first so every signature checks.
  - Store: day files of JSON lines (`rooms/<ROOM>/YYYY-MM-DD.jsonl`, each
    `{"w":[wires]}` with the parts as sent), `identities.jsonl` and
    `local.json` (muted, hidden, last read); pruned hourly, at most 8 MiB a
    room. Loaded on `Isolate.run`; every signature check and signing runs on
    `Isolate.run` too.
  - No moderators: "Mute" hides a callsign on this device and stops passing
    its posts on; "Hide this message" hides one post. A flood guard adapted
    from reticulum-dart's SpamPolicy drops fresh posts over 6 a minute or 60
    an hour per callsign (30 likes a minute), and holds back authors new to
    a busy room.
  - Joining: a room is joined by opening its Chat tab or by mining the coin
    (`rooms` in `app.json`), and goes online whenever the private network
    runs. On phones, where the network is off by default, the Chat tab
    offers a Join button.
  - What is public: posts are clear text for anyone in the room and for the
    two transit routers of each I2P path; the members list ties a device's
    `.b32.i2p` address to its callsign; and publishing a meeting address
    shows the netDB that this destination is in a coin's room.
  - The chat view (`lib/ui/chat/chat_view.dart`) is forked from the xprs
    app's ChatViewField without media; `chat_palette.dart` and
    `generated_avatar.dart` are copied from it unchanged.
- Icon: a mining-rig fan (shroud, five swept blades, a gem at the hub) on
  a dark rounded square. `tool/icon/make_icons.py` (cairosvg) writes
  `assets/icon/minerfan.svg` (the Linux dock and app menu use it through
  the launcher entry), the Android launcher PNGs, the adaptive icon
  (foreground, background, monochrome for themed icons) and the status bar
  icon.
- Power profiles: performance (no flexible mining), balanced (flexible
  CPU/RAM mining, the default), eco (flexible on half the threads). A change
  applies at the next start.
- UI (`lib/ui/`): Dashboard (master switch, total hashrate, one card per
  miner with its switch and a chip to its chat, with the count of new
  messages), Miners (list; each opens its page: Overview, Settings, Pool,
  Chain, Rewards, Log, Chat), Settings. A true-black theme (`lib/theme.dart`)
  with one accent color; Material's seed-derived surfaces were what tinted
  the old theme brown. The web server/API switch is shown but not built
  yet.

## Runtime

- UI isolate: Flutter only. Receives a status snapshot every 2 s.
- Node isolate (`NodeHandle`): Monero light chain, P2Pool sidechain, both
  peer managers, templates, rewards.
- Monero wallet isolate (`MoneroWalletHandle`): its own light chain and
  RandomX PoW checks (one worker, light mode), block scans for the wallets,
  sends. Heavy steps of a send (range proof, signatures) run on a helper
  isolate.
- Chain isolate per Bitcoin-family coin (`ChainHandle`): light node, solo
  miner, SPV wallets; status every 2 s. Its GPU miner is one more isolate
  (OpenCL batches, CPU recheck of every found nonce); CPU mining threads are
  isolates too. The host side of GPU mining is about 2% of one core.
- RandomX worker isolates (`HashPool`): mining and PoW verification.
  Verification requests run before mining work.

Memory: with shared memory the cache of the mining seed and of one more
seed (late shares) live once in OS memory and every worker attaches to
them. In fast mode workers start on the cache while the 2080 MiB dataset of
the mining seed is built in chunks on helper isolates, then switch to it.
Only the mining seed has a dataset. The build is skipped (light mode) when
the OS reports less than dataset plus 1 GiB free (Linux, Android, Windows).
Shared memory is freed only after every worker has acknowledged letting go
of it, on seed changes and on stop. A worker inside a native JIT hash cannot
be killed, so stop waits for each worker's `exited` message (and leaks the
memory rather than freeing it if one never arrives).

On Android the standalone app keeps mining when it is closed or the screen
is off, through a small Kotlin layer in `apps/minerfan/android`:
- `MainActivity` uses one Flutter engine per process that outlives the
  activity, so the Dart node keeps running and the reopened app attaches to
  it.
- `MiningService` is a `specialUse` foreground service with a partial wake
  lock. It shows a notification with the hashrate and a Stop action, which
  asks Dart to stop the node.
- `MiningChannel` is the method channel between the two
  (`lib/mining_service.dart` on the Dart side).
- Restarting after a kill (the master switch is saved in `app.json`):
  - `MiningService` is sticky: when the system kills the process, Android
    restarts the service, which starts the Flutter engine without any
    activity (`MinerEngine.ensure`); Dart's `main()` sees the master switch
    on and resumes mining;
  - `MiningWatchdog`, a persisted JobScheduler job every 15 minutes,
    restarts the service if the master switch is on and the service is
    gone (covers kills that Android does not follow with a restart);
  - `MiningBootReceiver` resumes after a reboot and after an app update;
  - the app asks once to be exempt from battery optimization (Android's
    dialog; also a "Background mining" row in Settings). Vendor battery
    managers kill exempt apps less, and only exempt apps may start the
    foreground service from the background (the watchdog path).
  Verified on the T606: after `am crash` Android restarted it and it mined
  again within 30 s; the watchdog, forced right after a crash, had it back
  in 2 s; an app update resumed mining without opening the app.

Mining itself stays in Dart. Measured on the T606 phone:

| State | Hashrate | CPU |
|---|---|---|
| Foreground | 74 to 78 H/s | |
| Home pressed | same | |
| Screen off | 74 to 78 H/s | 620 to 730% |
| Forced deep Doze (network kept working) | 74 to 78 H/s | |
| Activity closed | 72 to 91 H/s | |

The service keeps the process in Android's `foreground` CPU group (all
cores). Background apps are limited to cores 0 to 3 there.

Thermal control (Settings, on by default on Android) keeps a phone from
heating up until the system throttles it hard. Every 10 s the app reads
the `PowerManager` thermal status, the thermal headroom forecast for 10 s
and the battery temperature (`MiningChannel.thermal`).
`ThermalGovernor` (`xmr_core/lib/src/node/thermal.dart`) turns the reading
into a thread count, and `NodeHandle.setActiveThreads` applies it: the
`HashPool` workers above the count get a `pause` and the rest take the job
with the new nonce stride, so no restart and no dataset rebuild.

| Reading | Action |
|---|---|
| status 4 or more, or battery 48 C or more | pause mining |
| status 3, headroom 0.95 or more, or battery 45 C or more | cut to 60% of the threads (at least 1) |
| status 2, headroom 0.85 or more, or battery 42 C or more | one thread fewer (at least 1) |
| status 1, headroom 0.70 or more, or battery 39 C or more | hold (resume on 1 thread after a pause) |
| none of the above | one thread more per minute of cool readings |

Status shows `N of M` threads and a card with the reason while threads are
held back, and the Log tab records every change (`mining threads: N of M`).
Verified on the T606 with `adb shell cmd thermalservice override-status`:
status 2 took 8 threads down to 4 in 30 s, status 4 paused mining, and
after a reset mining resumed on 1 thread and gained one per minute.

Sustained performance mode (Settings, on by default where offered) calls
`Window.setSustainedPerformanceMode` while mining, so a phone that offers it
holds its CPU at clocks it can keep up for hours instead of bursting and
then throttling. Android ties the mode to a window: it applies only while
the app is on screen, and `MainActivity.onResume` applies it again to each
new activity. Vendors may opt out (`isSustainedPerformanceModeSupported`),
and the T606 does, so there the switch is disabled and thermal control does
the job.

## Flexible CPU/RAM mining

On by default (`NodeConfig.flexible`, Settings, `node_cli --no-flexible` to
turn it off). The node mines in the machine's idle time and steps aside
for the user's work. Every 2 s it samples:
- CPU used by other programs: machine busy time minus this process's time
  (`SystemLoad`: /proc/stat and /proc/self/stat on Linux,
  `GetSystemTimes` and `GetProcessTimes` on Windows). Android hides
  /proc/stat from apps, and macOS is not read yet, so there only memory is
  watched (thermal control covers phones);
- available and total memory (`availableMemoryBytes`, `totalMemoryBytes`).

`FlexGovernor` (`node/flex.dart`) turns the samples into actions:

| Condition | Action |
|---|---|
| other programs use N cores (smoothed) | N threads fewer, all off when they fill the machine; threads come off at 0.7 of a core, come back below 0.2, one per 6 s |
| free memory below 15% (at least 1 GiB) | give the 2 GiB fast-mode dataset back (`HashPool.setDatasetEnabled(false)`): workers move to the cache and keep mining in light mode, the memory is freed after they all let go |
| free memory below 12% (at least 512 MiB) | pause mining until it is back above that plus 256 MiB |
| room for the dataset plus the 15% mark plus 1 GiB, for 3 minutes | build the dataset again |

The first dataset build uses the same rule, so a dataset is never built
only to be given back seconds later (a build takes every core for several
seconds). Thermal control and flexible mining each cap the threads; the
lower cap wins (`XmrNode._applyThreads`). The Status page shows a card with
the reason, the notification says "(other apps busy)", and the log records
thread changes and every memory state change.

Seen live on this desktop (other sessions running builds, load about 7):
other programs used 2.9 cores, so it mined on 5 of 8 threads, and with free
memory near the mark it gave the dataset back and kept mining in light
mode.

## How the node gets its data without a Monero node

1. A checkpoint of 735 headers (id, timestamp, cumulative difficulty) is
   built into the app (`tool/gen_checkpoint.dart`, release tooling).
2. The light chain fetches blocks forward from it over levin, requiring each
   block to extend its parent, and computes every difficulty with Monero's
   algorithm.
3. Three checks make a fake chain detectable: RandomX PoW of blocks near the
   tip and of seed blocks, exact agreement of our cumulative difficulty with
   the value peers advertise, and the checkpoint itself.
4. The window of 4500 headers is saved, so later starts only sync the gap.

Sidechain verification of a whole window (thousands of shares, each with
its PPLNS outputs) runs in 40 ms slices between network events
(`SideChain.verifyBudgetMs`), so a first sync on a slow phone never blocks
the node isolate. Shares fetched while syncing that happen to be old Monero
blocks are not relayed to Monero again.

P2Pool needs only three things from Monero: the tip, the RandomX seed block
ids, and Monero difficulty at seed heights (the PPLNS window cap). All come
from the light chain. Templates are coinbase-only, which P2Pool consensus
allows; only the fees of a found Monero block are forgone. Found blocks are
broadcast as fluffy blocks to Monero peers and are also submitted by every
P2Pool peer that receives the share.

## Validation done

| What | Result |
|---|---|
| RandomX vectors (cache, superscalar, dataset, reciprocal, hashes a-f v1, a-e v2) | all pass |
| Monero crypto vectors (tests/crypto/tests.txt: keys, derivation, view tags) | all pass |
| Next-block difficulty from the checkpoint vs monerod | exact |
| P2Pool share codec (upstream block.dat: fields, byte-exact round trip, PoW hash) | all pass |
| Sidechain replay: upstream nano dump (4364 shares) and main dump (4543) | every share verified, tips as upstream expects |
| Template built on the nano tip | accepted by the sidechain verifier as new tip |
| Live P2Pool nano peer (P2Pool 4.18) | handshake, tip and parents fetched, ids and links match |
| Live Monero peers | 3002 blocks synced from the checkpoint, cumulative difficulty equals the peer's, tip PoW verifies |
| Full node, live nano | Monero synced in seconds, sidechain synchronized about 3 minutes after, mining own templates, clean shutdown with state saved |
| Restart from saved state | 4360 cached shares reloaded in about 2 s, mining again within a minute |
| Fast mode (`XMR_FAST_TEST=1`) | hashes over the dataset equal the reference vectors, seed switch frees the old dataset |
| Real phone: OUKITEL C61, Unisoc T606 (2 x A75 + 6 x A55), Android 15, 4 GB | ARM64 JIT self-tests pass on hardware (startup and every seed). Monero synced in about 4 minutes, sidechain verified in slices at about 6 shares/s, then mining at 28 to 35 H/s on 2 threads in light mode (the defaults picked for this phone) |
| Same phone: our JIT against native C++ | tevador's RandomX 2.0.1 built with the NDK, JIT, light mode: 16.8 / 31.1 / 48.2 / 67.6 / 81.3 H/s on 1 / 2 / 4 / 6 / 8 threads (result matches the reference). Our app with the whole node running: 28 to 35 H/s on 2 threads, and 70 to 92 H/s (about 78 on average over 9 minutes) on 8 threads. That is about 96% of native |
| Android 14 (x86_64 emulator, release build) | JIT runs (the self-test vector matches, no SELinux denials), node synced in about 3 minutes, mining at 47 H/s on one light-mode thread |
| JIT x86-64 and ARM64 | tevador vectors a-f (v1 and v2), 1000-nonce benchmark cross-check (v1 and v2), JIT against interpreter on random inputs and a synthetic dataset, dataset items, Win64 variant through a thunk (x86-64) |

## RandomX engines

Two engines compute the same hashes.

**JIT** (default on x86-64 and ARM64). This is a port of xmrig's RandomX JITs (`src/crypto/randomx/`,
BSD-3-Clause), in `lib/src/randomx/jit/`.
- Dart turns each RandomX program into machine code at run time. It writes
  the code into executable memory obtained from the OS through `dart:ffi` and
  calls it. No compiler, assembler or native library is bundled.
- ARM64 is ported from `jit_compiler_a64.cpp` and
  `jit_compiler_a64_static.S` (`asm_a64.dart`, `jit_a64.dart`), with
  tevador's fix for ISUB_R with immediate 0x80000000 (xmrig's ARM64 JIT gets
  it wrong). The instruction cache is flushed with `__clear_cache` when libc
  exports it, `sys_icache_invalidate` on Apple, and otherwise a generated
  `dc cvau`/`ic ivau` routine.
- The static code pieces of xmrig's `jit_compiler_x86_static.S` are written
  with a small Dart assembler (`asm_x64.dart`, `x64_templates.dart`). The
  instruction handlers write the same bytes as xmrig (`jit_compiler_x86.cpp`,
  ported in `jit_x64.dart`).
- AES generators and the final AES hash run as AES-NI or ARMv8 crypto code
  (`aes_native.dart`). CPUs without AES instructions (a Raspberry Pi 4,
  some budget phones) run them in Dart around the JIT-compiled programs.
  This adds about 10 ms per hash, still far faster than the interpreter.
  v2 needs AES inside the program loop, so those CPUs hash v2 with the
  interpreter.
- The dataset is built with compiled SuperscalarHash.
- Blake2b and program decoding stay in Dart; they cost about 180 us of a
  1.7 ms hash.

Differences from xmrig:
- **Rounding mode.** The rounding mode lives in `MemoryRegisters`, so the
  program saves and restores the caller's MXCSR (x86-64) or FPCR (ARM64).
  The Dart VM never sees RandomX's rounding mode.
- **Light mode v2.** It has its own dataset-read template, taken from
  tevador; xmrig has none.
- **Code memory.** It is mapped read-write-execute once where the OS allows
  it, as xmrig does. Toggling permissions per program forces TLB flushes on
  every core, which cost 30% with all cores mining. Where the OS refuses,
  permissions are toggled W^X.
- **Huge pages.** Scratchpads come from fresh mmap pages marked for
  transparent huge pages, and so do the cache and dataset.

Safety:
- At start, worker 0 hashes a fixed input with the JIT and with the
  interpreter over an untouched 256 MiB buffer. The same check runs again at
  every seed, in light and in fast mode. A mismatch switches every worker to
  the interpreter.
- A marker file exists while the first self-test is pending. If the process
  dies there, the next start in `auto` mode skips the JIT.

**Threads and fast mode on phones.**
- `CpuTopology` (`lib/src/randomx/jit/cpu_topology.dart`) reads the core clusters from cpufreq and the core types per CPU from `/proc/cpuinfo`. Types decide when big and little cores share one maximum frequency, as on the Unisoc T606.
- It reads the L3 from sysfs, or estimates it from the core types when Android hides it.
- Default mining threads in light mode: every core. Measured on a Unisoc T606, the little cores add about 8 H/s each.
- Default mining threads in fast mode: the big cores only, capped at L3 / 2 MiB, so at most one scratchpad per 2 MiB of cache. This rule is not yet measured on a phone.
- Phones with 8 GB or more default to fast mode. The memory guard still falls back to light mode when free memory is short at dataset time.
- Desktops keep one thread per physical core.

**Interpreter** (pure Dart). This is the fallback everywhere else: iOS
(no JIT memory allowed), other architectures, the pure Dart memory backend,
and any self-test failure.

Verification of the ARM64 JIT ran in an arm64 Debian VM
(qemu-system-aarch64, TCG) with the Dart arm64 SDK:
- all JIT tests pass: hash vectors a-f, 2000-hash benchmark cross-check,
  random inputs against the interpreter, fast mode on a synthetic dataset,
  the W^X fallback, and FPCR preservation;
- the HashPool JIT tests pass too.

qemu does not model instruction caches, so a check on real ARM64 hardware is
still due; the self-test and crash guard cover users until then.

## Performance (this machine, 16 threads, Dart 3.10 AOT)

Interpreter:

| | Time |
|---|---|
| Argon2d cache (256 MiB) | about 1.3 s |
| Dataset item (light mode) | about 15 us |
| Dataset (2080 MiB, 16 lanes, while verifying shares) | 60 to 90 s |
| Light-mode hash | about 330 ms per thread |
| VM part of a hash (fast mode) | about 60 ms per thread |
| VM with round-to-nearest only (for comparison) | about 36 ms |
| Sidechain full verification, nano window | about 35 s for 4364 shares |
| Trusted reload of the same window from disk | about 0.4 s |

JIT (Ryzen 7 3700X, 8 cores and 16 threads; the machine was also busy with
other work):

| | Interpreter | JIT |
|---|---|---|
| Light mode, 1 thread | 3 H/s | 77 H/s |
| Fast mode, 1 thread | about 10 H/s | 598 H/s |
| Fast mode, 8 threads | about 100 H/s | 2950 H/s (bench), 3100 H/s (live node) |
| Dataset build | 60 to 90 s | 4 to 6 s |

Sixteen threads are slower than eight here (about 2100 H/s). With SMT, 16
scratchpads fill the L3 while most of the dataset sits in small pages (THP
covered about 40% of it on this fragmented machine), so page walks miss
cache. The default is therefore one thread per physical core.

Live mining, nano: 3100 H/s with 8 JIT threads. At a share difficulty of
about 121 million that is one share every 11 hours on average. The
interpreter reached 127 H/s (one share every 11 to 12 days).

Directed float rounding is exact (TwoSum and Dekker error terms). The error
sign is random, so the one-ulp correction works on sign bits read through
an aliased integer view: comparisons compile to branches that mispredict
half the time, which cost 25% of the VM.
