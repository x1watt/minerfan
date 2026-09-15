import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:i2p/i2p.dart';
import 'package:xprs_room/xprs_room.dart';

import '../contacts/contact_book.dart';
import '../moderation/admin.dart';
import '../moderation/claims.dart';
import '../moderation/config.dart';
import '../wallets/wallet.dart';
import 'private_network.dart';

/// The I2P port coin rooms talk on (XPRS direct packets use 4242).
const roomI2pPort = 4244;

/// The largest frame an I2P app message carries.
const _maxFrame = 32 * 1024;

/// The room's meeting addresses, one per slot: destinations made from the
/// room's name, so curve math, on a short-lived isolate. A top-level
/// function so the closure holds only [room].
Future<List<String>> _meetingAddresses(String room) => Isolate.run(() async => [
      for (var k = 0; k < roomSlots; k++)
        await sharedDestinationAddress(roomSlotSeeds(room, k).$1, roomSlotSeeds(room, k).$2),
    ]);

final _roomField = RegExp(r'"room"\s*:\s*"([A-Z0-9]{1,16})"');
final _lineRoom = RegExp(r'(?:^| )(?:d|only):([A-Za-z0-9]{1,16})(?= |$)');

/// The rooms a frame names: `"room"` of a control frame, or the `d:` and
/// `only:` of its XPRS lines. A cheap look before any signature is checked,
/// so a frame costs only the rooms it concerns; a wrong guess costs nothing
/// more, since each room's engine keeps only its own.
Set<String> roomNamesIn(String text) {
  if (text.startsWith('{')) {
    final g = _roomField.firstMatch(text)?.group(1);
    return {?g};
  }
  return {
    for (final line in LineSplitter.split(text))
      if (line.startsWith('t:'))
        for (final g in _lineRoom.allMatches(line)) g.group(1)!.toUpperCase(),
  };
}

/// A room's frames over this app's I2P node.
class _I2pRoomBearer implements RoomBearer {
  final PrivateNetwork net;
  final _frames = StreamController<RoomFrame>.broadcast();
  _I2pRoomBearer(this.net);

  @override
  Stream<RoomFrame> get frames => _frames.stream;

  void deliver(RoomFrame f) => _frames.add(f);

  @override
  Future<bool> send(String b32, String payload) async {
    final bytes = utf8.encode(payload);
    if (bytes.length > _maxFrame) {
      net.note('rooms: a ${bytes.length} byte frame is over the limit, not sent');
      return false;
    }
    try {
      return await net.sendRaw(b32, roomI2pPort, bytes);
    } catch (_) {
      return false;
    }
  }
}

/// The chat room of one mined coin: an XPRS open group (docs/architecture.md,
/// "Coin rooms") kept by the miners in it. Its [engine] exists once the
/// station key is loaded; it goes [online] while the private network is up
/// and the user is in the room.
class ChatRoom extends ChangeNotifier {
  final String minerId;
  final String coin;
  final String name;
  final _I2pRoomBearer _bearer;
  ChatRoom(this.minerId, this.coin, this.name, PrivateNetwork net) : _bearer = _I2pRoomBearer(net);

  RoomEngine? engine;
  bool online = false;
  bool _joining = false;
  List<String>? _meeting;

  /// The meeting address this device answers for while online.
  String? slotAddress;
  StreamSubscription<void>? _sub;
  int _unread = 0;

  /// This device's open claims to the room's moderator rights (null when
  /// the room has no moderation).
  ClaimBook? claims;

  /// Whether the room's moderator rights can be bought.
  bool get moderated => engine?.moderated ?? false;

  RoomStore? get store => engine?.store;
  int get unread => engine?.store.unread ?? 0;
  RoomState get state => online ? (engine?.state ?? RoomState.offline) : RoomState.offline;

