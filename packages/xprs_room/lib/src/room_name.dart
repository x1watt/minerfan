import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:xprs_wire/xprs_wire.dart';

/// How many shared meeting addresses (slots) a room has. A member answers
/// for one of them, chosen by its own address; a newcomer greets them all.
const roomSlots = 4;

/// The XPRS open-group name (section 7.3) of a coin's room: the coin's name
/// in capitals, letters and digits only, 1 to 16 characters, and not shaped
/// like a callsign. Null when no such name can be made.
String? roomNameFor(String coinName) {
  final n = coinName.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  if (n.isEmpty || n.length > 16 || xprsAddressesStation(n)) return null;
  return n;
}

/// The two 32-byte seeds of [room]'s meeting address number [slot]
/// (encryption and signing keys of an I2P destination). Everybody derives
/// the same ones from the room's name.
(Uint8List enc, Uint8List sign) roomSlotSeeds(String room, int slot) {
  Uint8List h(String part) =>
      Uint8List.fromList(sha256.convert(utf8.encode('minerfan-room/v1|$room|$slot|$part')).bytes);
  return (h('enc'), h('sign'));
}

/// The slot a member with this address answers for.
int slotFor(Uint8List destHash) => sha256.convert(destHash).bytes[0] % roomSlots;
