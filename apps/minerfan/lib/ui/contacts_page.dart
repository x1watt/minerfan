import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../contacts/contact.dart';
import '../contacts/contact_card.dart';
import '../contacts/qr_decode.dart';
import 'contact_edit_page.dart';
import 'field_types.dart';
import 'my_card_page.dart';
import 'scan_page.dart';

bool get _hasCamera => Platform.isAndroid || Platform.isIOS;

/// The address book: search, your own card, and every contact. Contacts
/// come from a scanned or pasted card (signed by their key) or are typed
/// in.
class ContactsPage extends StatefulWidget {
  final AppController app;
  const ContactsPage(this.app, {super.key});

  @override
  State<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends State<ContactsPage> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(Contact c, String q) {
    if (q.isEmpty) return true;
    bool has(String s) => s.toLowerCase().contains(q);
    return has(c.name) || has(c.callsign) || has(c.npub) || has(c.note) || c.fields.any((f) => has(f.value) || has(f.label));
  }

  Future<void> _add(BuildContext context) async {
    final how = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.qr_code_scanner),
            title: Text(_hasCamera ? 'Scan their QR code' : 'Read their card'),
            subtitle: Text(_hasCamera ? 'The card on their screen' : 'Paste it, or open an image of the QR code'),
            onTap: () => Navigator.pop(context, 'read'),
          ),
          ListTile(
            leading: const Icon(Icons.key_outlined),
            title: const Text('Type their public key'),
            subtitle: const Text('npub1...; add their addresses by hand'),
            onTap: () => Navigator.pop(context, 'key'),
          ),
        ]),
      ),
    );
    if (!context.mounted) return;
    if (how == 'read') {
      await readContact(context, widget.app);
    } else if (how == 'key') {
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ContactEditPage(widget.app)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Contacts'),
        actions: [
          IconButton(
            tooltip: 'Your card (QR code)',
            icon: const Icon(Icons.qr_code_2),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => MyCardPage(app))),
          ),
          IconButton(
            tooltip: _hasCamera ? 'Scan a card' : 'Read a card',
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: () => readContact(context, app),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _add(context),
        icon: const Icon(Icons.person_add_alt_1_outlined),
        label: const Text('Add contact'),
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([app.contacts, app.privateNetwork]),
          builder: (context, _) {
            final q = _search.text.trim().toLowerCase();
            final list = app.contacts.contacts.where((c) => _matches(c, q)).toList();
            final me = app.privateNetwork.station;
            return ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 96), children: [
              Card(
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  leading: const Icon(Icons.badge_outlined),
                  title: Text(app.contacts.myName.isNotEmpty ? 'You: ${app.contacts.myName}' : 'Your card'),
                  subtitle: Text(me == null ? 'Loading your key...' : '${me.callsign}  ·  show it as a QR code to share'),
                  trailing: const Icon(Icons.qr_code_2),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => MyCardPage(app))),
                ),
              ),
              if (app.contacts.contacts.length > 5)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: TextField(
                    controller: _search,
                    decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              if (app.contacts.contacts.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'No contacts yet. Scan someone\'s card, or show them yours: a card carries a public key (who they '
                    'are, with the callsign that comes from it) and the addresses they chose to share, signed by '
                    'that key.',
                    style: muted,
                  ),
                ),
              for (final c in list)
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    leading: CircleAvatar(child: Text(c.title.isEmpty ? '?' : c.title[0].toUpperCase())),
                    title: Row(children: [
                      Flexible(child: Text(c.title, overflow: TextOverflow.ellipsis)),
                      if (c.verified) ...[
                        const SizedBox(width: 6),
                        Icon(Icons.verified_outlined, size: 16, color: t.colorScheme.primary),
                      ],
                    ]),
                    subtitle: Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      Text(c.callsign, style: const TextStyle(fontFamily: 'monospace')),
                      for (final type in {for (final f in c.fields) f.type}) Icon(fieldIcon(type), size: 14),
                    ]),
                    onTap: () => Navigator.of(context)
                        .push(MaterialPageRoute<void>(builder: (_) => ContactEditPage(app, contact: c))),
                  ),
                ),
            ]);
          },
        ),
      ),
    );
  }
}

