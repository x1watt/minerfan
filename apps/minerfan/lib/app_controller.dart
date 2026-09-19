import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:crypto_core/crypto_core.dart' show Bip39;
import 'package:pow_core/pow_core.dart' show GpuCheck, ScryptPow, cpuHashrate, gpuSelfTest;
import 'package:xmr_core/xmr_core.dart';

import 'catalog.dart';
import 'contacts/contact_book.dart';
import 'chains/monero_chain.dart';
import 'chains/utxo_chain.dart';
import 'desktop.dart';
import 'miners/miner.dart';
import 'miners/monero_miner.dart';
import 'miners/utxo_miner.dart';
import 'mining_service.dart';
import 'network/private_network.dart';
import 'moderation/admin.dart';
import 'moderation/config.dart';
import 'network/rooms.dart';
import 'prices.dart';
import 'shop/shop.dart';
import 'theme.dart';
import 'wallets/device_key.dart';
import 'wallets/keyed_wallet.dart';
import 'wallets/monero_wallet.dart';
import 'wallets/utxo_wallet.dart';
import 'wallets/wallet.dart';

/// How hard the miners may use the machine.
enum PowerProfile {
  /// Every configured thread, no stepping aside.
  performance,

  /// Flexible CPU/RAM mining: mines in idle time, steps aside for other
  /// programs (the default).
  balanced,

  /// Flexible, and half the configured threads: cooler and quieter.
  eco,
}

/// What the window's close button does on the desktop.
enum CloseAction {
  /// Ask each time: keep mining in the dock, or quit.
  ask,

  /// Keep mining: the window goes to the dock.
  dock,

  /// Stop the miners and quit.
  quit,
}

/// App-wide settings (`app.json`); each miner keeps its own.
class AppSettings {
  PowerProfile power;
  int accent;
  bool thermalControl;
  bool sustainedPerformance;
  bool apiEnabled;
  int apiPort;

  /// The master switch: while on, every enabled miner runs (and resumes
  /// when the app starts again).
  bool miningOn;

  /// Each miner's own switch, by miner id (missing means enabled).
  Map<String, bool> minerEnabled;

  /// Whether the battery optimization exemption was asked for (Android asks
  /// once on the first start; Settings can ask again).
  bool askedBattery;

  /// Desktop: start minimized in the dock when the user logs in.
  bool startWithComputer;

  /// Desktop: what the window's close button does.
  CloseAction closeAction;

  /// Monero node whose RPC gives decoys and fees for sending.
  String moneroNode;

  /// Run this app's I2P node (on by default on desktops; phones join when
  /// the user turns it on, for data and battery).
  bool i2pEnabled;

  /// Wallets the app made or listed by itself, once: `app-wallet:<chain>`
  /// (the wallet every mined coin gets) and `watch:<address>` (the Monero
  /// payout address). Once made, removing them is final.
  Set<String> autoWallets;

  /// The coin chat rooms the user is in (XPRS room names such as `MONERO`):
  /// joined by opening a miner's Chat tab or by mining the coin.
  Set<String> rooms;

  AppSettings({
    this.power = PowerProfile.balanced,
    int? accent,
    this.thermalControl = true,
    this.sustainedPerformance = true,
    this.apiEnabled = false,
    this.apiPort = 8710,
    this.miningOn = false,
    Map<String, bool>? minerEnabled,
    this.askedBattery = false,
    this.startWithComputer = true,
    this.closeAction = CloseAction.ask,
    String? moneroNode,
    bool? i2pEnabled,
    Set<String>? autoWallets,
    Set<String>? rooms,
  })  : autoWallets = autoWallets ?? {},
        rooms = rooms ?? {},
        moneroNode = moneroNode ?? MoneroRpc.defaultNodes.first,
        i2pEnabled = i2pEnabled ?? !(Platform.isAndroid || Platform.isIOS),
        accent = accent ?? accentColors.first.$2,
        minerEnabled = minerEnabled ?? {};

  Map<String, Object?> toJson() => {
    'power': power.name,
    'accent': accent,
    'thermalControl': thermalControl,
    'sustainedPerformance': sustainedPerformance,
    'apiEnabled': apiEnabled,
    'apiPort': apiPort,
    'miningOn': miningOn,
    'minerEnabled': minerEnabled,
    'askedBattery': askedBattery,
    'startWithComputer': startWithComputer,
    'closeAction': closeAction.name,
    'moneroNode': moneroNode,
    'i2pEnabled': i2pEnabled,
    'autoWallets': autoWallets.toList()..sort(),
    'rooms': rooms.toList()..sort(),
  };

