import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../contacts/qr_decode.dart';

/// Whether this device can read a code with a camera. The camera plugin
/// is phones only, so a desktop pastes the text or opens an image.
bool get hasCamera => Platform.isAndroid || Platform.isIOS;

/// Reads a QR code with the camera (phones). Frames go to a pure-Dart
/// decoder on a short-lived isolate a few times a second; the page closes
/// with the first text that [accept] takes.
class ScanPage extends StatefulWidget {
  /// What the page returns when the user asks to paste instead.
  static const pasteInstead = '\u0000paste';

  final bool Function(String text) accept;
  final String title;

  /// The line under the picture, saying what to point at.
  final String hint;
  const ScanPage({
    required this.accept,
    this.title = 'Read a QR code',
    this.hint = 'Point the camera at the QR code of a contact card.',
    super.key,
  });

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  CameraController? _cam;
  String? _error;
  bool _busy = false;
  bool _done = false;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) return setState(() => _error = 'This device has no camera.');
      final cam = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cams.first);
      final c = CameraController(cam, ResolutionPreset.high, enableAudio: false, imageFormatGroup: ImageFormatGroup.yuv420);
      await c.initialize();
      if (!mounted) return c.dispose();
      await c.startImageStream(_frame);
      setState(() => _cam = c);
    } on CameraException catch (e) {
      if (mounted) {
        setState(() => _error = e.code.contains('Denied') || e.code.contains('denied')
            ? 'The app may not use the camera. Allow it in the system settings, or paste the card instead.'
            : 'The camera did not start: ${e.description ?? e.code}');
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'The camera did not start: $e');
    }
  }

  void _frame(CameraImage image) {
    final now = DateTime.now();
    if (_busy || _done || now.difference(_last) < const Duration(milliseconds: 250)) return;
    _last = now;
    _busy = true;
    final p = image.planes.first;
    final y = Uint8List.fromList(p.bytes);
    final w = image.width, h = image.height, stride = p.bytesPerRow;
    decodeLuminanceInBackground(y, w, h, stride).then((text) {
      _busy = false;
      if (text == null || _done || !mounted || !widget.accept(text)) return;
      _done = true;
      unawaited(_cam?.stopImageStream());
      Navigator.pop(context, text);
    }, onError: (Object _) => _busy = false);
  }

  @override
  void dispose() {
    final c = _cam;
    _cam = null;
    if (c != null) unawaited(c.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _cam;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title), actions: [
        TextButton(onPressed: () => Navigator.pop(context, ScanPage.pasteInstead), child: const Text('Paste instead')),
      ]),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: Center(
              child: _error != null
                  ? Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center))
                  : c == null
                      ? const CircularProgressIndicator()
                      : AspectRatio(aspectRatio: 1 / c.value.aspectRatio, child: CameraPreview(c)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(widget.hint, textAlign: TextAlign.center),
          ),
        ]),
      ),
    );
  }
}