  void _attach(RoomEngine e, VoidCallback onUnread) {
    engine = e;
    _sub = e.changes.listen((_) {
      notifyListeners();
      final u = unread;
      if (u != _unread) {
        _unread = u;
        onUnread();
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

/// One [ChatRoom] per mined coin, carried by the private network (I2P).
///
/// - Rooms in [joined] go online whenever the network is up: this device
///   publishes one of the room's meeting addresses with its own tunnels,
///   greets the others and remembered members, and catches up on the last
///   two weeks.
/// - Frames on [roomI2pPort] reach the room they name (`"room"` in control
///   frames, `d:`/`only:` in XPRS lines); a history result that names no
///   room goes to every online room, whose engine keeps only its own.
/// - Contacts with an `i2p` field are offered as possible members.
class RoomService extends ChangeNotifier {
  final String dataDir;
  final PrivateNetwork net;
  final ContactBook contacts;

  /// Decides on claims when this device is the rooms' admin.
  final ModerationAdmin? admin;

  /// Names of the rooms the user is in (the app's settings).
  final Set<String> Function() joined;
  final List<ChatRoom> rooms;

  RoomService({
    required this.dataDir,
    required this.net,
    required this.contacts,
    required this.joined,
    required List<(String minerId, String coin)> coins,
    this.admin,
  }) : rooms = [
          for (final (id, coin) in coins)
            if (roomNameFor(coin) case final name?) ChatRoom(id, coin, name, net),
        ] {
    net.addListener(sync);
    contacts.addListener(_contactsChanged);
  }

  bool _ready = false;
  Timer? _claimTimer;
  int _generation = -1;
  StreamSubscription<I2pMessage>? _sub;

  ChatRoom? roomFor(String minerId) => rooms.where((r) => r.minerId == minerId).firstOrNull;

  /// Opens every room's store (reading happens off the UI isolate), then
  /// joins as [sync] decides.
  Future<void> start() async {
    if (_ready) return;
    final keys = await net.keys();
    final st = keys.station;
    for (final r in rooms) {
      final moderated = ModerationConfig.on(r.minerId);
      final e = RoomEngine(
        room: r.name,
        store: RoomStore('$dataDir/rooms/${r.name}', r.name),
        bearer: r._bearer,
        privHex: st.privateKeyHex,
        self: st.callsign,
        log: net.note,
        admin: moderated ? ModerationConfig.adminCallsign : null,
        adminKeyHex: moderated ? ModerationConfig.adminKeyHex : null,
      )..nick = contacts.myName;
      await e.start();
      r._attach(e, notifyListeners);
      if (moderated) {
        r.claims = ClaimBook('$dataDir/rooms/${r.name}');
        await r.claims!.load();
        final a = admin;
        if (e.isAdmin && a != null) {
          e.claims.listen((c) async => net.note('rooms: ${r.name}: ${await a.decide(e, c)}'));
        }
      }
    }
    _claimTimer = Timer.periodic(const Duration(minutes: 1), (_) => unawaited(_resendClaims()));
    _ready = true;
    sync();
    notifyListeners();
  }

  /// Follows the network and [joined]: a new node (restart) means joining
  /// again, since shared addresses and listeners belonged to the old one.
  void sync() {
    if (!_ready) return;
    final up = net.state == PrivateNetworkState.up && net.address != null && net.messages != null;
    if (!up) {
      if (_generation != -1) {
        _generation = -1;
        unawaited(_sub?.cancel());
        _sub = null;
        for (final r in rooms) {
          _offline(r);
        }
        notifyListeners();
      }
      return;
    }
    if (net.generation != _generation) {
      _generation = net.generation;
      unawaited(_sub?.cancel());
      _sub = net.messages!.listen(_onMessage);
      for (final r in rooms) {
        _offline(r);
      }
    }
    // The admin is in every room with moderation: claims reach it there.
    final want = {...joined(), for (final r in rooms) if (r.engine?.isAdmin ?? false) r.name};
    for (final r in rooms) {
      if (want.contains(r.name)) {
        if (!r.online && !r._joining) unawaited(_join(r));
      } else if (r.online) {
        final slot = r.slotAddress;
        _offline(r);
        if (slot != null) unawaited(net.removeShared(slot));
      }
    }
  }

  void _offline(ChatRoom r) {
    if (!r.online) return;
    r.online = false;
    r.slotAddress = null;
    r.engine?.offline();
    r.notifyListeners();
  }

  Future<void> _join(ChatRoom r) async {
    final e = r.engine, address = net.address, gen = _generation;
    if (e == null || address == null) return;
    r._joining = true;
    try {
      final meeting = r._meeting ??= await _meetingAddresses(r.name);
      final hash = I2pService.decodeB32(address);
      if (hash == null) return;
      final (enc, sign) = roomSlotSeeds(r.name, slotFor(hash));
      final slot = await net.addShared(enc, sign);
      if (gen != _generation || net.address != address) return; // restarted meanwhile
      r.slotAddress = slot;
      r.online = true;
      e.online(address, meeting);
      _hint(r);
      net.note('rooms: in ${r.name}, answering for meeting address ${slot?.substring(0, 8) ?? '(none)'}');
    } catch (err) {
      net.note('rooms: joining ${r.name} failed: $err');
    } finally {
      r._joining = false;
      r.notifyListeners();
      notifyListeners();
    }
  }

  void _hint(ChatRoom r) {
    final e = r.engine;
    if (e == null || !r.online) return;
    for (final c in contacts.contacts) {
      for (final f in c.fieldsOf('i2p')) {
        final b = f.value.trim().toLowerCase();
        if (b.endsWith('.b32.i2p')) e.hint(b, c.callsign);
      }
    }
  }

  void _contactsChanged() {
    for (final r in rooms) {
      r.engine?.nick = contacts.myName;
      _hint(r);
    }
  }

  void _onMessage(I2pMessage m) {
    if (m.port != roomI2pPort) return;
    final String text;
    try {
      text = utf8.decode(m.payload);
    } catch (_) {
      return;
    }
    final online = [for (final r in rooms) if (r.online) r];
    if (online.isEmpty) return;
    final named = roomNamesIn(text);
    var to = [for (final r in online) if (named.contains(r.name)) r];
    // Nothing named a room we are in: a meeting address says which, else
    // (a bare history result) every room looks.
    if (to.isEmpty && text.startsWith('{')) return;
    if (to.isEmpty) to = [for (final r in online) if (r._meeting?.contains(m.toB32) ?? false) r];
    if (to.isEmpty) to = online;
    final f = RoomFrame(m.fromB32, m.toB32, text);
    for (final r in to) {
      r._bearer.deliver(f);
    }
  }

  /// Buys [r]'s moderator rights: pays [amount] (the coin's smallest unit)
  /// from [wallet], keeps the claim and sends it to the admin (again every
  /// minute until a grant answers it).
  Future<ModClaim> buyModeration(ChatRoom r, Wallet wallet, BigInt amount, {String? password}) async {
    final e = r.engine, book = r.claims;
    if (e == null || book == null) throw const ClaimError('This room has no moderator rights to buy.');
    final c = await payForModeration(wallet: wallet, room: r.name, callsign: e.self, amount: amount, password: password);
    await book.add(c);
    net.note('rooms: ${r.name}: paid $amount for the moderator rights in ${c.txid.substring(0, 12)}');
    unawaited(e.sendClaim(c.toJson()));
    r.notifyListeners();
    return c;
  }

  /// Claims still waiting for a grant go to the admin again; answered,
  /// outbid or stale ones are dropped.
  Future<void> _resendClaims() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final r in rooms) {
      final e = r.engine, book = r.claims;
      if (e == null || book == null || book.claims.isEmpty) continue;
      final m = e.moderation;
      await book.removeWhere((c) =>
          now - c.tsMs > ModerationConfig.claimLife.inMilliseconds ||
          (m.term?.callsign == e.self && m.term!.startMs >= c.tsMs - 600000) ||
          (m.term != null && m.term!.callsign != e.self && m.toBeat >= c.amount && m.term!.startMs >= c.tsMs));
      for (final c in book.claims) {
        await e.sendClaim(c.toJson());
      }
    }
  }

  /// Saves members and stores (the app is quitting).
  Future<void> close() async {
    _claimTimer?.cancel();
    unawaited(_sub?.cancel());
    for (final r in rooms) {
      await r.engine?.close();
    }
  }

  @override
  void dispose() {
    net.removeListener(sync);
    contacts.removeListener(_contactsChanged);
    unawaited(_sub?.cancel());
    for (final r in rooms) {
      r.dispose();
    }
    super.dispose();
  }
}
