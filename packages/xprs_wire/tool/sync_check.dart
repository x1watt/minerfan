// Reports vendored files that drifted from their xprs sources.
//
//   dart run tool/sync_check.dart [path to the xprs checkout]
//
// Each vendored file starts with a short header and a blank line; the rest must equal the
// source with only the documented import rewrites (and, in xprs_sig.dart,
// the profile hook). Exit 1 on drift.
import 'dart:io';

const files = {
  'xprs_crypto.dart': 'reticulum-dart/lib/src/util/xprs_crypto.dart',
  'nostr_crypto.dart': 'reticulum-dart/lib/src/util/nostr_crypto.dart',
  'xprs_packet.dart': 'app/lib/services/xprs/xprs_packet.dart',
  'xprs_id.dart': 'app/lib/services/xprs/xprs_id.dart',
  'xprs_body.dart': 'app/lib/services/xprs/xprs_body.dart',
  'xprs_parts.dart': 'app/lib/services/xprs/xprs_parts.dart',
  'xprs_sig.dart': 'app/lib/services/xprs/xprs_sig.dart',
  'xprs_vocab.dart': 'app/lib/services/xprs/xprs_vocab.dart',
};

String normalize(String name, String src) {
  var s = src
      .replaceAll("'../../util/nostr_crypto.dart'", "'nostr_crypto.dart'")
      .replaceAll("'../../util/xprs_crypto.dart'", "'xprs_crypto.dart'");
  if (name == 'xprs_sig.dart') {
    s = s
        .replaceAll("import '../../profile/profile_service.dart';\n", '')
        .replaceAll("ProfileService.instance.activeProfile?.nsec ?? ''", "xprsProfileNsec() ?? ''");
  }
  return s;
}

String body(String vendored, String name) {
  final lines = vendored.split('\n');
  var s = lines.skip(lines.indexOf('') + 1).join('\n'); // the header ends at a blank line
  if (name == 'xprs_sig.dart') {
    // The hook's own declaration is the one addition.
    s = s.replaceAll(RegExp(r'/// The host.s nsec.*?\n\n', dotAll: true), '');
  }
  return s;
}

void main(List<String> args) {
  final xprs = args.isNotEmpty ? args.first : '${Platform.environment['HOME']}/code/xprs';
  final here = File.fromUri(Platform.script).parent.parent.path;
  var drift = 0;
  files.forEach((name, source) {
    final src = File('$xprs/$source');
    if (!src.existsSync()) {
      print('  ?    $name: no $source under $xprs');
      drift++;
      return;
    }
    final same = body(File('$here/lib/src/$name').readAsStringSync(), name) ==
        normalize(name, src.readAsStringSync());
    print('  ${same ? "ok  " : "DIFF"} $name');
    if (!same) drift++;
  });
  exit(drift == 0 ? 0 : 1);
}
