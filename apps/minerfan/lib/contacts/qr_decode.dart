import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:qr/qr.dart';
import 'package:zxing2/qrcode.dart';

/// Pure-Dart QR reading (zxing2), for [Isolate.run]: nothing here touches
/// the UI or a platform plugin.
///
/// Call the `InBackground` forms from UI code: a closure handed to
/// [Isolate.run] carries its whole enclosing scope, and one that shares a
/// scope with a closure touching a widget or `this` cannot be sent.

Future<String?> decodeLuminanceInBackground(Uint8List y, int width, int height, int rowStride) =>
    Isolate.run(() => decodeLuminance(y, width, height, rowStride));

Future<String?> decodeImageFileInBackground(Uint8List bytes) => Isolate.run(() => decodeImageFile(bytes));

/// The text of a QR code in a camera frame's luminance plane (the Y plane of
/// YUV420), or null. [rowStride] is the plane's bytes per row.
String? decodeLuminance(Uint8List y, int width, int height, int rowStride) {
  Uint8List data = y;
  if (rowStride != width) {
    data = Uint8List(width * height);
    for (var r = 0; r < height; r++) {
      data.setRange(r * width, r * width + width, y, r * rowStride);
    }
  }
  return _decode(_Plane(Int8List.sublistView(data), width, height));
}

/// A packed 8-bit luminance plane (zxing2 does not export its YUV source).
class _Plane extends LuminanceSource {
  final Int8List _data;
  _Plane(this._data, int width, int height) : super(width, height);

  @override
  Int8List getRow(int y, Int8List? row) {
    final out = (row == null || row.length < width) ? Int8List(width) : row;
    out.setRange(0, width, _data, y * width);
    return out;
  }

  @override
  Int8List getMatrix() => _data;
}

/// The text of a QR code in an image file (PNG, JPEG, GIF, BMP or WebP), or
/// null.
String? decodeImageFile(Uint8List bytes) {
  img.Image? image;
  try {
    image = img.decodeImage(bytes); // throws on some damaged files
  } catch (_) {}
  if (image == null) return null;
  // Large photos decode as well and much faster at a phone screen's size.
  if (image.width > 1600 || image.height > 1600) {
    image = img.copyResize(image, width: image.width >= image.height ? 1600 : null, height: image.height > image.width ? 1600 : null);
  }
  final px = Int32List(image.width * image.height);
  var i = 0;
  for (final p in image) {
    px[i++] = (0xff << 24) | (p.r.toInt() << 16) | (p.g.toInt() << 8) | p.b.toInt();
  }
  return _decode(RGBLuminanceSource(image.width, image.height, px), pure: true);
}

String? _decode(LuminanceSource source, {bool pure = false}) {
  final hints = DecodeHints()..put(DecodeHintType.tryHarder);
  for (final binarizer in [HybridBinarizer(source), GlobalHistogramBinarizer(source)]) {
    try {
      return QRCodeReader().decode(BinaryBitmap(binarizer), hints: hints).text;
    } catch (_) {}
  }
  if (pure) {
    // A clean image of a code (a screenshot, a saved card) can still defeat
    // the finder-pattern search; read it as a pure barcode instead.
    try {
      return QRCodeReader().decode(BinaryBitmap(HybridBinarizer(source)), hints: DecodeHints()..put(DecodeHintType.pureBarcode)).text;
    } catch (_) {}
  }
  return null;
}

/// The QR code this app draws for [text] (error correction M, the version
/// and mask that package:qr picks, as qr_flutter does) as an 8-bit
/// luminance image, [scale] pixels per module and a 4-module quiet zone.
(Uint8List, int) qrLuminance(String text, {int scale = 4}) {
  final q = QrImage(QrCode.fromData(data: text, errorCorrectLevel: QrErrorCorrectLevel.M));
  final n = q.moduleCount, size = (n + 8) * scale;
  final y = Uint8List(size * size)..fillRange(0, size * size, 255);
  for (var r = 0; r < n; r++) {
    for (var c = 0; c < n; c++) {
      if (!q.isDark(r, c)) continue;
      for (var dy = 0; dy < scale; dy++) {
        final row = ((r + 4) * scale + dy) * size + (c + 4) * scale;
        y.fillRange(row, row + scale, 0);
      }
    }
  }
  return (y, size);
}

/// Whether the camera path ([decodeLuminance], no pure-barcode fallback)
/// reads the QR code of [text].
bool qrReadable(String text) {
  final (y, size) = qrLuminance(text);
  return decodeLuminance(y, size, size, size) == text;
}
