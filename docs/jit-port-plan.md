# RandomX JIT port: status and resume plan

Written 2026-09-13 so work can resume after a reboot. The approved plan is
`~/.claude/plans/i-want-create-a-radiant-wozniak.md`; this file records
where the work stands.

## Goal

The user wants xmrig's RandomX code running in Dart. Dart emits the same
x86-64 and ARM64 machine code as xmrig's JIT into executable memory obtained
through `dart:ffi` (mmap / VirtualAlloc) and calls it. Rules:
- no bundled native binaries, no C compiler or assembler, no helper
  processes or servers;
- the interpreter stays as the fallback (iOS, unsupported CPUs, self-test
  failure).

## Licensing (verified)

- **Port freely (BSD-3):** everything in xmrig `src/crypto/randomx/`, which
  keeps tevador's BSD-3 header plus SChernykh/XMRig copyright lines.
- **Never port (GPL-3):** xmrig `src/crypto/rx/*`, `src/backend/cpu/*` and
  `src/crypto/common/VirtualMemory*`. Their roles are rewritten in our own
  Dart.
- **Headerless `asm/*.inc`:** take them from tevador/RandomX, whose repo is
  BSD-3.

## Reference sources (they live in /tmp and are gone after a reboot)

Re-fetch into the session scratchpad (or any dev dir, never into the repo):

```sh
git clone --depth 1 https://github.com/xmrig/xmrig.git
git clone --depth 1 https://github.com/tevador/RandomX.git
```

The key files are in xmrig `src/crypto/randomx/`:
- `jit_compiler_x86.cpp`, `jit_compiler_x86_static.S` and `asm/*.inc`;
- `jit_compiler_a64.cpp` and `jit_compiler_a64_static.S`;
- `aes_hash.cpp`, `randomx.cpp` and `vm_compiled*.cpp`.

## Done

All of this is in `packages/xmr_core/lib/src/randomx/jit/`.

| File | What | State |
|---|---|---|
| `exec_memory.dart` | exec memory via ffi: mmap/mprotect (Linux/Android), MAP_JIT + `pthread_jit_write_protect_np` (macOS arm64), VirtualAlloc/VirtualProtect (Windows), THP madvise, ARM64 cache-flush hook | done. RWX mapping once, W^X as fallback; `NativePages` for huge-page scratchpads |
| `asm_x64.dart` | x86-64 assembler (labels, rel8/32, rip-relative, SSE, AES-NI, prefetch) | done |
| `cpu_features.dart` | CPUID via a JIT'd stub (AES, AVX, AVX2, BMI2, XOP, vendor/family/model, total L3), ARM64 via getauxval / IsProcessorFeaturePresent, `suggestedThreads` (L3 / 2 MiB) | done |
| `x64_templates.dart` | port of `jit_compiler_x86_static.S` + `asm/*.inc`: prologue/epilogue SysV and Win64, loop load/store (v1 and v2 hard AES), read dataset v1/v2, light-mode sshash init (v1 and **v2, which xmrig lacks**) and fin, dataset init, sshash init/load/prefetch | done |
| `jit_x64.dart` | port of `jit_compiler_x86.cpp`: every handler byte-for-byte, BMI2 variants, AMD CFROUND variant, CFROUND elimination, JCC-erratum padding, IMUL_RCP stack constants, superscalar JIT, dataset init code | done (the AVX2 dataset init is not ported) |
| `aes_native.dart` | fillAes1Rx4, fillAes4Rx4, hashAes1Rx4 as AES-NI code (SysV + Win64 wrappers) | done (no fused hashAndFill yet) |
| `vm_jit.dart` | `RandomXJitVM.light/fast` (one hash = Blake2b in Dart, AES fill native, 8 JIT programs, AES hash native) and `JitDatasetInit` (address shareable across isolates) | done |

**Deviation from xmrig (by design):** `MemoryRegisters` is extended with
two slots:
- +16: the RandomX MXCSR;
- +20: the caller's MXCSR.

The prologue saves the caller's MXCSR and loads RandomX's, and the epilogue
does the reverse. The rounding mode therefore carries across the 8 programs
while Dart runs with its own FP state. To keep xmrig's stack alignment, the
prologue pushes the `MemoryRegisters*` plus 8 bytes of padding.

