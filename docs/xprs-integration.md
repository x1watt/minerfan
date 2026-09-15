# Running minerfan inside xprs

Rules from `~/code/xprs/app/docs/architecture.md` and `performance.md` that
shape this:

- Every wapp engine runs on the UI isolate. Hashing, share verification and
  curve arithmetic must never run in `module_tick`.
- Pure heavy CPU belongs on a long-lived worker isolate with a bounded queue
  and a `perf:` counter (performance.md 8.1).
- Continuous work rides the existing foreground service and the native
  heartbeat, and respects the power tier (performance.md 8.2, 8.11).
- Transports are core. A wapp only calls `hal_*`.

## Shape

1. `xmr_core` becomes a path dependency of the app, like `reticulum-dart`.
2. App side, `lib/services/xmr/minerfan_service.dart`: a `BackgroundService`
   subclass that owns a `NodeHandle` (the node isolate plus RandomX worker
   isolates). Pattern: `I2pBackgroundService` (`onPause` stops mining,
   `onResume` restarts it). It adds a `perf: xmr-node` line to
   `TaskMonitorService.startCpuSummary`, takes `hold('xmr')` on the
   foreground service while mining, and pauses in the battery and low power
   tiers.
3. Sockets: the node's `Transport` interface is implemented over the app's
   own socket layer instead of `IoTransport` if the app wants all sockets in
   core; otherwise the node isolate uses `dart:io` directly.
4. Wapp `wapps/xmrminer/`: a thin C bridge plus GeoUI screens, like the
   Wallet wapp. It sends `xmr.*` messages (`xmr.status`, `xmr.start`,
   `xmr.stop`, `xmr.set` with wallet, sidechain, threads) through
   `hal_msg_send`, answered by `app/lib/wapp/xmr/xmr_host_bridge.dart` in the
   `CoinHostBridge` pattern. Manifest: `requires.hal: ["log","msg","kv"]`,
   tick 60000 ms, no socket permission (the core owns the network).
5. Before the work: re-read both xprs docs and run `dart tool/arch_guard.dart`.

## Web

Flutter web has no TCP sockets and no isolates, so the node cannot run in a
browser build of xprs. The wapp there can only show status from another
device.
