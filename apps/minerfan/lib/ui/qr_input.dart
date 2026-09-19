import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../contacts/qr_decode.dart';
import 'scan_page.dart';

/// Reads a QR code the way this device can: the camera on a phone, and a
/// paste or an image file elsewhere (and as the way out when the camera
/// will not play). Returns the text, or null when nothing was read.
///
/// [accept] says whether some text is the kind of code being asked for.
Future<String?> readQrText(
  BuildContext context, {
  required bool Function(String text) accept,
  required String title,
  required String hint,
}) async {
  String? text;
  if (hasCamera) {
    text = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => ScanPage(accept: accept, title: title, hint: hint)),
    );
    if (text == ScanPage.pasteInstead && context.mounted) {
      text = await pasteOrImage(context, accept: accept, title: title);
    }
  } else {
    text = await pasteOrImage(context, accept: accept, title: title);
  }
  if (text == null) return null;
  final t = text.trim();
  return t.isEmpty ? null : t;
}

/// Asks for the text of a code: pasted, or read out of an image file.
Future<String?> pasteOrImage(
  BuildContext context, {
  required bool Function(String text) accept,
  required String title,
  bool cameraFirst = false,
}) async {
  final field = TextEditingController();
  final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
  if (clip.isNotEmpty && accept(clip)) field.text = clip;
  if (!context.mounted) {
    field.dispose();
    return null;
  }
  String? error;
  final r = await showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialog) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 520,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Paste the code, or open an image of it.'),
            TextField(
              controller: field,
              minLines: 2,
              maxLines: 5,
              decoration: InputDecoration(errorText: error),
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