  static AppSettings fromJson(Map<String, Object?> m) => AppSettings(
    power: PowerProfile.values.asNameMap()[m['power']] ?? PowerProfile.balanced,
    accent: m['accent'] as int?,
    thermalControl: (m['thermalControl'] as bool?) ?? true,
    sustainedPerformance: (m['sustainedPerformance'] as bool?) ?? true,
    apiEnabled: (m['apiEnabled'] as bool?) ?? false,
    apiPort: (m['apiPort'] as int?) ?? 8710,
    miningOn: (m['miningOn'] as bool?) ?? false,
    askedBattery: (m['askedBattery'] as bool?) ?? false,
    startWithComputer: (m['startWithComputer'] as bool?) ?? true,
    closeAction: CloseAction.values.asNameMap()[m['closeAction']] ?? CloseAction.ask,
    moneroNode: m['moneroNode'] as String?,
    i2pEnabled: m['i2pEnabled'] as bool?,
    autoWallets: {for (final a in (m['autoWallets'] as List?) ?? const []) '$a'},
    rooms: {for (final r in (m['rooms'] as List?) ?? const []) '$r'},
    minerEnabled: {for (final e in ((m['minerEnabled'] as Map?) ?? const {}).entries) '${e.key}': e.value == true},
  );
}

/// App data directory without platform plugins: XDG/HOME on Linux and
/// macOS, APPDATA on Windows, and next to the app's temp dir on mobile.
String appDataDir([String name = 'minerfan']) {
  final env = Platform.environment;
  if (Platform.isWindows) return '${env['APPDATA'] ?? Directory.systemTemp.path}\\$name';
  if (Platform.isLinux) return '${env['XDG_DATA_HOME'] ?? '${env['HOME']}/.local/share'}/$name';
  if (Platform.isMacOS) return '${env['HOME']}/Library/Application Support/$name';
  // Android: /data/user/0/<pkg>/cache -> /data/user/0/<pkg>/files.
  // iOS: <container>/tmp -> <container>/Library.
  final tmp = Directory.systemTemp.parent.path;
  return Platform.isIOS ? '$tmp/Library/$name' : '$tmp/files/$name';
}

/// Moves the data folder of the app's first name (`xmr-dart`) to
/// `minerfan` once, keeping settings, the synced chains and the history.
void migrateDataDir() {
  try {
    final old = Directory(appDataDir('xmr-dart'));
    final now = Directory(appDataDir());
    if (old.existsSync() && !now.existsSync()) old.renameSync(now.path);
  } catch (_) {}
}

/// The app: its settings, the miners, and the Android foreground service
/// that keeps them running while any of them mines.
class AppController extends ChangeNotifier {
  late final String dataDir = appDataDir();
  AppSettings settings = AppSettings();
  late final MoneroMiner monero = MoneroMiner(this);

  /// Bitcoin-family chains, by coin id: each runs its own light node for
  /// its miner and wallets.
  late final Map<String, UtxoChain> chains = {
    for (final c in [cryptoescudoCoin]) c.id: UtxoChain(c, '$dataDir/${c.id}'),
  };
  late final UtxoMiner cryptoescudo = UtxoMiner(this, chains['cryptoescudo']!);

  /// This app's I2P node (for private client-to-client messages later).
  late final PrivateNetwork privateNetwork = PrivateNetwork(dataDir)
    ..addListener(notifyListeners)
    ..addListener(() {
      if (!identical(privateNetwork.link, _syncedLink)) _syncLinkContacts();
    });

  /// What this device sells (`shop.json`), its cart and its takings.
  late final Shop shop = Shop(dataDir)..addListener(notifyListeners);

  /// The address book (`contacts.json`) and this device's own card.
  late final ContactBook contacts = ContactBook(dataDir)
    ..addListener(notifyListeners)
    ..addListener(_syncLinkContacts);

  Object? _syncedLink;

