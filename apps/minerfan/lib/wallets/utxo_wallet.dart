import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto_core/crypto_core.dart';
import 'package:utxo_core/utxo_core.dart';

import '../chains/utxo_chain.dart';
import 'keyed_wallet.dart';
import 'wallet.dart';

/// What creating or restoring a wallet produces: the watch-only account
/// key, the first address and the recovery phrase sealed with the password.
class SealedAccount {
  final String xpub;
  final String firstAddress;
  final Map<String, Object?> secret;
  const SealedAccount(this.xpub, this.firstAddress, this.secret);
}

/// An HD (BIP44) SPV wallet on a Bitcoin-family chain. The recovery phrase
/// is kept encrypted: with the device key (no password, the default) or
/// with the user's password (Argon2id; asked for every payment). The
/// account's public key watches the chain; the phrase is opened only to
/// sign a payment or to show it for a backup.
class UtxoWallet extends KeyedWallet {
  @override
  final String id;
  @override
  String label;
  final UtxoChain service;
  final String xpub;
  final int birthday;
  final String firstAddress;

  UtxoWallet({
    required this.id,
    required this.label,
    required this.service,
    required this.xpub,
    required this.birthday,
    required this.firstAddress,
    required super.secret,
    required super.deviceKey,
    super.backedUp,
  });

  UtxoCoin get coin => service.coin;

  static UtxoWallet fromJson(Map<String, Object?> m, UtxoChain service, Uint8List deviceKey) => UtxoWallet(
    id: m['id']! as String,
    label: (m['label'] as String?) ?? service.coin.name,
    service: service,
    xpub: m['xpub']! as String,
    birthday: m['birthday']! as int,
    firstAddress: m['address']! as String,
    secret: (m['secret']! as Map).cast<String, Object?>(),
    deviceKey: deviceKey,
    backedUp: (m['backedUp'] as bool?) ?? false,
  );

  @override
  Map<String, Object?> toJson() => {
    'id': id,
    'chain': service.coin.id,
    'label': label,
    'xpub': xpub,
    'birthday': birthday,
    'address': firstAddress,
    'secret': secret,
    'backedUp': backedUp,
  };



  WalletStatus? get status => service.status?.wallets[id];

  @override
  String get chain => coin.id;
  @override
  String get chainName => coin.name;
  @override
  String get symbol => coin.symbol;

  /// The next unused receive address once scanned, else the first one.
  @override
  String get address => status?.receiveAddress ?? firstAddress;

  @override
  List<WalletAsset> get assets {
    final b = status?.balance;
    return [
      WalletAsset(coin.symbol, coin.name, balance: b == null ? null : BigInt.from(b.total), decimals: coin.decimals),
    ];
  }

  @override
  bool get canReceive => true;
  @override
  bool get canSend => (status?.balance.confirmed ?? 0) > 0;
  @override
  String? get sendUnavailable {
    final s = status;
    if (s == null) return 'Connecting to the ${coin.name} network';
    if (s.balance.confirmed > 0) return null;
    if (s.balance.immature > 0) {
      return 'Mined coins can be spent after ${coin.params.coinbaseMaturity} confirmations.';
    }
    return 'Nothing to send yet.';
  }

  /// Derives the account and seals the phrase: with [password], or with
  /// the device key when it is null. Argon2id and PBKDF2 take up to a
  /// second, so this runs on a helper isolate.
  static Future<SealedAccount> seal(UtxoCoin coin, String mnemonic, {String? password, required Uint8List deviceKey}) {
    final params = coin.params;
    final path = coin.accountPath;
    return Isolate.run(() {
      final phrase = mnemonic.trim().toLowerCase().split(RegExp(r'\s+')).join(' ');
      final account = HdKey.master(Bip39.seed(phrase)).derive(path);
      final first = Address.fromPublicKey(account.child(0).child(0).publicKey).encode(params);
      final bytes = utf8.encode(phrase);
      return SealedAccount(
        account.neutered().serialize(),
        first,
        password == null ? KeyBox.seal(deviceKey, bytes) : PasswordBox.seal(password, bytes),
      );
    });
  }

  /// The account's private key for signing, or null for a wrong password
  /// ([password] is ignored without one).
  Future<String?> unlock([String? password]) {
    final box = secret, key = deviceKey, path = coin.accountPath, expected = xpub;
    return Isolate.run(() {
      final phrase = KeyedWallet.open(box, key, password);
      if (phrase == null) return null;
      final account = HdKey.master(Bip39.seed(phrase)).derive(path);
      return account.neutered().serialize() == expected ? account.serialize() : null;
    });
  }
}
