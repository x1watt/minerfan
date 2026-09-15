import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto_core/crypto_core.dart';
import 'package:net_core/net_core.dart';
import 'package:pow_core/pow_core.dart';

import 'address.dart';
import 'bytes.dart';
import 'header_chain.dart';
import 'node.dart';
import 'params.dart';
import 'solo_miner.dart';
import 'wallet.dart';

/// Which chain a [ChainHandle] runs and where it keeps its files.
class ChainServiceConfig {
  final ChainParams params;
  final HeaderCheckpoint checkpoint;
  final String dataDir;
  const ChainServiceConfig({required this.params, required this.checkpoint, required this.dataDir});
}

/// How to mine: the payout address, the effort (target share of the
/// network, 1 for no cap) and the devices.
class MiningConfig {
  final String payTo;
  final double effort;

  /// OpenCL device index, or null for no GPU.
  final int? gpuDevice;
  final int cpuThreads;

  const MiningConfig({required this.payTo, required this.effort, this.gpuDevice, this.cpuThreads = 0});
}

class MiningStatus {
  /// Searching nonces now (false while syncing or before work).
  final bool mining;
  final double hashrate;
  final double fullSpeed;
  final double duty;
  final double effort;
  final List<String> devices;
  final int? height;
  final String payTo;

  /// Our blocks among the last 30, and the fair-share guard's factor.
  final double observedShare;
  final double guard;
  const MiningStatus(this.mining, this.hashrate, this.fullSpeed, this.duty, this.effort, this.devices, this.height,
      this.payTo, this.observedShare, this.guard);
}

class WalletStatus {
  final String id;
  final WalletBalance balance;
  final String receiveAddress;
  final int scanned;

  /// Newest first (unconfirmed, then by height).
  final List<WalletTx> history;
  const WalletStatus(this.id, this.balance, this.receiveAddress, this.scanned, this.history);
}

/// A snapshot of the chain service, sent every 2 seconds.
class ChainStatus {
  final int tip;
  final int bestPeerHeight;
  final int peers;
  final bool synced;
  final double difficulty;
  final double networkHashrate;
  final MiningStatus? mining;
  final String? miningError;
  final List<FoundBlock> found;
  final Map<String, WalletStatus> wallets;
  const ChainStatus(this.tip, this.bestPeerHeight, this.peers, this.synced, this.difficulty, this.networkHashrate,
      this.mining, this.miningError, this.found, this.wallets);
}

/// A Bitcoin-family chain in its own isolate: the light node, solo mining
/// on its GPU and CPU miners, and SPV wallets, all sharing one set of peers.
class ChainHandle {
  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _inbox;
  final StreamController<ChainStatus> _status = StreamController.broadcast();
  final StreamController<String> _log = StreamController.broadcast();
  final Map<int, Completer<Object?>> _pending = {};
  final Completer<void> _stopped = Completer();
  int _nextId = 0;
  ChainStatus? last;

  ChainHandle._(this._isolate, this._commands, this._inbox, Stream<Object?> messages) {
    messages.listen((m) {
      final msg = m as List<Object?>;
      switch (msg[0]) {
        case 'status':
          last = msg[1]! as ChainStatus;
          _status.add(last!);
        case 'log':
          _log.add(msg[1]! as String);
        case 'reply':
          final c = _pending.remove(msg[1]! as int);
          if (msg[3] != null) {
            c?.completeError(ChainServiceException(msg[3]! as String));
          } else {
            c?.complete(msg[2]);
          }
        case 'stopped':
          if (!_stopped.isCompleted) _stopped.complete();
      }
    });
  }

  static Future<ChainHandle> spawn(ChainServiceConfig config) async {
    final inbox = ReceivePort();
    final iso = await Isolate.spawn(_main, [inbox.sendPort, config], debugName: '${config.params.symbol}-chain');
    final messages = inbox.asBroadcastStream();
    final commands = await messages.first as SendPort;
    return ChainHandle._(iso, commands, inbox, messages);
  }

  Stream<ChainStatus> get status => _status.stream;
  Stream<String> get log => _log.stream;

  Future<Object?> _request(List<Object?> msg) {
    final id = _nextId++;
    final c = _pending[id] = Completer<Object?>();
    _commands.send([msg[0], id, ...msg.skip(1)]);
    return c.future;
  }