  /// Contacts reach this device over I2P as XPRS stations: their keys verify
  /// what they send and they get receipts (docs/architecture.md).
  void _syncLinkContacts() {
    final link = _syncedLink = privateNetwork.link;
    if (link == null) return;
    for (final c in contacts.contacts) {
      final i2p = c.fieldsOf('i2p').firstOrNull?.value.trim();
      try {
        link.addContact(c.npub, b32: i2p == null || i2p.isEmpty ? null : i2p);
      } catch (_) {}
    }
  }

  /// Monero wallets' service (created after the settings load).
  late final MoneroChain moneroChain = MoneroChain('$dataDir/monero-wallet', node: settings.moneroNode)
    ..addListener(notifyListeners);

  List<Miner> get miners => [monero, cryptoescudo];

  /// Each mined coin's chat room (docs/architecture.md, "Coin rooms").
  late final RoomService rooms = RoomService(
    dataDir: dataDir,
    net: privateNetwork,
    contacts: contacts,
    joined: () => settings.rooms,
    coins: [for (final m in miners) (m.id, m.name)],
    admin: ModerationAdmin(wallets: () => wallets, dataDir: dataDir, log: privateNetwork.note),
  )..addListener(notifyListeners);

  ChatRoom? roomFor(Miner m) => rooms.roomFor(m.id);

  /// Joins [m]'s room for good: it goes online whenever the private network
  /// runs.
  void joinRoom(Miner m) {
    final r = roomFor(m);
    if (r == null || !settings.rooms.add(r.name)) return;
    save();
    rooms.sync();
  }

  void leaveRoom(Miner m) {
    final r = roomFor(m);
    if (r == null || !settings.rooms.remove(r.name)) return;
    save();
    rooms.sync();
  }

  /// OpenCL GPUs of this device (desktop drivers, and phones whose vendor
  /// lets apps load `libOpenCL.so`, such as Mali and Adreno phones).
  List<String> gpus = const [];

  /// Why GPU mining is off although a GPU may exist, or null.
  String? gpuNote;

  /// Every GPU's self-test (its scrypt against the CPU's, and its speed).
  List<GpuCheck> gpuChecks = const [];

  /// scrypt hashes per second on one CPU thread of this device.
  double cpuScryptRate = 0;

  File get _gpuGuard => File('$dataDir/gpu-probe.guard');

  /// Lists the GPUs on a helper isolate. A vendor driver that crashes
  /// takes the app down with it, so a guard file marks the probe: if it is
  /// still there at the next start, GPU mining stays off until the user
  /// asks to try again.
  Future<void> _probeGpus() async {
    try {
      cpuScryptRate = await Isolate.run(() => cpuHashrate(ScryptPow.new));
    } catch (_) {}
    if (Platform.isIOS) return;
    if (_gpuGuard.existsSync()) {
      gpuNote = 'Checking the GPU stopped the app last time, so GPU mining is off. You can try again.';
      return;
    }
    try {
      _gpuGuard.writeAsStringSync(DateTime.now().toIso8601String());
      gpuChecks = await Isolate.run(gpuSelfTest);
      // Only GPUs whose results match the CPU's mine.
      gpus = [for (final c in gpuChecks) if (c.ok) c.name];
      debugPrint('GPU self-test: ${gpuChecks.isEmpty ? 'no OpenCL GPU' : gpuChecks.join('; ')}');
      final bad = gpuChecks.where((c) => !c.ok).toList();
      if (gpus.isEmpty && bad.isNotEmpty) gpuNote = 'The GPU failed its self-test (${bad.first}), so it does not mine.';
    } catch (e) {
      gpus = const [];
      debugPrint('GPU self-test: $e');
    } finally {
      try {
        _gpuGuard.deleteSync();
      } catch (_) {}
    }
  }

  /// Clears a failed GPU check and probes again.
  Future<void> retryGpus() async {
    try {
      if (_gpuGuard.existsSync()) _gpuGuard.deleteSync();
    } catch (_) {}
    gpuNote = null;
    await _probeGpus();
    notifyListeners();
  }

  /// What can be mined with what hardware (assets/mining_catalog.json).
  MiningCatalog catalog = MiningCatalog.empty;
  late final PriceService prices = PriceService(() => catalog);

  /// The user's wallets (`wallets.json`), independent from the miners.
  final List<Wallet> wallets = [];

  /// Whether this device offers Android's sustained performance mode.
  bool sustainedSupported = false;

