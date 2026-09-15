import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../contacts/contact.dart';
import 'contacts_page.dart';
import 'field_types.dart';

/// Lets the user pick a contact's address of [type] (a wallet's chain id)
/// for a payment. Returns the address, or null.
Future<String?> pickContactAddress(BuildContext context, AppController app, String type) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) {
      // Only addresses that are valid for the coin.
      final check = fieldType(type)?.check;
      final options = [
        for (final o in app.contacts.withField(type))
          if (check == null || check(o.$2.value) == null) o,
      ];
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
          child: ListView(shrinkWrap: true, children: [
            if (options.isEmpty)
              const Padding(padding: EdgeInsets.all(16), child: Text('No contact has an address for this coin yet.')),
            for (final (c, f) in options)
              ListTile(
                leading: CircleAvatar(child: Text(c.title.isEmpty ? '?' : c.title[0].toUpperCase())),
                title: Text(f.label.isEmpty ? c.title : '${c.title} (${f.label})'),
                subtitle: Text('${c.callsign}  ·  ${_short(f.value)}', style: const TextStyle(fontFamily: 'monospace')),
                onTap: () => Navigator.pop(context, f.value.trim()),
              ),
            ListTile(
              leading: const Icon(Icons.contacts_outlined),
              title: const Text('Contacts'),
              onTap: () {
                Navigator.pop(context);
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ContactsPage(app)));
              },
            ),
          ]),
        ),
      );
    },
  );
}

/// "To: name (callsign)" when [address] is a contact's address of [type].
String? contactHint(AppController app, String type, String address) {
  final Contact? c = app.contacts.whoHas(type, address);
  return c == null ? null : 'To: ${c.title} (${c.callsign})';
}

String _short(String a) => a.length > 24 ? '${a.substring(0, 10)}...${a.substring(a.length - 10)}' : a;
