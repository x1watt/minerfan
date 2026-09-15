import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../wallets/keyed_wallet.dart';

/// Shown until the user confirms writing the recovery words down.
class BackupReminder extends StatelessWidget {
  final AppController app;
  final KeyedWallet w;
  const BackupReminder(this.app, this.w, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final text = Row(children: [
      Icon(Icons.shield_outlined, color: t.colorScheme.primary),
      const SizedBox(width: 12),
      const Expanded(
        child: Text('Back up this wallet: write down its recovery words. They restore it on any device if this one is '
            'lost.'),
      ),
    ]);
    final button = FilledButton.tonal(
      onPressed: () => showRecoveryPhrase(context, app, w),
      child: const Text('Show the words'),
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        // On a phone the button goes under the text, which otherwise wraps
        // one word per line.
        child: LayoutBuilder(
          builder: (context, c) => c.maxWidth < 560
              ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  text,
                  const SizedBox(height: 8),
                  Align(alignment: Alignment.centerRight, child: button),
                ])
              : Row(children: [Expanded(child: text), const SizedBox(width: 8), button]),
        ),
      ),
    );
  }
}

/// Shows the recovery words (after the password, when there is one) and
/// records that they were written down.
Future<void> showRecoveryPhrase(BuildContext context, AppController app, KeyedWallet w) async {
  final password = TextEditingController();
  String? phrase = w.hasPassword ? null : await w.recoveryPhrase();
  String? error;
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialog) => AlertDialog(
        title: Text(w.backupName[0].toUpperCase() + w.backupName.substring(1)),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (phrase == null) ...[
                Text('Enter the wallet password to show the ${w.backupName}.'),
                TextField(
                  controller: password,
                  obscureText: true,
                  autofocus: true,
                  decoration: InputDecoration(labelText: 'Wallet password', errorText: error),
                ),
              ] else ...[
                const Text(
                  'Write these words down in order and keep them offline. Anyone who has them can spend '
                  'this wallet.',
                ),
                const SizedBox(height: 12),
                SelectableText(phrase!, style: const TextStyle(fontFamily: 'monospace', fontSize: 16)),
              ],
            ],
          ),
        ),
        actions: [
          if (phrase == null)
            FilledButton(
              onPressed: () async {
                final p = await w.recoveryPhrase(password.text);
                setDialog(() => p == null ? error = 'Wrong password' : phrase = p);
              },
              child: const Text('Show'),
            )
          else if (!w.backedUp)
            FilledButton(
              onPressed: () {
                w.backedUp = true;
                app.saveWallets();
                Navigator.pop(context);
              },
              child: const Text('I wrote them down'),
            ),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    ),
  );
  password.dispose();
}

/// Sets, changes or removes the wallet's password.
Future<void> changePassword(BuildContext context, AppController app, KeyedWallet w) async {
  final current = TextEditingController(), next = TextEditingController(), again = TextEditingController();
  String? error;
  var busy = false;
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialog) {
        Future<void> apply(String? newPassword) async {
          if (newPassword != null && newPassword.length < 8) return setDialog(() => error = 'At least 8 characters');
          if (newPassword != null && newPassword != again.text) return setDialog(() => error = 'The passwords differ');
          setDialog(() => busy = true);
          final ok = await w.setPassword(current: w.hasPassword ? current.text : null, next: newPassword);
          if (!context.mounted) return;
          if (!ok) {
            return setDialog(() {
              busy = false;
              error = 'Wrong password';
            });
          }
          app.saveWallets();
          Navigator.pop(context);
        }

        return AlertDialog(
          title: Text(w.hasPassword ? 'Wallet password' : 'Set a password'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'A password is asked for every payment and for showing the recovery words. It cannot be '
                  'recovered: the recovery words are the backup.',
                ),
                if (w.hasPassword)
                  TextField(
                    controller: current,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Current password'),
                  ),
                TextField(
                  controller: next,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'New password'),
                ),
                TextField(
                  controller: again,
                  obscureText: true,
                  decoration: InputDecoration(labelText: 'New password again', errorText: error),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
            if (w.hasPassword)
              TextButton(onPressed: busy ? null : () => apply(null), child: const Text('Remove the password')),
            FilledButton(onPressed: busy ? null : () => apply(next.text), child: const Text('Save')),
          ],
        );
      },
    ),
  );
  for (final c in [current, next, again]) {
    c.dispose();
  }
}
