import 'dart:typed_data';

import '../crypto/keccak.dart';
import '../crypto/monero_keys.dart';
import '../util/bytes.dart';
import '../util/varint.dart';
import 'base58.dart';

enum MoneroNetwork { mainnet, testnet, stagenet }

enum AddressKind { standard, integrated, subaddress }

/// A decoded Monero address: public spend and view keys.
class MoneroAddress {
  final MoneroNetwork network;
  final AddressKind kind;
  final Uint8List spendKey;
  final Uint8List viewKey;
  final Uint8List? paymentId;

  MoneroAddress(this.network, this.kind, this.spendKey, this.viewKey, [this.paymentId]);

  static const Map<int, (MoneroNetwork, AddressKind)> _tags = {
    18: (MoneroNetwork.mainnet, AddressKind.standard),
    19: (MoneroNetwork.mainnet, AddressKind.integrated),
    42: (MoneroNetwork.mainnet, AddressKind.subaddress),
    53: (MoneroNetwork.testnet, AddressKind.standard),
    54: (MoneroNetwork.testnet, AddressKind.integrated),
    63: (MoneroNetwork.testnet, AddressKind.subaddress),
    24: (MoneroNetwork.stagenet, AddressKind.standard),
    25: (MoneroNetwork.stagenet, AddressKind.integrated),
    36: (MoneroNetwork.stagenet, AddressKind.subaddress),
  };

  /// Parses and validates (checksum, key encodings). Returns null if invalid.
  static MoneroAddress? parse(String s) {
    final raw = base58Decode(s.trim());
    if (raw == null || raw.length < 1 + 64 + 4) return null;
    final tagRes = readVarint(raw, 0);
    if (tagRes == null) return null;
    final (tag, tagLen) = tagRes;
    final info = _tags[tag];
    if (info == null) return null;
    final (network, kind) = info;
    final bodyLen = raw.length - 4;
    final expected = tagLen + 64 + (kind == AddressKind.integrated ? 8 : 0);
    if (bodyLen != expected) return null;
    final checksum = Keccak.hash256(raw.sublist(0, bodyLen)).sublist(0, 4);
    if (!bytesEqual(checksum, raw.sublist(bodyLen))) return null;
    final spend = Uint8List.fromList(raw.sublist(tagLen, tagLen + 32));
    final view = Uint8List.fromList(raw.sublist(tagLen + 32, tagLen + 64));
    if (!checkKey(spend) || !checkKey(view)) return null;
    final pid = kind == AddressKind.integrated ? Uint8List.fromList(raw.sublist(tagLen + 64, tagLen + 72)) : null;
    return MoneroAddress(network, kind, spend, view, pid);
  }

  String encode() {
    final tag = _tags.entries.firstWhere((e) => e.value == (network, kind)).key;
    final body = concatBytes([encodeVarint(tag), spendKey, viewKey, ?paymentId]);
    return base58Encode(concatBytes([body, Keccak.hash256(body).sublist(0, 4)]));
  }
}