/// Reads a contact: the camera on phones, a paste or an image elsewhere
/// (the paste is offered on phones too). A signed card becomes a contact
/// after a look at what it holds; a bare public key opens a new contact.
Future<void> readContact(BuildContext context, AppController app) async {
  bool looksRight(String t) => t.trim().startsWith(ContactCard.prefix) || Contact.parseKey(t) != null;
  String? text;
  if (_hasCamera) {
    text = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => ScanPage(accept: looksRight, title: 'Scan a contact card')),
    );
    if (text == ScanPage.pasteInstead && context.mounted) text = await _pasteOrImage(context, cameraFirst: true);
  } else {
    text = await _pasteOrImage(context);
  }
  if (text == null || !context.mounted) return;
  await importContactText(context, app, text);
}

Future<String?> _pasteOrImage(BuildContext context, {bool cameraFirst = false}) async {
  final field = TextEditingController();
  final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
  if (clip.startsWith(ContactCard.prefix) || Contact.parseKey(clip) != null) field.text = clip;
  if (!context.mounted) return null;
  String? error;
  final r = await showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialog) => AlertDialog(
        title: const Text('Read a contact card'),
        content: SizedBox(
          width: 520,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(cameraFirst
                ? 'Or paste the card they sent you (text starting with xprs-contact:) or their public key.'
                : 'Paste the card they sent you (text starting with xprs-contact:) or their public key, or open an '
                    'image of their QR code.'),
            TextField(
              controller: field,
              minLines: 2,
              maxLines: 5,
              decoration: InputDecoration(hintText: 'xprs-contact:1... or npub1...', errorText: error),
            ),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final file = await openFile(acceptedTypeGroups: const [
                XTypeGroup(label: 'Images', extensions: ['png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp']),
              ]);
              if (file == null) return;
              final bytes = await file.readAsBytes();
              final text = await decodeImageFileInBackground(bytes);
              if (text == null) {
                setDialog(() => error = 'No QR code found in that image');
              } else {
                field.text = text;
                setDialog(() => error = null);
              }
            },
            child: const Text('Open an image'),
          ),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, field.text.trim()), child: const Text('Read')),
        ],
      ),
    ),
  );
  field.dispose();
  return r == null || r.isEmpty ? null : r;
}

/// Adds or updates a contact from a card, or starts one from a public key.
Future<void> importContactText(BuildContext context, AppController app, String text) async {
  final t = text.trim();
  final card = t.startsWith(ContactCard.prefix) ? await parseCardInBackground(t) : null;
  if (!context.mounted) return;
  void say(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  if (card == null) {
    final npub = Contact.parseKey(t);
    if (npub == null) {
      return say(t.startsWith(ContactCard.prefix)
          ? 'This card is damaged or its signature does not match its key'
          : 'This is not a contact card or a public key');
    }
    final existing = app.contacts.byNpub(npub);
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ContactEditPage(app, contact: existing, npub: npub),
    ));
    return;
  }
  if (card.npub == app.privateNetwork.station?.npub) return say('That is your own card');
  final existing = app.contacts.byNpub(card.npub);
  final th = Theme.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(existing == null ? 'Add ${card.name.isEmpty ? card.callsign : card.name}?' : 'Update ${existing.title}?'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.verified_outlined, size: 18, color: th.colorScheme.primary),
              const SizedBox(width: 6),
              Text(card.callsign, style: th.textTheme.titleMedium),
            ]),
            const SizedBox(height: 4),
            Text('Signed by ${card.npub.substring(0, 16)}...: these addresses were published by whoever holds that '
                'key.'),
            const SizedBox(height: 8),
            for (final f in card.fields)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(fieldIcon(f.type)),
                title: Text(f.label.isEmpty ? fieldLabel(f.type) : '${fieldLabel(f.type)} (${f.label})'),
                subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(f.value, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                  if (fieldType(f.type)?.check?.call(f.value) case final err?)
                    Text('$err: it will not be offered for payments', style: TextStyle(color: th.colorScheme.error)),
                ]),
              ),
            if (existing != null)
              const Text('New addresses are added; what you typed for this contact stays.'),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(existing == null ? 'Add' : 'Update')),
      ],
    ),
  );
  if (ok != true) return;
  if (existing != null) {
    mergeCard(existing, card);
    await app.contacts.put(existing);
  } else {
    await app.contacts.put(card.toContact());
  }
  if (context.mounted) say(existing == null ? 'Contact added' : 'Contact updated');
}