**Native block layout in `vm_jit.dart`:**

| Offset | Content |
|---|---|
| 0 | scratchpad (2 MiB) |
| 2 MiB | tempHash (64 B) |
| 2 MiB + 64 | RegisterFile (256 B) |
| 2 MiB + 320 | MemoryRegisters (64 B) |
| 2 MiB + 384 | program (3200 B) |

The block is 2 MiB aligned (`NativePages`).

**Instruction decoding:** xmrig masks each instruction's dst/src to 7
while generating the program. We mask them when decoding in
`_generateProgramPrologue`.

**Other changes:**
- `memory_ffi.dart`: madvise(MADV_HUGEPAGE) on shared allocations of 32
  MiB or more; `availableMemoryBytes()` (from the previous session).
- `tool/bench.dart`: rewritten; takes `jit` and `threads=N`.
- `test/jit_x64_test.dart`, 7 tests, **all passing**:
  - native AES against the Dart AES;
  - 204 dataset items against `initDatasetItem` and the vectors;
  - light-mode hash vectors a-f v1 and a-e v2;
  - 24 random inputs against the interpreter;
  - Dart floating point unaffected after hashing.

## Measured (Ryzen 7 3700X, this machine, busy with other work)

| | Interpreter | JIT |
|---|---|---|
| Light mode, 1 thread | about 3 H/s (330 ms/hash) | 61 H/s (16.5 ms) |
| Fast mode, 1 thread | about 10 H/s | 417 H/s (2.4 ms) |
| Fast mode, 8 threads | about 100 H/s | 2021 H/s |
| Fast mode, 16 threads | | 1594 H/s (scales badly, see below) |
| Dataset build (16 lanes) | 60 to 90 s | 4.1 to 4.4 s |

Overhead outside the machine code is about 180 µs per hash:
- Dart compile: 13 µs per program;
- Blake2b: 1.1 µs;
- fillAes1Rx4 of 2 MiB: 34 µs;
- two mprotect calls: 6 µs.

Only about 570 MB of the 2.1 GB dataset got transparent huge pages. THP is
in `madvise` mode here, and memory is fragmented.

## Update 2026-09-13 (morning)

Done since the first version of this file:

- **Code memory mapped RWX once** (`ExecMemory.allowRwx`, W^X fallback), like
  xmrig: 1 thread went from 417 to 598 H/s, 8 threads from 2021 to 2950 H/s.
- **Scratchpads** on fresh 2 MiB-aligned mmap pages with MADV_HUGEPAGE
  (`NativePages`).
- **Allocation-free hash path** (`RandomXJitVM.hashInto`,
  `Blake2b.reset/digestInto`).
- **`RandomXHasher` interface** (`vm.dart`), implemented by the interpreter
  and the JIT VM.
- **HashPool integration** (`jit:` flag):
  - workers create JIT VMs with a per-worker code offset;
  - the dataset is built with `JitDatasetInit` over all cores;
  - worker 0 self-tests JIT against the interpreter per seed and mode, with
    automatic fallback to the interpreter (`onJitSelfTest`,
    `jitDisabledReason`);
  - mining loops for 5 ms per event-loop turn.
- **Node integration:**
  - `NodeConfig.engine` (auto | jit | interpreter);
  - desktop defaults: fast mode, JIT and one thread per physical core
    (`CpuFeatures.physicalCores`);
  - the crash guard `jit_guard` in the data dir, cleared on self-test and on
    stop;
  - `NodeStatus.engine`;
  - `node_cli --engine`.
- **App:** engine setting and core hint (Settings), engine on Status; macOS
  Release entitlements get `allow-jit` and `network.client`.
- **Docs:** `THIRD_PARTY_NOTICES.md`, `docs/architecture.md` (engines section
  and numbers), README.
- **Tests:** 75 pass, including HashPool JIT tests. The opt-in fast-mode
  tests (`XMR_FAST_TEST=1`) pass as well.
- **Live node** (nano, fast mode, JIT, 8 threads):
  - both self-tests pass;
  - the dataset is ready in 5.6 s;
  - stable at 3000 to 3200 H/s (the interpreter did 96 to 127 H/s);
  - at the current share difficulty (about 121M) that is one share every 11
    hours on average.

