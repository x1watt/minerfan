import 'package:hex/hex.dart';
import 'package:xprs_wire/xprs_wire.dart';

/// One way to reach a contact or pay them: a type (`monero`, `i2p`,
/// `website`, `irc` or anything else) and a value, with an optional label
/// ("savings", "work"). Types are free text so any service fits; the app
/// knows some of them (see `field_types.dart`) and shows the rest as they
/// are.
class ContactField {
  String type;
  String value;
  String label;

  /// Keys this version does not know, kept as they were.
  final Map<String, Object?> extra;

  ContactField(String type, this.value, {this.label = '', Map<String, Object?>? extra})
      : type = normalizeType(type),
        extra = extra ?? {};

  static String normalizeType(String t) => t.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '-');

  factory ContactField.fromJson(Map<String, Object?> m) => ContactField(
        '${m['type'] ?? ''}',
        '${m['value'] ?? ''}',
        label: '${m['label'] ?? ''}',
        extra: {for (final e in m.entries) if (!_known.contains(e.key)) e.key: e.value},
      );

  static const _known = {'type', 'value', 'label'};

  Map<String, Object?> toJson() => {
        ...extra,
        'type': type,
        'value': value,
        if (label.isNotEmpty) 'label': label,
      };

  bool sameAs(ContactField o) => o.type == type && o.value.trim() == value.trim();
}

/// A person or station in the address book. Their identity is a NOSTR key
/// (npub) and the XPRS callsign derived from it (docs XPRS.md section 3);
/// everything else is a name, a note and a list of [ContactField]s.
///
/// Stored as JSON with every key this version does not understand kept
/// (`extra`), so a newer app's data survives an older app's save.
class Contact {
  /// The contact's public key, `npub1...`: the identity, never edited.
  final String npub;

  /// `X1` + 2 to 5 characters of the npub (section 3); 4 unless a signed
  /// card said otherwise.
  String callsign;
  String name;
  String note;
  final List<ContactField> fields;

  /// Whether the fields came from a card signed with this key (the person
  /// holding the key published them), rather than typed in here.
  bool verified;
  DateTime added;
  DateTime updated;
  final Map<String, Object?> extra;

  Contact({
    required this.npub,
    String? callsign,
    this.name = '',
    this.note = '',
    List<ContactField>? fields,
    this.verified = false,
    DateTime? added,
    DateTime? updated,
    Map<String, Object?>? extra,
  })  : callsign = callsign ?? defaultCallsign(npub),
        fields = fields ?? [],
        added = added ?? DateTime.now(),
        updated = updated ?? DateTime.now(),
        extra = extra ?? {};

  /// The x-only public key as hex, or null when [npub] is not one.
  static String? keyHex(String npub) {
    try {
      final hex = NostrCrypto.decodeNpub(npub.trim());
      return hex.length == 64 ? hex : null;
    } catch (_) {
      return null;
    }
  }

  /// An npub from what the user typed: an `npub1...` or 64 hex characters.
  static String? parseKey(String text) {
    final t = text.trim();
    if (t.startsWith('npub1')) return keyHex(t) == null ? null : t;
    if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(t)) {
      try {
        HEX.decode(t);
        return NostrCrypto.encodeNpub(t.toLowerCase());
      } catch (_) {}
    }
    return null;
  }

  static String defaultCallsign(String npub) {
    final hex = keyHex(npub);
    return hex == null ? '' : 'X1${NostrCrypto.deriveCallsign(hex)}';
  }

  /// [callsign] when it derives from [npub] (section 3), else the default.
  static String checkedCallsign(String npub, String? callsign) {
    final hex = keyHex(npub);
    if (hex != null && callsign != null && NostrCrypto.callsignMatchesKey(callsign, hex)) {
      return callsign.trim().toUpperCase();
    }
    return defaultCallsign(npub);
  }

  /// What to show: the name, else the callsign.
  String get title => name.trim().isNotEmpty ? name.trim() : callsign;

  List<ContactField> fieldsOf(String type) => [for (final f in fields) if (f.type == type) f];

  factory Contact.fromJson(Map<String, Object?> m) {
    final npub = '${m['npub'] ?? ''}';
    return Contact(
      npub: npub,
      callsign: checkedCallsign(npub, m['callsign'] as String?),
      name: '${m['name'] ?? ''}',
      note: '${m['note'] ?? ''}',
      fields: [
        for (final f in (m['fields'] as List?) ?? const [])
          if (f is Map) ContactField.fromJson(f.cast<String, Object?>()),
      ],
      verified: m['verified'] == true,
      added: DateTime.tryParse('${m['added']}'),
      updated: DateTime.tryParse('${m['updated']}'),
      extra: {for (final e in m.entries) if (!_known.contains(e.key)) e.key: e.value},
    );
  }

  static const _known = {'npub', 'callsign', 'name', 'note', 'fields', 'verified', 'added', 'updated'};

  Map<String, Object?> toJson() => {
        ...extra,
        'npub': npub,
        'callsign': callsign,
        if (name.isNotEmpty) 'name': name,
        if (note.isNotEmpty) 'note': note,
        'fields': [for (final f in fields) f.toJson()],
        if (verified) 'verified': true,
        'added': added.toUtc().toIso8601String(),
        'updated': updated.toUtc().toIso8601String(),
      };
}
