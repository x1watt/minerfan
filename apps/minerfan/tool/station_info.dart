// Prints the XPRS station of a minerfan data folder (callsign and npub),
// for build-time settings such as ROOM_ADMIN_NPUB in tests.
//
//   dart run tool/station_info.dart <data folder>

// ignore_for_file: avoid_print

import 'package:minerfan/network/network_keys.dart';

void main(List<String> args) {
  final k = NetworkKeys.loadOrCreate(args.first);
  print('${k.station.callsign} ${k.station.npub}');
}
