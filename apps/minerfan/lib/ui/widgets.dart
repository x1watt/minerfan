import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../miners/miner.dart';

/// A small labelled value.
class Stat extends StatelessWidget {
  final String label;
  final String value;
  final IconData? icon;
  const Stat(this.label, this.value, {super.key, this.icon});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                if (icon != null) ...[Icon(icon, size: 16, color: t.colorScheme.primary), const SizedBox(width: 6)],
                Expanded(
                  child: Text(
                    label,
                    style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value, style: t.textTheme.titleLarge, maxLines: 1),
            ),
          ],
        ),
      ),
    );
  }
}

/// Stats in 2 to 4 columns depending on the width.
Widget statGrid(BuildContext context, List<Widget> children) {
  final w = MediaQuery.sizeOf(context).width;
  final cols = w >= 1100 ? 4 : (w >= 720 ? 3 : 2);
  return GridView(
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: cols,
      mainAxisExtent: 88,
      mainAxisSpacing: 4,
      crossAxisSpacing: 6,
    ),
    children: children,
  );
}

/// The miner's ticker in a circle.
class MinerBadge extends StatelessWidget {
  final Miner miner;
  final double size;
  const MinerBadge(this.miner, {super.key, this.size = 40});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: c.primaryContainer,
        border: Border.all(color: miner.running ? c.primary : c.outlineVariant),
      ),
      child: Text(
        miner.symbol,
        style: TextStyle(fontSize: size * 0.28, fontWeight: FontWeight.w700, color: c.onPrimaryContainer),
      ),
    );
  }
}

/// One miner's own switch (see [AppController.setMinerOn]).
class MinerSwitch extends StatelessWidget {
  final AppController app;
  final Miner miner;
  const MinerSwitch(this.app, this.miner, {super.key});

  @override
  Widget build(BuildContext context) => Tooltip(
    message: miner.canStart ? (miner.running ? 'Stop ${miner.name}' : 'Start ${miner.name}') : miner.problem ?? '',
    child: Switch(
      value: miner.running || miner.starting,
      onChanged: miner.canStart && !miner.starting ? (v) => app.setMinerOn(miner, v) : null,
    ),
  );
}

class SectionTitle extends StatelessWidget {
  final String text;
  const SectionTitle(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 18, 4, 6),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}

/// Where a miner pays: one of the user's wallets of that coin, or another
/// address typed in. An empty value means the first wallet.
class PayoutPicker extends StatefulWidget {
  final List<({String label, String address})> wallets;
  final String value;
  final bool enabled;
  final TextEditingController otherController;
  final bool validOther;
  final String coinName;
  final ValueChanged<String> onChanged;

  const PayoutPicker({
    super.key,
    required this.wallets,
    required this.value,
    required this.enabled,
    required this.otherController,
    required this.validOther,
    required this.coinName,
    required this.onChanged,
  });

  @override
  State<PayoutPicker> createState() => _PayoutPickerState();
}

class _PayoutPickerState extends State<PayoutPicker> {
  static const _other = '#other';
  late bool _typing = widget.value.isNotEmpty && !widget.wallets.any((w) => w.address == widget.value);

  String _short(String a) => a.length > 20 ? '${a.substring(0, 8)}...${a.substring(a.length - 8)}' : a;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final selected = _typing || w.wallets.isEmpty
        ? _other
        : (w.wallets.any((x) => x.address == w.value) ? w.value : w.wallets.first.address);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      DropdownButtonFormField<String>(
        initialValue: selected,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Pay to'),
        items: [
          for (final x in w.wallets)
            DropdownMenuItem(
                value: x.address, child: Text('${x.label}  ·  ${_short(x.address)}', overflow: TextOverflow.ellipsis)),
          const DropdownMenuItem(value: _other, child: Text('Another address')),
        ],
        onChanged: !w.enabled
            ? null
            : (v) {
                setState(() => _typing = v == _other);
                w.onChanged(v == _other ? w.otherController.text.trim() : v!);
              },
      ),
      if (selected == _other)
        TextField(
          controller: w.otherController,
          enabled: w.enabled,
          decoration: InputDecoration(
            labelText: '${w.coinName} address',
            errorText: w.otherController.text.isEmpty || w.validOther ? null : 'Not a ${w.coinName} address',
          ),
          onChanged: (v) => w.onChanged(v.trim()),
        ),
    ]);
  }
}
