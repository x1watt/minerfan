import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto_core/crypto_core.dart';

import 'address.dart';
import 'block.dart';
import 'bloom.dart';
import 'bytes.dart';
import 'node.dart';
import 'spend_proof.dart';
import 'peer.dart';
import 'txbuilder.dart';
import 'wire.dart';

/// An output the wallet owns.
class WalletCoin {
  final OutPoint outpoint;
  final int value;
  final Uint8List script;
  final int chain; // 0 receive, 1 change
  final int index;
  final bool coinbase;
  int? height; // null while unconfirmed

  WalletCoin(this.outpoint, this.value, this.script, this.chain, this.index, {required this.coinbase, this.height});

  Map<String, Object?> toJson() => {
        'txid': hashToHex(outpoint.txid),
        'n': outpoint.index,
        'value': value,
        'script': toHex(script),
        'chain': chain,
        'index': index,
        'coinbase': coinbase,
        'height': height,
      };

  static WalletCoin fromJson(Map<String, Object?> m) => WalletCoin(
        OutPoint(hashFromHex(m['txid']! as String), m['n']! as int),
        m['value']! as int,
        fromHex(m['script']! as String),
        m['chain']! as int,
        m['index']! as int,
        coinbase: m['coinbase']! as bool,
        height: m['height'] as int?,
      );
}

/// One transaction as the wallet sees it.
class WalletTx {
  final String txid;
  int? height;
  final int received; // to our addresses
  final int sent; // from our coins
  final int time; // first seen (seconds)
  final bool coinbase;

  /// The public keys its inputs revealed (hex), so a payment to us can be
  /// matched to a proof signed by its sender (spend_proof.dart).
  final List<String> inputKeys;

  WalletTx(this.txid, this.height, this.received, this.sent, this.time,
      {this.coinbase = false, this.inputKeys = const []});

  int get net => received - sent;

  Map<String, Object?> toJson() =>
      {'txid': txid, 'height': height, 'received': received, 'sent': sent, 'time': time, 'coinbase': coinbase,
        if (inputKeys.isNotEmpty) 'ik': inputKeys};
  static WalletTx fromJson(Map<String, Object?> m) => WalletTx(
      m['txid']! as String, m['height'] as int?, m['received']! as int, m['sent']! as int, m['time']! as int,
      coinbase: (m['coinbase'] as bool?) ?? false,
      inputKeys: [for (final k in (m['ik'] as List?) ?? const []) '$k']);
}

class WalletBalance {
  final int confirmed; // spendable now
  final int immature; // coinbase outputs still maturing
  final int pending; // unconfirmed incoming
  const WalletBalance(this.confirmed, this.immature, this.pending);
  int get total => confirmed + immature + pending;
}

/// An HD (BIP44) SPV wallet on a [UtxoNode]. It watches with the account's
/// public key alone; spending needs the account's private key.
class SpvWallet {
  final UtxoNode node;
  final HdKey account; // m/44'/coin'/0' (public is enough to watch)
  final String? file;
  final int birthday;
  final void Function(String)? log;
  static const gap = 20;

  final Map<String, WalletCoin> coins = {};
  final Map<String, WalletTx> history = {};
  final Map<String, (int, int)> _scripts = {}; // script hex -> (chain, index)
  final List<int> _used = [-1, -1]; // highest used index per chain
  int scanned;
  BloomFilter? _filter;
  final StreamController<void> _changes = StreamController.broadcast();
  final List<StreamSubscription<Object?>> _subs = [];
  final Map<String, int> _expect = {}; // txid hex -> height, from merkleblocks
  bool _scanning = false;
  Completer<void>? _batchDone;
  int _batchLeft = 0;

  SpvWallet({required this.node, required this.account, required this.birthday, this.file, this.log}) : scanned = birthday - 1;

  Stream<void> get changes => _changes.stream;

  Address address(int chain, int index) => Address.fromPublicKey(account.child(chain).child(index).publicKey);

  /// The first receive address not seen on chain yet.
  Address get receiveAddress => address(0, _used[0] + 1);

  WalletBalance get balance {
    final tip = node.chain.tipHeight;
    var confirmed = 0, immature = 0, pending = 0;
    for (final c in coins.values) {
      final h = c.height;
      if (h == null) {
        pending += c.value;
      } else if (c.coinbase && tip + 1 - h < node.params.coinbaseMaturity) {
        immature += c.value;
      } else {
        confirmed += c.value;
      }
    }
    return WalletBalance(confirmed, immature, pending);
  }

  Future<void> start() async {
    _load();
    _deriveUpTo();
    _subs.add(node.peerConnected.listen(_loadFilter));
    _subs.add(node.messages.listen((pm) => _onMessage(pm.$1, pm.$2)));
    _subs.add(node.tipChanges.listen((_) => unawaited(scan())));
    for (final p in node.peers) {
      _loadFilter(p);
    }
    unawaited(scan());
  }

