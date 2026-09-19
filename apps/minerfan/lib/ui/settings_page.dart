import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xmr_core/xmr_core.dart' show MoneroRpc;

import '../app_controller.dart';
import '../network/private_network.dart';
import '../desktop.dart';
import '../mining_service.dart';
import '../theme.dart';
import 'account_keys.dart';
import 'admin_rooms.dart';
import 'update_ui.dart';
import 'widgets.dart';

/// App-wide settings: power use, theme, web server/API.
class SettingsPage extends StatelessWidget {
  final AppController app;
  const SettingsPage(this.app, {super.key});

  @override
  Widget build(BuildContext context) {
    final s = app.settings;
    final t = Theme.of(context);
    final locked = app.runningCount > 0;
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const SectionTitle('Power usage profile'),
        SegmentedButton<PowerProfile>(
          showSelectedIcon: false,
          segments: [
            // Icons only where there is room; labels shrink instead of wrapping.
            for (final (p, label, icon) in const [
              (PowerProfile.performance, 'Performance', Icons.bolt),
              (PowerProfile.balanced, 'Balanced', Icons.tune),
              (PowerProfile.eco, 'Eco', Icons.eco),
            ])
              ButtonSegment(
                value: p,
                label: FittedBox(fit: BoxFit.scaleDown, child: Text(label, maxLines: 1)),
                icon: MediaQuery.sizeOf(context).width >= 600 ? Icon(icon) : null,
              ),
          ],
          selected: {s.power},
          onSelectionChanged: (v) {
            s.power = v.first;
            app.save();
          },
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(switch (s.power) {
            PowerProfile.performance => 'Every configured thread, all the time. For a machine that does nothing else.',
            PowerProfile.balanced =>
              'Flexible CPU/RAM mining: mines in idle time and steps aside for your work. One '
                  'thread fewer for every core other programs use, paused when they fill the CPU; when memory runs '
                  'low it gives the 2 GiB fast-mode dataset back, and pauses if memory gets critical. Threads and '
                  'fast mode come back as the load goes.',
            PowerProfile.eco => 'Balanced, on half the configured threads: cooler, quieter and less power.',
          }),
        ),
        if (locked)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('A change applies the next time a miner starts.', style: muted),
          ),
        if (Platform.isAndroid) ...[
          FutureBuilder<bool>(
            future: MiningService.batteryExempt(),
            builder: (context, snap) {
              final ok = snap.data ?? false;
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(ok ? Icons.battery_charging_full : Icons.battery_alert),
                title: const Text('Background mining'),
                subtitle: Text(
                  ok
                      ? 'Allowed: minerfan is exempt from battery optimization, so it keeps mining in the background '
                            'and restarts mining if the system stops it.'
                      : 'Not allowed yet: the system may stop the miner in the background and it cannot restart '
                            'by itself. Tap to allow.',
                ),
                onTap: ok
                    ? null
                    : () async {
                        await MiningService.requestBatteryExemption();
                        s.askedBattery = true;
                        app.save();
                      },
              );
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Thermal control'),
            subtitle: const Text(
              'Uses fewer threads while the phone is hot and adds them back as it cools, so it '
              'mines steadily instead of throttling hard. Pauses mining if the phone gets critically hot.',
            ),
            value: s.thermalControl,
            onChanged: locked
                ? null
                : (v) {
                    s.thermalControl = v;
                    app.save();
                  },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Sustained performance'),
            subtitle: Text(
              app.sustainedSupported
                  ? 'Asks Android to hold the CPU at clocks this phone can keep up for hours, instead of bursting '
                        'and then throttling. Applies while the app is on screen.'
                  : 'Not offered by this phone (Android lets vendors opt out). Thermal control does the same job '
                        'by adjusting threads.',
            ),
            value: s.sustainedPerformance && app.sustainedSupported,
            onChanged: locked || !app.sustainedSupported
                ? null
                : (v) {
                    s.sustainedPerformance = v;
                    app.save();
                  },
          ),
        ],
        if (Desktop.supported) ...[
          const SectionTitle('Desktop'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Start with the computer'),
            subtitle: const Text(
              'Opens minimized in the dock when you log in; with the master switch on, it '
              'resumes mining.',
            ),
            value: s.startWithComputer,
            onChanged: app.setStartWithComputer,
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 6),
            child: Text('When you close the window', style: t.textTheme.bodyMedium),
          ),
          SegmentedButton<CloseAction>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: CloseAction.ask, label: Text('Ask')),
              ButtonSegment(value: CloseAction.dock, label: Text('Keep mining')),
              ButtonSegment(value: CloseAction.quit, label: Text('Quit')),
            ],
            selected: {s.closeAction},
            onSelectionChanged: (v) => app.setCloseAction(v.first),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              switch (s.closeAction) {
                CloseAction.ask => 'The close button asks whether to keep mining in the dock or to quit.',
                CloseAction.dock => 'The close button sends minerfan to the dock and it keeps mining.',
                CloseAction.quit => 'The close button stops the miners and quits.',
              },
              style: muted,
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.power_settings_new),
            title: const Text('Quit minerfan'),
            subtitle: const Text('Stops the miners and quits, whatever the close button does.'),
            onTap: app.quit,
          ),
        ],
        const SectionTitle('Theme color'),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final (name, argb) in accentColors)
              Tooltip(
                message: name,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () {
                    s.accent = argb;
                    app.save();
                  },
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Color(argb),
                      shape: BoxShape.circle,
                      border: Border.all(color: s.accent == argb ? Colors.white : Colors.transparent, width: 2.5),
                    ),
                    child: s.accent == argb
                        ? Icon(
                            Icons.check,
                            size: 20,
                            color: Color(argb).computeLuminance() > 0.45 ? Colors.black : Colors.white,
                          )
                        : null,
                  ),
                ),
              ),
          ],
        ),
        const SectionTitle('Monero sending'),
        Text(
          'Sending Monero needs decoy outputs from the whole chain, which the P2P network does not offer, so they come '
          'from the RPC of a node. It learns which outputs are requested (and your IP), never your keys. Receiving and '
          'balances use our own P2P peers only.',
          style: muted,
        ),
        _MoneroNodeField(app),
        const SectionTitle('Private network (I2P)'),
        _PrivateNetworkSection(app),
        if (signsAsRoomsAdmin(app)) ...[
          const SectionTitle('Rooms admin'),
          AdminRoomsSection(app),
        ],
        const SectionTitle('Web server and API'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Local web server and API'),
          subtitle: const Text(
            'Not available yet. It will serve the dashboard and a JSON API for monitoring and '
            'control on this machine.',
          ),
          value: s.apiEnabled,
          onChanged: null,
        ),
        const SectionTitle('Updates'),
        UpdateSection(app),
        const SectionTitle('About'),
        Text('minerfan', style: t.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text('Data: ${app.dataDir}', style: muted),
      ],
    );
  }
}