  File get _file => File('$dataDir/app.json');
  File get _walletsFile => File('$dataDir/wallets.json');

  AppController() {
    for (final m in [monero, cryptoescudo]) {
      m.addListener(notifyListeners);
      // Mining a coin joins its room.
      m.addListener(() {
        if (m.running && _loaded) joinRoom(m);
      });
    }
    for (final c in chains.values) {
      c.addListener(notifyListeners);
    }
    MiningService.listen(stopAll);
  }

  int get runningCount => miners.where((m) => m.running).length;

  bool _loaded = false;

  Future<void> load() async {
    if (kDebugMode) {
      // Diagnostics on new devices: does the RandomX JIT run here?
      unawaited(
        Isolate.run(
          jitSelfCheck,
        ).then((r) => debugPrint('JIT self-check: $r'), onError: (Object e) => debugPrint('JIT self-check failed: $e')),
      );
    }
    try {
      catalog = MiningCatalog.parse(await rootBundle.loadString('assets/mining_catalog.json'));
    } catch (e) {
      debugPrint('mining catalog: $e');
    }
    Map<String, Object?>? legacy;
    try {
      Directory(dataDir).createSync(recursive: true);
      legacy = monero.load();
      if (_file.existsSync()) {
        settings = AppSettings.fromJson(jsonDecode(_file.readAsStringSync()) as Map<String, Object?>);
      } else if (legacy != null) {
        // Settings from before the app had its own file.
        settings = AppSettings(
          power: legacy['flexible'] == false ? PowerProfile.performance : PowerProfile.balanced,
          thermalControl: (legacy['thermalControl'] as bool?) ?? true,
          sustainedPerformance: (legacy['sustainedPerformance'] as bool?) ?? true,
        );
      }
    } catch (_) {}
    await _probeGpus();
    cryptoescudo.load();
    try {
      deviceKey = DeviceKey.loadOrCreate(dataDir);
    } catch (e) {
      debugPrint('device key: $e');
    }
    _loadWallets();
    await _ensureWallets();
    await contacts.load();
    await shop.load();
    unawaited(privateNetwork.keys().then((_) {}, onError: (Object e) => debugPrint('network keys: $e')));
    _loaded = true;
    // The rooms' admin and addresses, from this profile's file when it has
    // one, before any room opens.
    if (await ModerationConfig.loadProfile() case final note?) privateNetwork.note(note);
    unawaited(rooms.start().catchError((Object e) => debugPrint('rooms: $e')));
    Desktop.integrate(startWithComputer: settings.startWithComputer);
    unawaited(Desktop.setCloseAction(settings.closeAction.name));
    if (settings.i2pEnabled) unawaited(privateNetwork.start());
    sustainedSupported = await MiningService.sustainedPerformanceSupported();
    notifyListeners();
    // The master switch was on when the app last ran (closed, killed by
    // the system, or the device restarted): mine again.
    if (settings.miningOn) await setMiningOn(true);
  }

  void _loadWallets() {
    try {
      if (_walletsFile.existsSync()) {
        for (final w in jsonDecode(_walletsFile.readAsStringSync()) as List) {
          final m = w as Map<String, Object?>;
          final chain = chains[m['chain']];
          if (m['chain'] == 'monero' && m['secret'] != null) {
            final w = MoneroWallet.fromJson(m, moneroChain, deviceKey);
            wallets.add(w);
            if (!w.hasPassword) unawaited(_openMonero(w));
          } else if (m['chain'] == 'monero') {
            wallets.add(MoneroWatchWallet.fromJson(m));
          } else if (chain != null) {
            final w = UtxoWallet.fromJson(m, chain, deviceKey);
            wallets.add(w);
            unawaited(chain.openWallet(w.id, w.xpub, w.birthday));
          }
        }
      }
    } catch (_) {}
    // Wallets listed before the app remembered what it made itself count as
    // made: removing one of them must not bring a new one back.
    if (moneroAppWallet != null) settings.autoWallets.add('app-wallet:monero');
    for (final w in wallets) {
      settings.autoWallets.add(w is MoneroWatchWallet ? 'watch:${w.address}' : 'app-wallet:${w.chain}');
    }
    // The address the Monero miner pays is a wallet of the user's (listed
    // once; the user may remove it).
    final mining = monero.settings.wallet.trim();
    if (validMoneroAddress(mining) && settings.autoWallets.add('watch:$mining')) {
      if (!wallets.any((w) => w.address == mining)) {
        wallets.add(MoneroWatchWallet(id: _nextId('monero'), label: 'Monero (mining)', address: mining));
        saveWallets();
      }
    }
    save();
  }

