import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../format.dart';
import '../shop/shop_image.dart';
import '../shop/shop_item.dart';
import 'camera_shot_page.dart';
import 'scan_page.dart' show hasCamera;
import 'shop_page.dart';

/// What is in one folder: the items, each a picture with its prices. A
/// tap puts one in the cart, the pencil opens it for editing.
class ShopCategoryPage extends StatelessWidget {
  final AppController app;
  final String categoryId;
  const ShopCategoryPage(this.app, this.categoryId, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final t = Theme.of(context);
        final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
        final category = app.shop.category(categoryId);
        if (category == null) return const Scaffold(body: Center(child: Text('This folder is gone.')));
        return Scaffold(
          appBar: AppBar(
            title: Text(category.title),
            actions: [
              PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'rename') {
                    final name = await askText(context, title: 'Rename the folder', initial: category.title);
                    if (name != null && name.trim().isNotEmpty) await app.shop.renameCategory(categoryId, name);
                  }
                  if (v == 'remove' && context.mounted) {
                    final ok = await _confirmRemoveFolder(context, category.title, category.items.length);
                    if (ok) {
                      await app.shop.removeCategory(categoryId);
                      if (context.mounted) Navigator.pop(context);
                    }
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('Rename')),
                  PopupMenuItem(value: 'remove', child: Text('Remove the folder')),
                ],
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => showItemSheet(context, app, categoryId),
            icon: const Icon(Icons.add),
            label: const Text('Add an item'),
          ),
          body: SafeArea(
            child: category.items.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Nothing in this folder yet. Add an espresso, a cake, whatever belongs here, with a picture '
                      'and a price in each coin you take.',
                      style: muted,
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                    children: [
                      for (final item in category.items)
                        _ItemCard(
                          app: app,
                          item: item,
                          onAdd: () {
                            app.shop.cart.add(item);
                            app.shop.notify();
                            ScaffoldMessenger.of(context)
                              ..hideCurrentSnackBar()
                              ..showSnackBar(SnackBar(
                                duration: const Duration(milliseconds: 1200),
                                content: Text('${item.title} added'),
                                action: SnackBarAction(
                                  label: 'Undo',
                                  onPressed: () {
                                    app.shop.cart.setCount(item.id, (app.shop.cart.lines
                                                .where((l) => l.item.id == item.id)
                                                .firstOrNull
                                                ?.count ??
                                            1) -
                                        1);
                                    app.shop.notify();
                                  },
                                ),
                              ));
                          },
                          onEdit: () => showItemSheet(context, app, categoryId, item: item),
                        ),
                    ],
                  ),
          ),
        );
      },
    );
  }
}

Future<bool> _confirmRemoveFolder(BuildContext context, String title, int items) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Remove $title?'),
      content: Text(items == 0
          ? 'The folder is empty, so nothing else goes with it.'
          : 'Everything in it goes too: $items item(s) and their pictures. Sales already recorded stay.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
      ],
    ),
  );
  return ok ?? false;
}

class _ItemCard extends StatelessWidget {
  final AppController app;
  final ShopItem item;
  final VoidCallback onAdd;
  final VoidCallback onEdit;
  const _ItemCard({required this.app, required this.item, required this.onAdd, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onAdd,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ShopPicture(shop: app.shop, image: item.image, size: 72, radius: 12),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(item.title, style: t.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (item.note.isNotEmpty)
                  Text(item.note, style: muted, maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  if (item.prices.isEmpty)
                    Text('No price yet', style: muted)
                  else
                    for (final e in item.prices.entries)
                      Chip(
                        visualDensity: VisualDensity.compact,
                        label: Text('${coins(e.value, decimals: coinDecimals(e.key))} ${_symbol(app, e.key)}'),
                      ),
                ]),
              ]),
            ),
            IconButton(tooltip: 'Edit', icon: const Icon(Icons.edit_outlined), onPressed: onEdit),
          ]),
        ),
      ),
    );
  }

  static String _symbol(AppController app, String chain) {
    for (final w in app.wallets) {
      if (w.chain == chain) return w.symbol;
    }
    return chain.toUpperCase();
  }
}

/// Adds an item, or edits one.
Future<void> showItemSheet(BuildContext context, AppController app, String categoryId, {ShopItem? item}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ItemSheet(app, categoryId, item),
    );

class _ItemSheet extends StatefulWidget {
  final AppController app;
  final String categoryId;
  final ShopItem? item;
  const _ItemSheet(this.app, this.categoryId, this.item);

  @override
  State<_ItemSheet> createState() => _ItemSheetState();
}