class _MoneroNodeField extends StatefulWidget {
  final AppController app;
  const _MoneroNodeField(this.app);

  @override
  State<_MoneroNodeField> createState() => _MoneroNodeFieldState();
}

class _MoneroNodeFieldState extends State<_MoneroNodeField> {
  late final TextEditingController _url = TextEditingController(text: widget.app.settings.moneroNode);

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: TextField(
          controller: _url,
          decoration: const InputDecoration(labelText: 'Node URL (http or https, with port)'),
          onSubmitted: (v) => widget.app.setMoneroNode(v),
        ),
      ),
      PopupMenuButton<String>(
        tooltip: 'Public nodes',
        icon: const Icon(Icons.list),
        onSelected: (v) {
          _url.text = v;
          widget.app.setMoneroNode(v);
        },
        itemBuilder: (_) => [for (final n in MoneroRpc.defaultNodes) PopupMenuItem(value: n, child: Text(n))],
      ),
    ],
  );
}

class _PrivateNetworkSection extends StatelessWidget {
  final AppController app;
  const _PrivateNetworkSection(this.app);

  @override
  Widget build(BuildContext context) {
    final n = app.privateNetwork;
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final status = switch (n.state) {
      PrivateNetworkState.off => 'Off',
      PrivateNetworkState.starting => 'Joining the I2P network (about a minute the first time)',
      PrivateNetworkState.up => 'Connected: ${n.gateways} inbound tunnel${n.gateways == 1 ? '' : 's'} and an outbound one',
      PrivateNetworkState.failed => 'Could not join the I2P network; see the log',
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Run the I2P node'),
        subtitle: Text(status),
        value: app.settings.i2pEnabled,
        onChanged: app.setI2p,
      ),
      Text(
        'The app runs its own I2P node, in pure Dart: no router to install. minerfan and xprs clients reach each other '
        'through it without servers and without revealing their IP addresses. Messages are XPRS packets, signed '
        'with the callsign of this device; direct messages are sealed to their recipient. The chat rooms of the coins '
        '(the Chat tab of each miner) travel on it too, and their messages are public.',
        style: muted,
      ),
      if (n.station != null) ...[
        const SizedBox(height: 10),
        _copyable(context, 'Callsign', n.station!.callsign, 'Callsign copied'),
        _copyable(context, 'Public key', n.station!.npub, 'Public key copied'),
        AccountRows(n),
      ],
      if (n.address != null) ...[
        _copyable(context, 'I2P address', n.address!, 'I2P address copied'),
        Text(
            'The callsign, key and address stay the same across starts; the keys are kept encrypted with this '
            'device key.',
            style: muted),
      ],
      if (n.state == PrivateNetworkState.failed)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(onPressed: () => n.start(), child: const Text('Try again')),
        ),
      if (n.log.isNotEmpty)
        Theme(
          data: t.copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text('Log', style: t.textTheme.bodyMedium),
            children: [
              Container(
                constraints: const BoxConstraints(maxHeight: 220),
                width: double.infinity,
                child: ListView(
                  reverse: true,
                  children: [
                    for (final l in n.log.reversed)
                      Text(l, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                  ],
                ),
              ),
            ],
          ),
        ),
    ]);
  }

  Widget _copyable(BuildContext context, String label, String value, String copied) {
    final t = Theme.of(context);
    return Row(children: [
      SizedBox(width: 92, child: Text(label, style: t.textTheme.bodySmall)),
      Expanded(child: SelectableText(value, style: const TextStyle(fontFamily: 'monospace', fontSize: 12))),
      IconButton(
        tooltip: 'Copy',
        icon: const Icon(Icons.copy, size: 18),
        onPressed: () {
          Clipboard.setData(ClipboardData(text: value));
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(copied)));
        },
      ),
    ]);
  }
}