  String _nextId(String chain) {
    var n = wallets.length + 1;
    while (wallets.any((w) => w.id == '$chain-$n')) {
      n++;
    }
    return '$chain-$n';
  }

  Future<void> _openMonero(MoneroWallet w, {String? password}) async {
    try {
      await moneroChain.open(w, password: password);
    } catch (e) {
      debugPrint('monero wallet ${w.id}: $e');
      if (password != null) rethrow;
    }
  }

  /// Opens a Monero wallet that has a password (its keys stay sealed until
  /// then). Throws for a wrong password.
  Future<void> unlockMonero(MoneroWallet w, String password) => _openMonero(w, password: password);

  /// The app's own Monero wallet (full keys), if any.
  MoneroWallet? get moneroAppWallet =>
      wallets.whereType<MoneroWallet>().where((w) => !w.viewOnly).firstOrNull;

  /// Creates a new Monero wallet (sealed with [password] or the device key).
  Future<String?> createMoneroWallet(String label, {String? password}) async {
    final (words, address) = await MoneroWallet.generate();
    return _addMonero(label, address, words, viewOnly: false, birthday: -1, password: password);
  }

  /// Restores a Monero wallet from its 25 recovery words.
  Future<String?> restoreMoneroWallet(String label, String words, {String? password}) async {
    final address = await MoneroWallet.addressOfWords(words);
    if (address == null) return 'Not valid Monero recovery words (25 English words)';
    final normalized = words.trim().toLowerCase().split(RegExp(r'\s+')).join(' ');
    return _addMonero(label, address, normalized, viewOnly: false, birthday: 0, password: password);
  }

  /// A view-only Monero wallet: an address and its private view key (it
  /// sees incoming payments, P2Pool payouts included).
  Future<String?> addMoneroViewKey(String label, String address, String viewKey, {String? password}) async {
    if (!validMoneroAddress(address)) return 'Not a valid Monero mainnet address';
    if (!await MoneroWallet.viewKeyMatches(address, viewKey)) return 'This is not the private view key of the address';
    // Replaces the address-only entry of the same address.
    wallets.removeWhere((w) => w is MoneroWatchWallet && w.address == address.trim());
    return _addMonero(label, address.trim(), viewKey.trim().toLowerCase(), viewOnly: true, birthday: 0, password: password);
  }

  Future<String?> _addMonero(String label, String address, String secretText,
      {required bool viewOnly, required int birthday, String? password}) async {
    if (wallets.any((w) => w is MoneroWallet && w.address == address)) return 'This wallet is already listed';
    final w = MoneroWallet(
      id: _nextId('monero'),
      label: label.trim().isEmpty ? (viewOnly ? 'Monero (view-only)' : 'Monero') : label.trim(),
      address: address,
      viewOnly: viewOnly,
      birthday: birthday,
      service: moneroChain,
      secret: await KeyedWallet.seal(secretText, password: password, deviceKey: deviceKey),
      deviceKey: deviceKey,
      backedUp: viewOnly || birthday == 0,
    );
    wallets.add(w);
    saveWallets();
    unawaited(_openMonero(w, password: password));
    notifyListeners();
    return null;
  }

  /// Writes `wallets.json` (after a wallet changed its label, password or
  /// backup state).
  void saveWallets() {
    try {
      Directory(dataDir).createSync(recursive: true);
      _walletsFile.writeAsStringSync(jsonEncode([for (final w in wallets) w.toJson()]));
    } catch (_) {}
  }

  /// Adds a Monero address to watch (no keys). Returns an error or null.
  String? addWallet(String chain, String label, String address) {
    final a = address.trim();
    if (chain != 'monero' || !validMoneroAddress(a)) return 'Not a valid Monero mainnet address';
    if (wallets.any((w) => w.address == a)) return 'This wallet is already listed';
    wallets.add(MoneroWatchWallet(id: _nextId('monero'), label: label.trim().isEmpty ? 'Monero' : label.trim(), address: a));
    saveWallets();
    notifyListeners();
    return null;
  }

