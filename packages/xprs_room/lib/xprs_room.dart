/// Public chat rooms on XPRS open groups (docs XPRS.md 7.3): one room per
/// name, the last two weeks kept by every member and served by catch-up
/// (cmd:history, 11.2), members met through shared meeting addresses,
/// posts pushed and pulled among them, flood limits instead of moderators.
/// Pure Dart; the bearer (I2P in minerfan) is plugged in as a [RoomBearer].
library;

export 'src/flood_guard.dart';
export 'src/member_table.dart';
export 'src/room_crypto.dart';
export 'src/room_engine.dart';
export 'src/room_history.dart';
export 'src/room_item.dart';
export 'src/room_name.dart';
export 'src/room_store.dart';