class _ItemSheetState extends State<_ItemSheet> {
  late final _title = TextEditingController(text: widget.item?.title ?? '');
  late final _note = TextEditingController(text: widget.item?.note ?? '');
  late final Map<String, TextEditingController> _prices = {
    for (final chain in _chains)
      chain: TextEditingController(
        text: widget.item?.prices[chain] == null
            ? ''
            : coins(widget.item!.prices[chain]!, decimals: coinDecimals(chain)),
      ),
  };

  late final String _id = widget.item?.id ?? newShopId();
  String? _image;
  bool _busy = false;
  String? _error;

  List<String> get _chains => [
        for (final chain in {for (final w in widget.app.wallets) w.chain}) chain,
      ];

  @override
  void initState() {
    super.initState();
    _image = widget.item?.image;
  }

  @override
  void dispose() {
    for (final c in [_title, _note, ..._prices.values]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _picture({required bool camera}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      Uint8List? raw;
      if (camera) {
        raw = await Navigator.of(context).push<Uint8List>(
          MaterialPageRoute(builder: (_) => const CameraShotPage(title: 'Photograph the item')),
        );
      } else {
        final file = await openFile(acceptedTypeGroups: const [
          XTypeGroup(label: 'Images', extensions: ['png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp']),
        ]);
        if (file != null) raw = await file.readAsBytes();
      }
      if (raw == null) return;
      final small = await shopImageInBackground(raw);
      if (small == null) {
        if (mounted) setState(() => _error = 'That file is not a picture this app can read.');
        return;
      }
      final old = _image;
      final name = await writeShopImage(widget.app.shop.imageDir, _id, small);
      if (old != null && old != name) {
        try {
          final f = File(widget.app.shop.imagePath(old));
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      if (mounted) setState(() => _image = name);
    } catch (e) {
      if (mounted) setState(() => _error = 'The picture did not work: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) return setState(() => _error = 'Give the item a name.');
    final prices = <String, int>{};
    for (final e in _prices.entries) {
      final text = e.value.text.trim();
      if (text.isEmpty) continue;
      final units = parseCoins(text, decimals: coinDecimals(e.key));
      if (units == null) return setState(() => _error = 'The ${_symbol(e.key)} price is not a number.');
      prices[e.key] = units;
    }
    if (prices.isEmpty) return setState(() => _error = 'Give it a price in at least one coin.');
    await widget.app.shop.putItem(
      widget.categoryId,
      ShopItem(
        id: _id,
        title: title,
        note: _note.text.trim(),
        image: _image,
        prices: prices,
        extra: widget.item?.extra,
      ),
    );
    if (mounted) Navigator.pop(context);
  }

  Future<void> _remove() async {
    await widget.app.shop.removeItem(widget.categoryId, _id);
    if (mounted) Navigator.pop(context);
  }

  String _symbol(String chain) {
    for (final w in widget.app.wallets) {
      if (w.chain == chain) return w.symbol;
    }
    return chain.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.item == null ? 'Add an item' : 'Edit the item', style: t.textTheme.titleMedium),
          const SizedBox(height: 14),
          Row(children: [
            ShopPicture(shop: widget.app.shop, image: _image, size: 88, radius: 12),
            const SizedBox(width: 12),
            Expanded(
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                if (hasCamera)
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _picture(camera: true),
                    icon: const Icon(Icons.camera_alt_outlined, size: 18),
                    label: const Text('Take a photo'),
                  ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _picture(camera: false),
                  icon: const Icon(Icons.image_outlined, size: 18),
                  label: const Text('Open an image'),
                ),
                if (_image != null)
                  TextButton(onPressed: _busy ? null : () => setState(() => _image = null), child: const Text('No picture')),
              ]),
            ),
          ]),
          const SizedBox(height: 14),
          TextField(
            controller: _title,
            autofocus: widget.item == null,
            decoration: const InputDecoration(labelText: 'Name', hintText: 'Espresso'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _note,
            maxLines: 2,
            minLines: 1,
            decoration: const InputDecoration(labelText: 'Description', hintText: 'Short and strong'),
          ),
          const SizedBox(height: 14),
          Text('Price per coin. Leave one empty and the item is not sold in that coin.', style: muted),
          const SizedBox(height: 8),
          for (final chain in _chains)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: TextField(
                controller: _prices[chain],
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: _symbol(chain), hintText: '0'),
              ),
            ),
          if (_error != null) ...[
            const SizedBox(height: 4),
            Text(_error!, style: TextStyle(color: t.colorScheme.error)),
          ],
          const SizedBox(height: 10),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            if (widget.item != null)
              TextButton(
                onPressed: _busy ? null : _remove,
                child: Text('Remove', style: TextStyle(color: t.colorScheme.error)),
              ),
            const Spacer(),
            TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Save'),
            ),
          ]),
        ]),
      ),
    );
  }
}