  /// The first address of the first wallet of a chain (a miner's default
  /// payout address), or null.
  String? firstWalletAddress(String chain) {
    for (final w in wallets) {
      if (w.chain == chain) return w is UtxoWallet ? w.firstAddress : w.address;
    }
    return null;
  }

  /// Seals the phrases of wallets without a password.
  Uint8List deviceKey = Uint8List(32);

  /// Every coin the app mines gets a wallet without asking: the phrase the
  /// Cryptoescudo command-line miner left in plain text (its mined coins)
  /// is imported and the file deleted; otherwise a new wallet is created.
  /// No password is needed (the device key seals the phrase); the wallet
  /// page reminds the user to write the phrase down and offers a password.
  ///
  /// Only once per coin (`AppSettings.autoWallets`): a wallet the user
  /// removed stays removed.
  Future<void> _ensureWallets() async {
    if (moneroAppWallet == null && !settings.autoWallets.contains('app-wallet:monero')) {
      try {
        await createMoneroWallet('Monero');
        settings.autoWallets.add('app-wallet:monero');
      } catch (e) {
        debugPrint('monero: no wallet created: $e');
      }
    }
    for (final chain in chains.values) {
      final coin = chain.coin;
      if (wallets.any((w) => w.chain == coin.id) || settings.autoWallets.contains('app-wallet:${coin.id}')) continue;
      try {
        final legacy = File('$dataDir/${coin.id}/wallet-mnemonic.txt');
        if (legacy.existsSync()) {
          final e = await addUtxoWallet(coin, coin.name, legacy.readAsStringSync(), restore: true);
          if (e == null) {
            legacy.deleteSync();
            settings.autoWallets.add('app-wallet:${coin.id}');
            continue;
          }
          debugPrint('${coin.id}: the old phrase file was not imported: $e');
        }
        if (await addUtxoWallet(coin, coin.name, Bip39.generate(words: 12), restore: false) == null) {
          settings.autoWallets.add('app-wallet:${coin.id}');
        }
      } catch (e) {
        debugPrint('${coin.id}: no wallet created: $e');
      }
    }
    save();
  }

  /// Creates (a new phrase) or restores a wallet of a Bitcoin-family coin,
  /// its phrase sealed with [password] or, without one, the device key.
  /// Returns an error or null.
  Future<String?> addUtxoWallet(
    UtxoCoin coin,
    String label,
    String mnemonic, {
    String? password,
    required bool restore,
    bool backedUp = false,
  }) async {
    if (!Bip39.valid(mnemonic)) return 'Not a valid recovery phrase (BIP39, English words)';
    final sealed = await UtxoWallet.seal(coin, mnemonic, password: password, deviceKey: deviceKey);
    if (wallets.any((w) => w is UtxoWallet && w.xpub == sealed.xpub)) return 'This wallet is already listed';
    final chain = chains[coin.id]!;
    var n = wallets.length + 1;
    while (wallets.any((w) => w.id == '${coin.id}-$n')) {
      n++;
    }
    // A new phrase has no history, so scanning starts near the tip; a
    // restored one scans from the checkpoint.
    final birthday = restore ? 0 : (chain.status?.tip ?? coin.heightNowAtMost());
    final w = UtxoWallet(
      id: '${coin.id}-$n',
      label: label.trim().isEmpty ? coin.name : label.trim(),
      service: chain,
      xpub: sealed.xpub,
      birthday: birthday,
      firstAddress: sealed.firstAddress,
      secret: sealed.secret,
      deviceKey: deviceKey,
      backedUp: backedUp,
    );
    wallets.add(w);
    saveWallets();
    unawaited(chain.openWallet(w.id, w.xpub, w.birthday));
    notifyListeners();
    return null;
  }

  void renameWallet(Wallet w, String label) {
    w.label = label;
    saveWallets();
    notifyListeners();
  }

  /// Removes a wallet for good: its sealed keys leave `wallets.json` and
  /// its scan state (`wallet-<id>.json`) is deleted, so a later wallet that
  /// reuses the id starts clean. The app never recreates it.
  Future<void> removeWallet(Wallet w) async {
    wallets.remove(w);
    saveWallets();
    notifyListeners();
    File? state;
    try {
      if (w is UtxoWallet) {
        await w.service.closeWallet(w.id);
        state = File('$dataDir/${w.chain}/wallet-${w.id}.json');
      } else if (w is MoneroWallet) {
        await moneroChain.close(w.id);
        state = File('$dataDir/monero-wallet/wallet-${w.id}.json');
      }
      if (state != null && await state.exists()) await state.delete();
    } catch (e) {
      debugPrint('remove ${w.id}: $e');
    }
  }