  /// Starts (or restarts with new settings) solo mining. Throws
  /// [ChainServiceException] when no device can mine or the address is bad.
  Future<void> startMining(MiningConfig c) => _request(['startMining', c]);
  Future<void> stopMining() => _request(['stopMining']);
  void setEffort(double share) => _commands.send(['setEffort', -1, share]);

  /// Caps the miners' duty (a warm phone), 0 to 1.
  void setDutyCap(double cap) => _commands.send(['setDutyCap', -1, cap]);

  /// Watches a BIP44 account (its xpub) from [birthday] on.
  Future<void> openWallet(String id, String accountXpub, int birthday) =>
      _request(['openWallet', id, accountXpub, birthday]);
  Future<void> closeWallet(String id) => _request(['closeWallet', id]);

  /// (fee, change) of paying [amount]; throws when the funds are short.
  Future<(int, int)> preview(String walletId, int amount) async {
    final r = await _request(['preview', walletId, amount]) as List<Object?>;
    return (r[0]! as int, r[1]! as int);
  }

  /// Signs with [accountXprv] and broadcasts; returns the txid.
  Future<String> send(String walletId, String to, int amount, String accountXprv) async =>
      await _request(['send', walletId, to, amount, accountXprv]) as String;

  /// Sends like [send] and proves it (SpvWallet.sendProved): returns the
  /// txid, the first input's public key and the proof over [message] + txid,
  /// both hex.
  Future<(String, String, String)> sendProved(
      String walletId, String to, int amount, String accountXprv, String message) async {
    final r = await _request(['sendProved', walletId, to, amount, accountXprv, message]) as List<Object?>;
    return (r[0]! as String, r[1]! as String, r[2]! as String);
  }

  Future<void> stop() async {
    _commands.send(['stop', -1]);
    await _stopped.future.timeout(const Duration(seconds: 20), onTimeout: () {});
    _isolate.kill();
    _inbox.close();
    for (final c in _pending.values) {
      c.completeError(const ChainServiceException('stopped'));
    }
    _pending.clear();
    await _status.close();
    await _log.close();
  }
}

class ChainServiceException implements Exception {
  final String message;
  const ChainServiceException(this.message);
  @override
  String toString() => message;
}

Future<void> _main(List<Object?> args) async {
  final out = args[0]! as SendPort;
  final config = args[1]! as ChainServiceConfig;
  final inbox = ReceivePort();
  out.send(inbox.sendPort);
  final service = _Service(config, out);
  await service.start();
  await for (final m in inbox) {
    final msg = m as List<Object?>;
    final id = msg[1]! as int;
    try {
      final result = await service.handle(msg[0]! as String, msg.sublist(2));
      if (id >= 0) out.send(['reply', id, result, null]);
    } catch (e) {
      if (id >= 0) out.send(['reply', id, null, '$e']);
    }
    if (msg[0] == 'stop') {
      out.send(['stopped']);
      inbox.close();
    }
  }
}

class _Service {
  final ChainServiceConfig config;
  final SendPort out;
  late final UtxoNode node;
  SoloMiner? miner;
  MiningConfig? miningConfig;
  String? miningError;
  final Map<String, SpvWallet> wallets = {};
  late final List<FoundBlock> found = _loadFound();
  Timer? _timer;

  _Service(this.config, this.out);

  ChainParams get params => config.params;
  File get _foundFile => File('${config.dataDir}/found.json');

  void log(String line) => out.send(['log', '${DateTime.now().toIso8601String().substring(11, 19)} $line']);