16 threads still lose to 8 on this machine (about 2100 H/s). It is not the
Dart side: all 16 threads run at 100% and hashing allocates nothing. The
cause is SMT plus L3 and TLB pressure, with only about 40% of the dataset in
huge pages because this machine's memory is fragmented. The default is
therefore one thread per physical core.

## Update 2026-09-13 (late morning): ARM64 JIT done

- **ARM64 port:**
  - `asm_a64.dart`: the encoder;
  - `jit_a64.dart`:
    - `A64Templates`, which ports `jit_compiler_a64_static.S` with FPCR save/restore via `MemoryRegisters` +16/+20;
    - `JitA64`, which ports `jit_compiler_a64.cpp` plus tevador's ISUB_R 0x80000000 fix;
    - `installArm64CacheFlush`, a generated `dc cvau/ic ivau` routine for when `__clear_cache` is not exported;
  - ARMv8 AES routines in `aes_native.dart`.
- **`RandomXJitCompiler` interface** (`jit_compiler.dart`): the VM and dataset init pick x64 or ARM64.
- **Tests** (renamed `test/jit_test.dart`), now running on both architectures:
  - the tevador 1000-nonce benchmark cross-check (v1 and v2);
  - the Win64 thunk test (x86-64 only);
  - a synthetic-dataset fast-mode test (`XMR_FAST_TEST=1`);
  - the W^X fallback test.
- **ARM64 VM:** a qemu-system-aarch64 Debian VM, with its script in `scratchpad/armvm/vmctl.py` (`boot`, `setup`, `run 'cmd'`, `stop`; the share holds the Dart arm64 SDK and a copy of `xmr_core`).
  - All JIT tests pass, as do the HashPool JIT light tests.
  - The real fast-mode HashPool test was refused by the memory guard (the VM has 4 GB).
  - qemu does not model the icache, so test on a real device when one is available.

## Update 2026-09-13 (midday): Android and fixes

- **Android 14 x86_64 emulator** (Phone_API_34, started with `-qemu -cpu host` so AES is visible):
  - the JIT runs, with RWX mappings allowed;
  - the release app syncs and mines: 47 H/s on 1 thread in light mode.
- **Fixes found there:**
  - release builds lacked the INTERNET permission;
  - the app label was `xmr_miner`;
  - a stat card overflowed at phone width;
  - sidechain verification blocked the node isolate for minutes on a first sync (it now runs in slices);
  - old Monero blocks were re-relayed during sync;
  - failed dials flooded the log.
- **Known gap:** on Android the node stops when the activity is closed. Background mining needs a foreground service (the xprs host provides one; the standalone app still lacks it).
- **Long live run**, 10 hours, 8 threads, fast mode, JIT, log in `scratchpad/node_long.log`:
  - started at 11:15;
  - earlyoom stopped it at 11:18, when a one-off tool used memory at the same time;
  - restarted at 11:20;
  - mined for about an hour at 2500 to 2900 H/s (1700 H/s once the machine got busy), with no share;
  - at 12:21 earlyoom stopped it again, because browser processes took memory; it shut down cleanly.

  It was not restarted, since the machine was in active use. Rerun it when the PC is idle:
  `node_cli --threads 8 --fast --minutes 600`.

  Keep multi-GiB work (tests with caches, the ARM VM, the emulator) off the machine while it runs.
- **Share cache:** stored compact against the parent (`PoolBlock.serializeCompactAgainst` / `fillCompactFrom`), written hourly and on stop.
  - Live shares average 403 coinbase outputs and 34 transactions, so outputs dominate and compact saves only about 5% (71 to 68 MiB).
  - A real reduction needs pruned storage with outputs recomputed or served lazily: future work.

- **JIT without hardware AES:** v1 programs are JIT-compiled and the scratchpad AES runs in Dart (`RandomXJitVM(hardwareAes: false)`, tested). v2 on such CPUs uses an internal interpreter. Light-mode cost: 33 ms per hash against 24 ms with AES-NI.

- **Startup self-test:** worker 0 compares JIT and interpreter on an untouched 256 MiB buffer as soon as the pool starts (about 0.5 s, no Argon2), so the crash guard clears right away. Before this, swiping the Android app away before the first sync could have disabled the JIT.