  /// The miner that pays [w] because its address was typed in the miner's
  /// settings (not the automatic choice), or null. Removing such a wallet
  /// would leave the miner paying an address whose keys are gone.
  String? minerPaying(Wallet w) {
    final addresses = {w.address, if (w is UtxoWallet) w.firstAddress};
    if (monero.settings.wallet.trim().isNotEmpty && addresses.contains(monero.settings.wallet.trim())) return monero.name;
    if (cryptoescudo.settings.payTo.trim().isNotEmpty && addresses.contains(cryptoescudo.settings.payTo.trim())) {
      return cryptoescudo.name;
    }
    return null;
  }

  void save() {
    try {
      Directory(dataDir).createSync(recursive: true);
      _file.writeAsStringSync(jsonEncode(settings.toJson()));
    } catch (_) {}
    notifyListeners();
  }

  bool isEnabled(Miner m) => settings.minerEnabled[m.id] ?? true;

  /// The master switch: on starts every enabled miner, off stops them all
  /// (their own switches keep their state).
  Future<void> setMiningOn(bool on) async {
    settings.miningOn = on;
    save();
    for (final m in miners) {
      if (on && isEnabled(m) && m.canStart && !m.running) {
        await m.start();
      } else if (!on && m.running) {
        await m.stop();
      }
    }
  }

  /// One miner's own switch. Turning a miner on also turns the master
  /// switch on; turning the last one off turns it off.
  Future<void> setMinerOn(Miner m, bool on) async {
    settings.minerEnabled[m.id] = on;
    if (on) settings.miningOn = true;
    if (!on && !miners.any((x) => x != m && isEnabled(x) && x.running)) settings.miningOn = false;
    save();
    if (on && !m.running) await m.start();
    if (!on && m.running) await m.stop();
  }

  /// Called by a miner when it starts: the first one starts the Android
  /// foreground service (notification, wake lock).
  Future<void> minerStarted(String text) async {
    await MiningService.requestNotificationPermission();
    await MiningService.start(text);
    // Once: without the exemption, Android and vendor battery managers
    // kill the miner more readily and it cannot restart in the background.
    if (MiningService.supported && !settings.askedBattery) {
      if (await MiningService.requestBatteryExemption()) {
        settings.askedBattery = true;
        save();
      }
    }
    if (settings.sustainedPerformance && sustainedSupported) await MiningService.sustainedPerformance(true);
  }

  /// Called by a miner when it stops: the last one stops the service.
  Future<void> minerStopped() async {
    if (miners.any((m) => m.running)) return;
    await MiningService.sustainedPerformance(false);
    await MiningService.stop();
  }

  /// Stops the miners (saving their state) and ends the app. The window's
  /// close button only minimizes it.
  Future<void> quit() async {
    for (final m in miners) {
      await m.stop();
    }
    for (final c in chains.values) {
      await c.stop();
    }
    await moneroChain.stop();
    await rooms.close();
    privateNetwork.stop();
    await Desktop.quit();
  }

  Future<void> setMoneroNode(String url) async {
    settings.moneroNode = url.trim();
    save();
    await moneroChain.setNode(settings.moneroNode);
  }

  void setI2p(bool on) {
    settings.i2pEnabled = on;
    save();
    on ? unawaited(privateNetwork.start()) : privateNetwork.stop();
  }

  void setStartWithComputer(bool on) {
    settings.startWithComputer = on;
    Desktop.setStartWithComputer(on);
    save();
  }

  /// What the window's close button does from now on.
  void setCloseAction(CloseAction a) {
    settings.closeAction = a;
    unawaited(Desktop.setCloseAction(a.name));
    save();
    notifyListeners();
  }

  /// The notification's Stop action: the master switch off.
  Future<void> stopAll() async {
    await setMiningOn(false);
    await MiningService.stop();
  }

  @override
  void dispose() {
    unawaited(stopAll());
    super.dispose();
  }
}
