import 'dart:io';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../desktop.dart';
import '../mining_service.dart';
import '../update/update_manifest.dart';
import '../update/updater.dart';
import '../update/version.dart';

/// The line at the top of the dashboard when a new version is out: what
/// it is, and one button that does the next thing (download, then
/// install). It stays out of the way until there is something to say.
class UpdateBanner extends StatelessWidget {
  final AppController app;
  const UpdateBanner(this.app, {super.key});

  @override
  Widget build(BuildContext context) {
    final u = app.updater;
    if (!u.shows) return const SizedBox.shrink();
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return Card(
      color: t.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.system_update_alt, color: t.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                u.state == UpdateState.ready
                    ? '${u.manifest?.app ?? 'minerfan'} ${u.newVersion} is ready to install'
                    : '${u.manifest?.app ?? 'minerfan'} ${u.newVersion} is out (you have $appVersion)',
                style: t.textTheme.titleSmall,
              ),
            ),
          ]),
          if ((u.manifest?.notes ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 34),
              child: Text(u.manifest!.notes, style: muted, maxLines: 3, overflow: TextOverflow.ellipsis),
            ),
          if (u.state == UpdateState.downloading || u.state == UpdateState.paused)
            Padding(
              padding: const EdgeInsets.only(top: 10, left: 34),
              child: _Progress(u),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 26),
            child: Wrap(spacing: 8, runSpacing: 4, children: updateActions(context, app, dense: true)),
          ),
        ]),
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  final Updater u;
  const _Progress(this.u);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      LinearProgressIndicator(value: u.total > 0 ? u.progress : null),
      const SizedBox(height: 4),
      Text(
        u.total > 0
            ? '${_mb(u.received)} of ${_mb(u.total)} (${(u.progress * 100).round()} percent)'
            : '${_mb(u.received)} so far',
        style: muted,
      ),
    ]);
  }
}

String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

/// The buttons that suit what the updater is doing, shared by the banner
/// and the settings section.
List<Widget> updateActions(BuildContext context, AppController app, {bool dense = false}) {
  final u = app.updater;
  void say(String m) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(m)));

  Future<void> install() async {
    final path = u.readyFile;
    if (path == null) return;
    if (Platform.isAndroid) {
      final ok = await MiningService.openFile(path);
      if (!ok) say('Android would not open it. The file is at $path');
      return;
    }
    final shown = await Desktop.showInFolder(path);
    if (!shown) say('The file is at $path');
  }

  return [
    if (u.state == UpdateState.available)
      FilledButton.icon(
        onPressed: u.manifest?.mine == null ? null : u.download,
        icon: const Icon(Icons.download, size: 18),
        label: Text(u.manifest?.mine == null ? 'No build for this machine' : 'Download'),
      ),
    if (u.state == UpdateState.downloading)
      OutlinedButton.icon(
        onPressed: u.pause,
        icon: const Icon(Icons.pause, size: 18),
        label: const Text('Pause'),
      ),
    if (u.state == UpdateState.paused)
      FilledButton.icon(
        onPressed: u.download,
        icon: const Icon(Icons.download, size: 18),
        label: const Text('Carry on'),
      ),
    if (u.state == UpdateState.ready) ...[
      FilledButton.icon(
        onPressed: install,
        icon: const Icon(Icons.open_in_new, size: 18),
        label: Text(Platform.isAndroid ? 'Install' : 'Show the file'),
      ),
      if (!dense)
        TextButton(onPressed: u.discard, child: const Text('Throw it away')),
    ],
    if (u.state != UpdateState.ready && u.state != UpdateState.downloading)
      TextButton(onPressed: u.skip, child: const Text('Not now')),
  ];
}

/// The Updates section of Settings: what this build is, what the site
/// says, and where to look (which can move).
class UpdateSection extends StatefulWidget {
  final AppController app;
  const UpdateSection(this.app, {super.key});

  @override
  State<UpdateSection> createState() => _UpdateSectionState();
}

class _UpdateSectionState extends State<UpdateSection> {
  late final _url = TextEditingController(text: widget.app.updater.url);

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final u = widget.app.updater;
    final build = u.manifest?.mine;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('This is ${u.manifest?.app ?? 'minerfan'} $appVersion for $currentPlatform.', style: t.textTheme.bodyMedium),
      const SizedBox(height: 4),
      Text(
        switch (u.state) {
          UpdateState.checking => 'Asking the site...',
          UpdateState.current => u.lastCheck == null
              ? 'Not asked yet.'
              : 'Nothing newer on the site, asked ${_ago(u.lastCheck!)}.',
          UpdateState.available => '${u.newVersion} is out.'
              '${build == null ? ' The site has no build for this machine.' : ''}',
          UpdateState.downloading => 'Downloading ${u.newVersion}.',
          UpdateState.paused => 'Downloading ${u.newVersion} stopped part way; it carries on where it left off.',
          UpdateState.ready => '${u.newVersion} is downloaded and checked. ${installHint(build?.fileName ?? '')}',
          UpdateState.failed => 'The last try did not work.',
        },
        style: muted,
      ),
      if (u.error != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(u.error!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error)),
        ),
      if (u.state == UpdateState.downloading || u.state == UpdateState.paused)
        Padding(padding: const EdgeInsets.only(top: 8), child: _Progress(u)),
      if (u.readyFile != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: SelectableText(u.readyFile!, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
        ),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 4, children: [
        OutlinedButton.icon(
          onPressed: u.state == UpdateState.checking ? null : () => u.check(force: true),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Check now'),
        ),
        ...updateActions(context, widget.app),
      ]),
      const SizedBox(height: 12),
      TextField(
        controller: _url,
        decoration: const InputDecoration(labelText: 'Where to look for updates'),
        onSubmitted: (v) => u.setUrl(v),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          'The app asks this address once a day for the newest version, and downloads only when you say so. '
          'The file that answers can send the app somewhere else later, so this keeps working if the project '
          'moves or is renamed.',
          style: muted,
        ),
      ),
    ]);
  }

  static String _ago(DateTime at) {
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} minutes ago';
    if (d.inDays < 1) return '${d.inHours} hours ago';
    return '${d.inDays} days ago';
  }
}
