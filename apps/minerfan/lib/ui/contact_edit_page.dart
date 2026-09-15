import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../contacts/contact.dart';
import 'fields_editor.dart';

/// Adds or edits a contact: the public key (their identity, fixed once
/// saved), a name, a note, and any number of addresses and accounts.
class ContactEditPage extends StatefulWidget {
  final AppController app;

  /// The contact to edit, or null for a new one.
  final Contact? contact;

  /// A key to start a new contact with (from a scan or a paste).
  final String? npub;

  /// A name and note to start a new contact with (someone met in a chat).
  final String? name;
  final String? note;
  const ContactEditPage(this.app, {this.contact, this.npub, this.name, this.note, super.key});

  @override
  State<ContactEditPage> createState() => _ContactEditPageState();
}

class _ContactEditPageState extends State<ContactEditPage> {
  late final _key = TextEditingController(text: widget.contact?.npub ?? widget.npub ?? '');
  late final _name = TextEditingController(text: widget.contact?.name ?? widget.name ?? '');
  late final _note = TextEditingController(text: widget.contact?.note ?? widget.note ?? '');
  late final List<ContactField> _fields = [
    for (final f in widget.contact?.fields ?? const <ContactField>[])
      ContactField(f.type, f.value, label: f.label, extra: Map.of(f.extra)),
  ];
  final _editor = GlobalKey<FieldsEditorState>();
  String? _error;

  bool get _isNew => widget.contact == null;

  @override
  void dispose() {
    for (final c in [_key, _name, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final npub = _isNew ? Contact.parseKey(_key.text) : widget.contact!.npub;
    if (npub == null) return setState(() => _error = 'Enter their public key: npub1... or 64 hex characters');
    final bad = _editor.currentState?.firstError();
    if (bad != null) return setState(() => _error = bad);
    final book = widget.app.contacts;
    if (_isNew && book.byNpub(npub) != null) {
      return setState(() => _error = 'This key is already a contact: ${book.byNpub(npub)!.title}');
    }
    final c = widget.contact ?? Contact(npub: npub);
    c
      ..name = _name.text.trim()
      ..note = _note.text.trim();
    c.fields
      ..clear()
      ..addAll(_fields.where((f) => f.value.trim().isNotEmpty));
    await book.put(c);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final c = widget.contact!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${c.title}?'),
        content: const Text('The contact and everything saved about them leave this device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await widget.app.contacts.remove(c);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final npub = Contact.parseKey(_key.text);
    final c = widget.contact;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'New contact' : c!.title),
        actions: [
          if (!_isNew) IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: _delete),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _save,
        icon: const Icon(Icons.check),
        label: const Text('Save'),
      ),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 96), children: [
          if (_isNew)
            TextField(
              controller: _key,
              decoration: const InputDecoration(labelText: 'Public key', hintText: 'npub1...'),
              onChanged: (_) => setState(() => _error = null),
            )
          else
            Row(children: [
              Expanded(child: SelectableText(c!.npub, style: const TextStyle(fontFamily: 'monospace', fontSize: 12))),
              IconButton(
                tooltip: 'Copy the key',
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () => Clipboard.setData(ClipboardData(text: c.npub)),
              ),
            ]),
          const SizedBox(height: 6),
          Row(children: [
            Text(
              npub == null ? 'Callsign: -' : 'Callsign: ${c?.callsign ?? Contact.defaultCallsign(npub)}',
              style: t.textTheme.titleSmall,
            ),
            const SizedBox(width: 12),
            if (c?.verified ?? false) ...[
              Icon(Icons.verified_outlined, size: 16, color: t.colorScheme.primary),
              const SizedBox(width: 4),
              Text('from their signed card', style: muted),
            ],
          ]),
          const SizedBox(height: 4),
          Text('The key is who they are: the callsign comes from it (XPRS), and cards signed with it are theirs.',
              style: muted),
          const SizedBox(height: 12),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
          TextField(controller: _note, minLines: 1, maxLines: 4, decoration: const InputDecoration(labelText: 'Note')),
          const SizedBox(height: 16),
          Text('Addresses and accounts', style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.primary)),
          FieldsEditor(_fields, key: _editor, onChanged: () => setState(() => _error = null)),
          if (_error != null) Text(_error!, style: TextStyle(color: t.colorScheme.error)),
        ]),
      ),
    );
  }
}