## Update 2026-09-13 (afternoon): Android performance, points 1 and 2

- **`CpuTopology`:**
  - finds big cores by cpufreq clusters or by per-CPU core types;
  - uses the sysfs L3 or an estimate from core types (X-class 8 MiB, Oryon 12 MiB, A7x 4 MiB, all-little 1 MiB);
  - recommends big cores capped at L3 / 2 MiB;
  - is tested with Snapdragon 8 Gen 2, 778G, Tensor G1, an A53 octa-core and the Unisoc T606.
- **`CpuFeatures.recommendedThreads()`:** the topology result on ARM; one per physical core on x86-64.
- **`NodeConfig.defaults`:** phones with the JIT get these threads, plus fast mode when MemTotal is at least 7 GiB (8 GB phones).
- **App:** the thread hint explains the big-core rule on phones.
- **Checked on the emulator:** with 2 GB and 4 x86 cores it picks 4 threads and light mode.
- **Real phone** found on USB: OUKITEL C61, Unisoc UMS9230 (T606: 2 A75 plus 6 A55, both at 1.6 GHz), Android 15, 4 GB. It was not used, because the xprs app was in the foreground (probably another session). With the user's OK, run the JIT tests and a mining run on it. Expected default: 2 threads, light mode.
- **Not done (point 3, needs the user's OK for Kotlin):** a foreground service, wake lock, sustained performance mode and thermal throttling control.

## Update 2026-09-13 (evening): first real ARM64 hardware

OUKITEL C61 (Unisoc T606, Android 15, 4 GB), with the user's OK, via adb:
- **JIT:** self-tests pass on hardware (the icache flush works). Defaults: 2 threads, light mode, as the topology predicted.
- **Timing:** Monero synced in about 4 minutes; sidechain verification at about 6 shares/s.
- **Mining:** 28 to 35 H/s on 2 threads. The interpreter would do about 1 to 2 H/s per thread.
- **Bug found and fixed:** sliced verification did not slice when the added share was still pending, which made the node isolate unresponsive for minutes on the phone. Now covered by a random-order test.
- **Not done:** the 4 and 8 thread comparison. Another session brought the xprs app to the foreground on that phone, so phone input stopped. Redo the comparison when the phone is free.

## Native comparison (user asked why not native code)

- tevador RandomX v2.0.1 was built with NDK 28 (CMake, arm64, statically linked, `ARCH=default`, from `scratchpad/RandomX/build-android`).
- It ran via `adb shell` from `/data/local/tmp`, so the phone UI was not touched, and the binary was removed afterwards.
- Light mode (`--verify --jit`): 16.8 / 31.1 / 48.2 / 67.6 / 81.3 H/s on 1 / 2 / 4 / 6 / 8 threads.
- Our app did 28 to 35 H/s on 2 threads: the same as native. Native code would not make this phone faster.
- The little cores add a lot in light mode, so phones now default to all cores in light mode. The big-core rule is kept for fast mode.
- **Our app at 8 threads on the phone:** 70 to 92 H/s, averaging about 78 H/s over 9 minutes, sustained, with the node running (about 96% of native).
  - Mining started within a minute from the saved state.
  - The battery was at 33 C afterwards.
  - The xprs app was put back in the foreground.

## Android foreground service (user approved Kotlin)

- **Files:**
  - `MainActivity.kt`: a cached, process-wide engine (`shouldDestroyEngineWithHost = false`);
  - `MiningService.kt`: a `specialUse` foreground service, partial wake lock, a notification with the hashrate (updated every 10 s from Dart) and a Stop action;
  - `MiningChannel.kt`: the `xmr_miner/service` method channel, plus the notification permission request on Android 13 and later;
  - `ic_stat_mining.xml`;
  - manifest permissions: FOREGROUND_SERVICE, FOREGROUND_SERVICE_SPECIAL_USE, WAKE_LOCK, POST_NOTIFICATIONS;
  - Dart: `lib/mining_service.dart`, hooked into `AppController` start and stop.
- **Verified on the T606 phone:**
  - the service is foreground with type specialUse;
  - Home, screen off and forced deep Doze all keep 74 to 78 H/s, and the network keeps working in Doze;
  - Back (activity destroyed) keeps mining, and reopening attaches to the running node;
  - the notification's Stop action stops the node, the service and the notification.
- **Point 3 done** (thermal control and sustained performance mode below).

## Thermal control (user said "go ahead with the thermal control")

- **Core:** `node/thermal.dart` (`ThermalReading`, `ThermalGovernor`, thresholds in docs/architecture.md), `HashPool.setActiveWorkers(n)` (workers at or above `n` get `pause`; the rest get the job with stride `n`), `XmrNode.setActiveThreads`, `NodeHandle.setActiveThreads` (isolate command `threads`), `NodeStatus.maxThreads`. Tests: `test/thermal_test.dart` (governor steps and a pool test that changes the active workers while mining).
- **Android:** `MiningChannel.thermal()` returns `status` (API 29+), `headroom` (`getThermalHeadroom(10)`, API 30+) and `batteryC`; Dart `MiningService.thermal()`.
- **App:** `Settings.thermalControl` (default on; switch shown on Android only), a 10 s timer in `AppController._startThermalControl`, the Status card (`thermalNote`, `thermalReading`) and `Threads N of M`.
- **Verified on the phone** with `adb shell cmd thermalservice override-status 2|4` and `reset`: steps down, pauses, resumes on 1 thread and adds one per minute.
- **UI fixes found on the phone** (large font scale): the bottom bar clamps text scaling to 1.0 and the engine segment labels scale down instead of wrapping.
- **Crash on Stop fixed (found during this test, also in logcat at 18:11 and 19:01):** SIGSEGV (SEGV_MAPERR) in JIT code. `HashPool.stop` waited a fixed 50 ms, killed the workers and freed the cache, but a light-mode hash on the phone runs about 100 ms inside native code, which `Isolate.kill` cannot interrupt. Now each worker sends `exited` after leaving its loop, and the pool frees the cache and dataset only after every ack (after 10 s it leaks them instead). `XmrNode.stop` stops the pool first, so the 20 s handle deadline can no longer orphan mining workers. Verified: 4 Stops while mining at full speed on the phone, no crash. Desktop never showed it (a JIT light hash there is 16 ms, and the interpreter is pure Dart, which kill does interrupt).

## Sustained performance mode (user said "continue to sustained performance")

- **Kotlin:** `MiningChannel` methods `sustainedPerformanceSupported` (`PowerManager.isSustainedPerformanceModeSupported`, API 24+) and `sustainedPerformance` (`on`), which calls `Window.setSustainedPerformanceMode` on the current activity; `MainActivity.onResume` re-applies it to each new activity.
- **Dart:** `MiningService.sustainedPerformanceSupported()` and `sustainedPerformance(on)`; `Settings.sustainedPerformance` (default on); `AppController` asks for it on start when supported and releases it on stop.
- **Phone:** the T606 reports the mode as unsupported, so the switch is disabled with an explanation. Start and stop still run clean (no exception from releasing the mode). The on path could not be tested on real hardware here (Pixel phones offer the mode).
- **Not done, on purpose:** ADPF hint sessions (`PerformanceHintManager`). They tune clocks for bursty frame work. Mining threads already keep the CPU at 100%, and Dart isolates are not pinned to one OS thread, so the session's thread ids would go stale.

## Sidechain default is now mini (2026-09-13 evening)

The user objected to nano: they asked for P2Pool as Gupax uses it, and Gupax offers main and mini. Nano had been my own pick (lowest difficulty); I never asked. Defaults are now mini in `Settings`, `NodeConfig`, `NodeConfig.defaults` and `node_cli`; the Settings text under the sidechain buttons now describes the selected chain (it always said nano before). Live share difficulty at the switch: main 3.96 G, mini 246 M, nano 132 M.

Reward validation run, started 21:47:
- phone (T606, light mode JIT, 8 threads, about 75 H/s) on mini, wallet `44PTa648...ESXnB4fJ` (read from the phone's Settings);
- desktop `node_cli` AOT build (scratchpad `node_cli`), mini, same wallet, fast mode, 8 threads, data in `~/.local/share/xmr-dart-node/mini`, log in the session scratchpad `desktop_node.log`. Expected: one share about every 23 h at 3 kH/s.

## Flexible CPU/RAM mining (user asked for it, on by default)

- **Core:** `node/system_load.dart` (`SystemLoad.cpuTimes`, `parseLinux`, `otherCores`; Windows via kernel32), `node/flex.dart` (`FlexGovernor`, `FlexReading`, `lowMark`), `HashPool.setDatasetEnabled` / `hasDataset` / `datasetHeadroom`, `XmrNode._startFlex` and `_applyThreads` (thermal cap and flex cap, lower wins), `NodeConfig.flexible`, `NodeStatus.flexNote`, `node_cli --no-flexible`.
- **App:** `Settings.flexible` (default on) with a switch on every platform, a Status card, the notification reason.
- **Tests:** `test/flex_test.dart` (9: CPU steps, no flapping, full machine pauses, RAM give-back and slow return, critical pause, /proc parsing, other-cores math, real CPU times). The fast-mode pool test (`XMR_FAST_TEST=1`) now also gives the dataset back and rebuilds it; not run yet because this machine lacked 3.1 GB free while the live node ran.
- **Tuning found live:** the first desktop run built the dataset then gave it back seconds later; the build now needs the same room as a rebuild (dataset + 15% + 1 GiB). The low mark went from 20% to 15% (earlyoom here acts at 10%). Half a core of hysteresis stopped 5, 6, 5 thread flapping.
- **Not done:** macOS CPU sampling (`host_statistics`), lowering the miner's scheduling priority (Dart isolates are not pinned to OS threads, and on Linux a thread cannot raise its priority back without CAP_SYS_NICE).

## State at the end of 2026-09-13 (desktop suspended at the user's request)

- **Phone (C61, T606):** mining P2Pool mini to `44PTa648...ESXnB4fJ`, screen off (power key), 78 H/s on 8 threads, foreground service and wake lock holding. Its APK has flexible mining but not the last two dataset fixes (irrelevant there: 4 GB, light mode).
- **Desktop:** the Flutter Linux app (`apps/minerfan/build/linux/x64/release/bundle/minerfan`) mining mini with the same wallet, flexible mining at 4 to 5 of 8 threads, light mode (not enough free memory for the dataset while other sessions run). Data in `~/.local/share/xmr-dart/mini`; `node_cli`'s old data stays in `~/.local/share/xmr-dart-node/mini`. Suspended with the app still open; after resume the node reconnects to peers by itself.
- **To do next:**
  1. Check both for shares and payouts (desktop: `~/.local/share/minerfan/mini/shares.json` and `payouts.json`; phone: Rewards tab and notification).
  2. Rebuild the Linux app (window title, spinner after Start) and the phone APK (dataset retry and headroom), restart both.
  3. Run `XMR_FAST_TEST=1 dart test test/hash_pool_test.dart -n "dataset matches light mode"` when 3.1 GB are free (dataset given back and rebuilt).
  4. Ask the user whether the payout test should run without flexible mining (at 2.4 kH/s a mini share is about a day away, at 270 H/s about 10 days).

## minerfan UI (2026-09-14, user feedback)

- Renamed to minerfan (Android label and notification, Linux/Windows/macOS/iOS titles); package id and data folder unchanged.
- Black theme with an accent picker; three destinations (Dashboard, Miners, Settings); `Miner` abstraction for more miner kinds; per-miner page with tabs; app Settings with power profile (performance/balanced/eco), theme color, web server/API (placeholder), phone thermal and sustained switches.
- The stopped miner's power icon is a real button (starts it, or opens its settings without a wallet), as the user asked.
- Master Mining switch plus per-miner switches (state saved; the app resumes mining at start when it was on). Data folder renamed to `minerfan` with a one-time move of `xmr-dart`. Verified on desktop (resumed at 4 kH/s after relaunch) and phone (resumed after `am force-stop` and reopen).
- Desktop UI testing runs on a private Xvfb display (`Xvfb :77`, `DISPLAY=:77 xdotool`/`import -window root`) so it never touches the user's screen; the desktop miner app runs there too.

## Phone restart after kills (2026-09-14)

- Cause seen overnight: at 23:30 the process got SIGKILL (exit-info reason SIGNALED, importance 125, foreground service) with no restart, most likely the Unisoc battery manager; the service was START_NOT_STICKY.
- Fix: `MinerEngine` (headless engine start), sticky `MiningService` with a RESUME path, `MiningWatchdog` (JobScheduler, 15 min, persisted), `MiningBootReceiver` (BOOT_COMPLETED, MY_PACKAGE_REPLACED), battery exemption request (once at first start, and Settings > Background mining). Permissions: RECEIVE_BOOT_COMPLETED, REQUEST_IGNORE_BATTERY_OPTIMIZATIONS.
- Tests on the phone: update resume (no app opened, mining in 40 s), `am crash` (restart by Android in about 20 s, mining in 30 s), watchdog forced after a crash (back in 2 s), exemption granted through the in-app dialog (`dumpsys deviceidle whitelist` lists the app). Still to see: a night with the screen off.

## Rename to minerfan and desktop integration (2026-09-14)

- Repo folder `~/code/2026/minerfan` (a link from `xmr-dart` keeps old paths working), app `apps/minerfan`, Dart package `minerfan`, binaries `minerfan`, app id `app.minerfan` on Android, Linux, macOS and iOS (user's choice; on Android it is a new app, so the old `dev.xmrdart.xmr_miner` must be uninstalled and the wallet address entered again). Kotlin package `app.minerfan`, channels `minerfan/service` and `minerfan/window`. The Monero library keeps its name (`packages/xmr_core`).
- Linux runner: the close button minimizes (delete-event), one instance only (a second launch presents the running window), `--minimized` for autostart, window channel with quit/minimize/show. `lib/desktop.dart` installs the launcher (`~/.local/share/applications/app.minerfan.desktop`), the icon (`assets/icon/minerfan.svg`) and the autostart entry (Settings, Start with the computer, on by default); Settings has Quit minerfan.
- Installed with `apps/minerfan/tool/install_linux.sh` into `~/.local/opt/minerfan`, pinned to the GNOME dock (favorite-apps). Do not rebuild over a running copy: install only after quitting.
- Unexplained: at 16:09 the desktop app (then run from the build folder) aborted with Skia `ParagraphBuilderImpl.cpp: check(fUnicode)`; typing accented text did not reproduce it.
- Phone: waiting for adb to install `app.minerfan`, enter the wallet, switch mining on, allow background mining, uninstall the old app.

## Remaining work, in order (updated)

1. **Long live run** for a share: hours at about 3 kH/s on nano. Check
   `free -m` first. Confirm that peers accept the share (log line
   `found share ... accepted`) and that it shows up in the window counts.
2. **x64 extras**
   - Fused `hashAndFillAes1Rx4` pipelining (tevador `randomx_calculate_hash_first/next`).
   - A Win64 prologue test through a SysV-to-Win64 thunk (`X64Templates(win64: true)`).
   - The tevador benchmark cross-check test (see above).
   - A v2 soft-AES loop store for CPUs without AES (their v2 hashes use the interpreter; v1 already uses the JIT with Dart AES).
3. **ARM64 JIT**: done and verified under qemu. Check it on real hardware (Android phone, Apple Silicon) when available.
4. **Android**: done on the emulator and the T606 phone, with the foreground service, thermal control and sustained performance mode.
5. **App**: open the Linux build and check the engine setting and status.

## Context from earlier sessions still pending

- Mempool transactions in templates (coinbase-only today).
- Monero v17 (RandomX v2 selection by height, commitment, Carrot outputs).
- The share cache is 76 MB on disk (full serialization); a compact form would help phones.
- xprs integration per `docs/xprs-integration.md`: read xprs `docs/architecture.md` and `docs/performance.md` and run `dart tool/arch_guard.dart` when touching xprs.
- The Flutter Linux app was opened and checked on 2026-09-13 at 22:56: it mines P2Pool mini with the JIT and flexible mining (Status, P2Pool, Monero, Log and Settings all render; screenshots sent to the user). It replaced `node_cli` as the desktop miner, with `node_cli`'s state copied to `~/.local/share/xmr-dart/mini`. Fixed after the check (in the next build): the window title said `xmr_miner`, and pages showed "stopped" for about 2 s after Start.

## Checks before declaring anything done

```sh
cd packages/xmr_core && dart analyze && dart test     # 94 tests, 3 skipped
cd apps/minerfan && flutter analyze
```

Style rule for docs and UI text: no em/en dashes, arrows or curly quotes.
