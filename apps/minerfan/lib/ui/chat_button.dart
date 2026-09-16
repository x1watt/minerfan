import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../miners/miner.dart';
import 'miners_page.dart';

/// The way into a coin's chat room from anywhere the coin is named (the
/// dashboard, the miners list, the wallets, a miner's own page). It shows
/// the room's unread count and opens the miner's Chat tab; it draws nothing
/// for a coin without a room.
class ChatButton extends StatelessWidget {
  final AppController app;

  /// The coin, as the miners and the wallets name it (`monero`).
  final String coinId;

  /// Smaller, for a list row or an app bar.
  final bool dense;
  const ChatButton(this.app, this.coinId, {this.dense = false, super.key});

  @override
  Widget build(BuildContext context) {
    final room = app.rooms.roomFor(coinId);
    final Miner? miner = app.miners.where((m) => m.id == coinId).firstOrNull;
    if (room == null || room.engine == null || miner == null) return const SizedBox.shrink();
    return IconButton(
      tooltip: 'Chat room',
      visualDensity: dense ? VisualDensity.compact : null,
      onPressed: () => openMiner(context, app, miner, chat: true),
      icon: Badge(
        isLabelVisible: room.unread > 0,
        label: Text('${room.unread}'),
        child: Icon(Icons.forum_outlined, size: dense ? 20 : null),
      ),
    );
  }
}
