import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

/// Takes one photo with the camera and pops with its bytes (phones; the
/// camera plugin has no desktop side, so elsewhere the picture comes from
/// a file). Built like ScanPage, down to the wording when the camera is
/// not allowed.
class CameraShotPage extends StatefulWidget {
  final String title;
  const CameraShotPage({this.title = 'Take a photo', super.key});

  @override
  State<CameraShotPage> createState() => _CameraShotPageState();
}

class _CameraShotPageState extends State<CameraShotPage> {
  CameraController? _cam;
  String? _error;
  bool _busy = false;

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
      final c = CameraController(cam, ResolutionPreset.high, enableAudio: false);
      await c.initialize();
      if (!mounted) return c.dispose();
      setState(() => _cam = c);
    } on CameraException catch (e) {
      if (mounted) {
        setState(() => _error = e.code.contains('Denied') || e.code.contains('denied')
            ? 'The app may not use the camera. Allow it in the system settings, or choose a picture from a file.'
            : 'The camera did not start: ${e.description ?? e.code}');
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'The camera did not start: $e');
    }
  }

  Future<void> _shoot() async {
    final c = _cam;
    if (c == null || _busy) return;
    setState(() => _busy = true);
    try {
      final shot = await c.takePicture();
      final bytes = await shot.readAsBytes();
      if (mounted) Navigator.pop(context, Uint8List.fromList(bytes));
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'The photo did not work: $e';
        });
      }
    }
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
      appBar: AppBar(title: Text(widget.title)),
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
            child: FilledButton.icon(
              onPressed: c == null || _busy ? null : _shoot,
              icon: const Icon(Icons.camera_alt_outlined),
              label: Text(_busy ? 'Saving' : 'Take the photo'),
            ),
          ),
        ]),
      ),
    );
  }
}