  void _deriveUpTo() {
    for (var chain = 0; chain < 2; chain++) {
      for (var i = 0; i <= _used[chain] + gap; i++) {
        final a = address(chain, i);
        _scripts.putIfAbsent(toHex(a.script), () => (chain, i));
      }
    }
    final keys = <List<int>>[];
    for (final e in _scripts.entries) {
      final (chain, i) = e.value;
      final k = account.child(chain).child(i);
      keys
        ..add(k.identifier)
        ..add(k.publicKey);
    }
    final outpoints = [
      for (final c in coins.values) [...c.outpoint.txid, ...(ByteData(4)..setUint32(0, c.outpoint.index, Endian.little)).buffer.asUint8List()],
    ];
    final f = BloomFilter.forElements(keys.length + outpoints.length + 10);
    keys.forEach(f.insert);
    outpoints.forEach(f.insert);
    _filter = f;
  }

  void _loadFilter(Peer p) {
    final f = _filter;
    if (f != null) p.send('filterload', f.payload());
  }

  /// Fetches filtered blocks from the last scanned height to the tip.
  Future<void> scan() async {
    if (_scanning) return;
    _scanning = true;
    try {
      while (scanned < node.chain.tipHeight && node.peers.isNotEmpty) {
        final from = scanned + 1;
        final to = (from + 199).clamp(from, node.chain.tipHeight);
        final peer = node.peers.first;
        final items = <InvItem>[];
        for (var h = from; h <= to; h++) {
          final hash = node.chain.hashAt(h);
          if (hash != null) items.add(InvItem(InvType.filteredBlock, hash));
        }
        _batchLeft = items.length;
        _batchDone = Completer<void>();
        peer.send('getdata', Msg.inv(items));
        try {
          await _batchDone!.future.timeout(const Duration(seconds: 60));
        } on TimeoutException {
          log?.call('wallet: no filtered blocks from ${peer.address}; trying again');
          continue;
        }
        // Matched transactions follow their merkleblock; give them a moment.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        // A peer does not resend a transaction it already announced to us
        // (BIP 37), so a payment first seen unconfirmed would never arrive
        // with its block: ask for whatever the proofs named and did not come.
        if (_expect.isNotEmpty) {
          peer.send('getdata', Msg.inv([for (final t in _expect.keys) InvItem(InvType.tx, fromHex(t))]));
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        scanned = to;
        _save();
      }
      if (scanned >= node.chain.tipHeight) {
        for (final p in node.peers) {
          p.send('mempool');
        }
      }
    } finally {
      _scanning = false;
    }
  }

  void _onMessage(Peer p, WireMessage m) {
    switch (m.command) {
      case 'merkleblock':
        try {
          final mb = MerkleBlock.parse(m.payload);
          final height = node.chain.heightOf(mb.header.hash);
          final matched = mb.matched();
          if (height != null && matched != null) {
            for (final t in matched) {
              // Peers send the matched transactions after the merkleblock,
              // except those they know we have (ours, broadcast by us):
              // the proof alone confirms those.
              if (!_confirmKnown(t, height)) _expect[toHex(t)] = height;
            }
          }
        } on FormatException {
          // ignore
        }
        if (_batchLeft > 0 && --_batchLeft == 0) _batchDone?.complete();
      case 'inv':
        // With our filter loaded, a peer announces only transactions that
        // may concern us: fetch the ones we do not have yet.
        try {
          final want = [
            for (final i in Msg.parseInv(m.payload))
              if (i.type == InvType.tx && !history.containsKey(toHex(i.hash.reversed.toList()))) i,
          ];
          if (want.isNotEmpty) p.send('getdata', Msg.inv(want));
        } on FormatException {
          // ignore
        }
      case 'tx':
        try {
          final tx = Transaction.parse(m.payload);
          _process(tx, _expect.remove(toHex(tx.txid)));
        } on FormatException {
          // ignore
        }
    }
  }

  void _process(Transaction tx, int? height) {
    final id = tx.id;
    var received = 0, sent = 0;
    var changed = false;
    for (final input in tx.inputs) {
      final c = coins.remove(input.prevout.key);
      if (c != null) {
        sent += c.value;
        changed = true;
      }
    }
    for (var n = 0; n < tx.outputs.length; n++) {
      final o = tx.outputs[n];
      final mine = _scripts[toHex(o.script)];
      if (mine == null) continue;
      final op = OutPoint(tx.txid, n);
      final existing = coins[op.key];
      if (existing != null) {
        existing.height ??= height;
      } else if (!_spentByUs(op)) {
        coins[op.key] = WalletCoin(op, o.value, o.script, mine.$1, mine.$2, coinbase: tx.isCoinbase, height: height);
      }
      received += o.value;
      if (mine.$2 > _used[mine.$1]) {
        _used[mine.$1] = mine.$2;
        _deriveUpTo();
        for (final p in node.peers) {
          _loadFilter(p);
        }
      }
      changed = true;
    }
    if (!changed) return;
    final old = history[id];
    if (old != null) {
      old.height ??= height;
    } else {
      history[id] = WalletTx(id, height, received, sent, DateTime.now().millisecondsSinceEpoch ~/ 1000,
          coinbase: tx.isCoinbase,
          inputKeys: received > 0 && sent == 0
              ? [for (final i in tx.inputs) if (scriptSigPublicKey(i.script) case final k?) toHex(k)]
              : const []);
      log?.call('wallet: ${tx.isCoinbase ? 'mined' : 'transaction'} $id ${received - sent >= 0 ? '+' : ''}${received - sent}${height == null ? ' (unconfirmed)' : ' at $height'}');
    }
    _save();
    if (!_changes.isClosed) _changes.add(null);
  }

  /// Records the height of a transaction the wallet already has. Returns
  /// false when it is unknown (its `tx` message will follow).
  bool _confirmKnown(Uint8List txid, int height) {
    final t = history[hashToHex(txid)];
    if (t == null) return false;
    var changed = false;
    if (t.height == null) {
      t.height = height;
      changed = true;
    }
    for (final c in coins.values) {
      if (c.height == null && bytesEqual(c.outpoint.txid, txid)) {
        c.height = height;
        changed = true;
      }
    }
    if (changed) {
      log?.call('wallet: ${t.txid} confirmed at $height');
      _save();
      if (!_changes.isClosed) _changes.add(null);
    }
    return true;
  }

  final Set<String> _spent = {};
  bool _spentByUs(OutPoint op) => _spent.contains(op.key);

  /// Confirmed coins, and coinbases once mature.
  List<Spendable> _spendable(BigInt Function(WalletCoin) key) {
    final tip = node.chain.tipHeight;
    return [
      for (final c in coins.values)
        if (c.height != null && (!c.coinbase || tip + 1 - c.height! >= node.params.coinbaseMaturity))
          Spendable(c.outpoint, c.value, c.script, key(c)),
    ];
  }

  /// The coins and fee a payment of [amount] would use (no keys needed).
  /// Throws [InsufficientFunds].
  TxPlan preview(int amount) => TxBuilder.plan(params: node.params, available: _spendable((_) => BigInt.one), amount: amount);

  /// Pays [amount] smallest units to [to]; [accountPrivate] is the account
  /// key with its private part (from the mnemonic). Returns the broadcast
  /// transaction.
  Transaction send({required Address to, required int amount, required HdKey accountPrivate}) =>
      _pay(to, amount, accountPrivate).$1;

  /// Pays like [send], and proves it: a signature by the first input's key
  /// over [message] followed by the txid (spend_proof.dart). Returns the
  /// transaction, that key's public key and the proof.
  (Transaction, Uint8List, Uint8List) sendProved(
      {required Address to, required int amount, required HdKey accountPrivate, required String message}) {
    final (tx, used) = _pay(to, amount, accountPrivate);
    final first = used.first;
    final pub = Secp256k1.publicKey(first.key).encode(compressed: first.compressed);
    return (tx, pub, inputKeyProof(first.key, utf8.encode('$message${tx.id}')));
  }

  (Transaction, List<Spendable>) _pay(Address to, int amount, HdKey accountPrivate) {
    if (accountPrivate.neutered().serialize() != account.serialize()) {
      throw ArgumentError('the key is not this wallet\'s account key');
    }
    final spendable = _spendable((c) => accountPrivate.child(c.chain).child(c.index).key!);
    final change = address(1, _used[1] + 1);
    final used = <Spendable>[];
    final tx = TxBuilder.pay(
        params: node.params, available: spendable, toScript: to.script, amount: amount, changeScript: change.script, chosenOut: used);
    node.broadcastTransaction(tx);
    // Recorded like any transaction: the spent coins count as sent.
    _process(tx, null);
    for (final u in used) {
      _spent.add(u.outpoint.key);
    }
    return (tx, used);
  }

  // ---- persistence (public data only: no keys) ----

  void _save() {
    final f = file;
    if (f == null) return;
    try {
      final data = jsonEncode({
        'birthday': birthday,
        'scanned': scanned,
        'used': _used,
        'coins': [for (final c in coins.values) c.toJson()],
        'history': [for (final t in history.values) t.toJson()],
        'spent': _spent.toList(),
      });
      final tmp = File('$f.tmp')..writeAsStringSync(data);
      tmp.renameSync(f);
    } catch (_) {}
  }

  void _load() {
    final f = file;
    if (f == null || !File(f).existsSync()) return;
    try {
      final m = jsonDecode(File(f).readAsStringSync()) as Map<String, Object?>;
      scanned = (m['scanned'] as int?) ?? scanned;
      final used = (m['used'] as List?)?.cast<int>();
      if (used != null && used.length == 2) _used.setAll(0, used);
      for (final c in (m['coins'] as List? ?? const [])) {
        final w = WalletCoin.fromJson(c as Map<String, Object?>);
        coins[w.outpoint.key] = w;
      }
      for (final t in (m['history'] as List? ?? const [])) {
        final w = WalletTx.fromJson(t as Map<String, Object?>);
        history[w.txid] = w;
      }
      _spent.addAll((m['spent'] as List? ?? const []).cast<String>());
      // Re-check the last blocks, in case of a reorganization.
      scanned = (scanned - 6).clamp(birthday - 1, scanned);
    } catch (_) {}
  }

  Future<void> stop() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _save();
    await _changes.close();
  }
}
