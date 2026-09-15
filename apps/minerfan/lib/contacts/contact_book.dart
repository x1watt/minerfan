import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'contact.dart';

/// The address book (`contacts.json`): the contacts and this device's own
/// card (a name and the fields to share; the key is the XPRS station key).
///
/// ```json
/// {"version": 1, "me": {"name": "...", "fields": [...]}, "contacts": [{...}]}
/// ```
///
/// Every key this version does not know, at any level, is kept on save.
class ContactBook extends ChangeNotifier {
  final String dataDir;
  final List<Contact> contacts = [];
  String myName = '';
  final List<ContactField> myFields = [];

  /// Whether the own card was filled in by the app (the first time it is
  /// shown) or by the user.
  bool myCardStarted = false;
  final Map<String, Object?> _extra = {};
  final Map<String, Object?> _meExtra = {};
  Future<void> _writing = Future.value();

  ContactBook(this.dataDir);

  File get _file => File('$dataDir/contacts.json');

  Future<void> load() async {
    try {
      if (!await _file.exists()) return;
      final m = jsonDecode(await _file.readAsString()) as Map<String, Object?>;
      _extra
        ..clear()
        ..addAll({for (final e in m.entries) if (!{'version', 'me', 'contacts'}.contains(e.key)) e.key: e.value});
      final me = (m['me'] as Map?)?.cast<String, Object?>() ?? const {};
      myName = '${me['name'] ?? ''}';
      myCardStarted = me['started'] == true;
      myFields
        ..clear()
        ..addAll([
          for (final f in (me['fields'] as List?) ?? const [])
            if (f is Map) ContactField.fromJson(f.cast<String, Object?>()),
        ]);
      _meExtra
        ..clear()
        ..addAll({for (final e in me.entries) if (!{'name', 'fields', 'started'}.contains(e.key)) e.key: e.value});
      contacts
        ..clear()
        ..addAll([
          for (final c in (m['contacts'] as List?) ?? const [])
            if (c is Map && Contact.keyHex('${c['npub']}') != null) Contact.fromJson(c.cast<String, Object?>()),
        ]);
      _sort();
      notifyListeners();
    } catch (e) {
      debugPrint('contacts: $e');
    }
  }

  Map<String, Object?> toJson() => {
        ..._extra,
        'version': 1,
        'me': {
          ..._meExtra,
          if (myName.isNotEmpty) 'name': myName,
          if (myCardStarted) 'started': true,
          'fields': [for (final f in myFields) f.toJson()],
        },
        'contacts': [for (final c in contacts) c.toJson()],
      };

  /// Saves (in order, off the frame: a temporary file, then a rename).
  Future<void> save() {
    notifyListeners();
    final text = const JsonEncoder.withIndent(' ').convert(toJson());
    return _writing = _writing.then((_) async {
      try {
        await Directory(dataDir).create(recursive: true);
        final tmp = File('${_file.path}.tmp');
        await tmp.writeAsString(text, flush: true);
        await tmp.rename(_file.path);
      } catch (e) {
        debugPrint('contacts: $e');
      }
    });
  }

  void _sort() => contacts.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

  Contact? byNpub(String npub) {
    for (final c in contacts) {
      if (c.npub == npub) return c;
    }
    return null;
  }

  /// Adds [c], or replaces the contact with the same key.
  Future<void> put(Contact c) {
    c.updated = DateTime.now();
    contacts.removeWhere((x) => x.npub == c.npub && !identical(x, c));
    if (!contacts.contains(c)) contacts.add(c);
    _sort();
    return save();
  }

  Future<void> remove(Contact c) {
    contacts.remove(c);
    return save();
  }

  /// Contacts that have an address of [type] (a wallet's chain id), with
  /// each such field.
  List<(Contact, ContactField)> withField(String type) => [
        for (final c in contacts)
          for (final f in c.fieldsOf(type)) (c, f),
      ];

  /// The contact whose [type] field is [value], or null.
  Contact? whoHas(String type, String value) {
    final v = value.trim();
    if (v.isEmpty) return null;
    for (final c in contacts) {
      if (c.fieldsOf(type).any((f) => f.value.trim() == v)) return c;
    }
    return null;
  }
}