  Future<void> start() async {
    Directory(config.dataDir).createSync(recursive: true);
    node = UtxoNode(params: params, transport: IoTransport(), checkpoint: config.checkpoint, dataDir: config.dataDir, log: log);
    await node.start();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _sendStatus());
  }

  Future<Object?> handle(String command, List<Object?> a) async {
    switch (command) {
      case 'startMining':
        await _stopMining();
        await _startMining(a[0]! as MiningConfig);
      case 'stopMining':
        await _stopMining();
      case 'setEffort':
        miner?.setEffort(a[0]! as double);
      case 'setDutyCap':
        miner?.setDutyCap(a[0]! as double);
      case 'openWallet':
        final id = a[0]! as String;
        if (wallets.containsKey(id)) return null;
        final account = HdKey.parse(a[1]! as String) ?? (throw const FormatException('not an extended public key'));
        final birthday = (a[2]! as int).clamp(config.checkpoint.height + 1, 1 << 40);
        final w = SpvWallet(
            node: node, account: account, birthday: birthday, file: '${config.dataDir}/wallet-$id.json', log: log);
        wallets[id] = w;
        await w.start();
      case 'closeWallet':
        await wallets.remove(a[0]! as String)?.stop();
      case 'preview':
        final plan = _wallet(a[0]).preview(a[1]! as int);
        return [plan.fee, plan.change];
      case 'send':
        final w = _wallet(a[0]);
        final to = Address.parse(a[1]! as String, params) ?? (throw FormatException('not a ${params.name} address'));
        final key = HdKey.parse(a[3]! as String);
        if (key == null || !key.isPrivate) throw const FormatException('not an extended private key');
        final tx = w.send(to: to, amount: a[2]! as int, accountPrivate: key);
        log('sent ${tx.id} to ${node.peerCount} peers');
        return tx.id;
      case 'sendProved':
        final w = _wallet(a[0]);
        final to = Address.parse(a[1]! as String, params) ?? (throw FormatException('not a ${params.name} address'));
        final key = HdKey.parse(a[3]! as String);
        if (key == null || !key.isPrivate) throw const FormatException('not an extended private key');
        final (tx, pub, proof) = w.sendProved(to: to, amount: a[2]! as int, accountPrivate: key, message: a[4]! as String);
        log('sent ${tx.id} to ${node.peerCount} peers');
        return [tx.id, toHex(pub), toHex(proof)];
      case 'stop':
        _timer?.cancel();
        await _stopMining();
        for (final w in wallets.values) {
          await w.stop();
        }
        wallets.clear();
        await node.stop();
    }
    return null;
  }

  SpvWallet _wallet(Object? id) => wallets[id] ?? (throw StateError('the wallet is not open'));

  Future<void> _startMining(MiningConfig c) async {
    miningConfig = c;
    miningError = null;
    final payTo = Address.parse(c.payTo.trim(), params);
    if (payTo == null) throw FormatException('the payout address is not a ${params.name} address');
    final devices = <HeaderMiner>[
      if (c.gpuDevice != null) GpuScryptMiner(deviceIndex: c.gpuDevice!),
      if (c.cpuThreads > 0) CpuHeaderMiner(pow: params.pow, threads: c.cpuThreads),
    ];
    if (devices.isEmpty) throw StateError('choose a GPU or at least one CPU thread');
    final m = SoloMiner(
      node: node,
      payTo: payTo,
      effort: EffortController(c.effort),
      miners: devices,
      log: log,
      found: found,
      onFound: _saveFound,
    );
    try {
      await m.start();
      miner = m;
    } catch (e) {
      miningError = '$e';
      rethrow;
    }
  }

  Future<void> _stopMining() async {
    final m = miner;
    miner = null;
    miningConfig = null;
    await m?.stop();
  }

  List<FoundBlock> _loadFound() {
    try {
      if (_foundFile.existsSync()) {
        return [
          for (final b in jsonDecode(_foundFile.readAsStringSync()) as List) FoundBlock.fromJson(b as Map<String, Object?>),
        ];
      }
    } catch (_) {}
    return [];
  }

  void _saveFound() {
    try {
      _foundFile.writeAsStringSync(jsonEncode([for (final b in found) b.toJson()]));
    } catch (_) {}
  }

  void _sendStatus() {
    final m = miner;
    final c = node.chain;
    final network = recentNetworkHashrate(node);
    final status = ChainStatus(
      c.tipHeight,
      node.bestPeerHeight,
      node.peerCount,
      node.synced,
      CompactTarget.difficulty(c.tipBits),
      network,
      m == null
          ? null
          : MiningStatus(m.mining, m.hashrate, m.fullSpeed, m.duty, m.effort.targetShare,
              [for (final d in m.miners) d.device], m.template?.height, miningConfig?.payTo ?? '', m.observedShare, m.guard),
      miningError,
      List.of(found),
      {
        for (final e in wallets.entries)
          e.key: WalletStatus(e.key, e.value.balance, e.value.receiveAddress.encode(params), e.value.scanned,
              (e.value.history.values.toList()..sort(_newestFirst)).take(100).toList()),
      },
    );
    out.send(['status', status]);
  }

  static int _newestFirst(WalletTx a, WalletTx b) {
    final ha = a.height ?? 1 << 40, hb = b.height ?? 1 << 40;
    return hb != ha ? hb.compareTo(ha) : b.time.compareTo(a.time);
  }
}
