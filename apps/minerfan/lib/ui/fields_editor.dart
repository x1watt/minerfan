import 'package:flutter/material.dart';

import '../contacts/contact.dart';
import 'field_types.dart';

/// Edits a list of contact fields in place: each has a type (one the app
/// knows or any name), a value and an optional label. [onChanged] runs
/// after every edit.
class FieldsEditor extends StatefulWidget {
  final List<ContactField> fields;
  final VoidCallback onChanged;
  const FieldsEditor(this.fields, {required this.onChanged, super.key});

  @override
  State<FieldsEditor> createState() => FieldsEditorState();
}

class FieldsEditorState extends State<FieldsEditor> {
  final _value = <ContactField, TextEditingController>{};
  final _label = <ContactField, TextEditingController>{};

  TextEditingController _c(Map<ContactField, TextEditingController> m, ContactField f, String text) =>
      m.putIfAbsent(f, () => TextEditingController(text: text));

  @override
  void dispose() {
    for (final c in [..._value.values, ..._label.values]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The first field whose value its type rejects, as a message, or null.
  String? firstError() {
    for (final f in widget.fields) {
      final err = f.value.trim().isEmpty ? null : fieldType(f.type)?.check?.call(f.value);
      if (err != null) return '${fieldLabel(f.type)}: $err';
    }
    return null;
  }

  void add(String type, [String value = '']) {
    setState(() => widget.fields.add(ContactField(type, value)));
    widget.onChanged();
  }

  Future<void> _pickType(BuildContext context, {ContactField? change}) async {
    final type = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          for (final t in fieldTypes)
            ListTile(leading: Icon(t.icon), title: Text(t.label), onTap: () => Navigator.pop(context, t.id)),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Something else...'),
            subtitle: const Text('Any service: a game, a forum, a radio callsign'),
            onTap: () async {
              final name = TextEditingController();
              final t = await showDialog<String>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('What is it?'),
                  content: TextField(
                    controller: name,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Name of the service', hintText: 'for example Mastodon'),
                    onSubmitted: (v) => Navigator.pop(context, v),
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(context, name.text), child: const Text('Add')),
                  ],
                ),
              );
              name.dispose();
              if (context.mounted) Navigator.pop(context, t == null || t.trim().isEmpty ? null : t);
            },
          ),
        ]),
      ),
    );
    if (type == null) return;
    if (change != null) {
      setState(() => change.type = ContactField.normalizeType(type));
      widget.onChanged();
    } else {
      add(type);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final f in widget.fields)
        Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(fieldIcon(f.type), size: 18, color: t.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: TextButton(
                    style: TextButton.styleFrom(alignment: Alignment.centerLeft, padding: EdgeInsets.zero),
                    onPressed: () => _pickType(context, change: f),
                    child: Text(fieldLabel(f.type)),
                  ),
                ),
                IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () {
                    setState(() {
                      widget.fields.remove(f);
                      _value.remove(f)?.dispose();
                      _label.remove(f)?.dispose();
                    });
                    widget.onChanged();
                  },
                ),
              ]),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: TextField(
                  controller: _c(_value, f, f.value),
                  minLines: 1,
                  maxLines: 3,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: fieldType(f.type)?.hint ?? 'Value',
                    errorText: f.value.trim().isEmpty ? null : fieldType(f.type)?.check?.call(f.value),
                  ),
                  onChanged: (v) {
                    setState(() => f.value = v);
                    widget.onChanged();
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: TextField(
                  controller: _c(_label, f, f.label),
                  decoration: const InputDecoration(isDense: true, hintText: 'Label (optional), for example "work"'),
                  style: t.textTheme.bodySmall,
                  onChanged: (v) {
                    f.label = v;
                    widget.onChanged();
                  },
                ),
              ),
            ]),
          ),
        ),
      TextButton.icon(
        onPressed: () => _pickType(context),
        icon: const Icon(Icons.add),
        label: const Text('Add an address, wallet or account'),
      ),
    ]);
  }
}
