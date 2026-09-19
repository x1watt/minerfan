// Pictures of the things a shop sells.
//
// A photo from a phone is several megabytes and far bigger than any
// screen needs, so it is decoded, shrunk and written as a small JPEG. All
// of that is pure Dart on a short-lived isolate: nothing here touches the
// UI or a plugin, and the top-level functions keep the isolate's closure
// down to their arguments (the same rule as contacts/qr_decode.dart).

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// The longest side a stored picture keeps.
const shopImageSide = 640;

/// [bytes] as a small JPEG, or null when it is not an image this app can
/// read. Runs off the caller's isolate.
Future<Uint8List?> shopImageInBackground(Uint8List bytes, {int max = shopImageSide}) =>
    Isolate.run(() => shopImage(bytes, max: max));

/// [bytes] decoded, shrunk to [max] on its longest side and encoded as a
/// JPEG, or null when it cannot be read. Heavy: call it off the UI
/// isolate.
Uint8List? shopImage(Uint8List bytes, {int max = shopImageSide}) {
  img.Image? image;
  try {
    image = img.decodeImage(bytes);
  } catch (_) {
    return null;
  }
  if (image == null) return null;
  final side = image.width > image.height ? image.width : image.height;
  if (side > max) {
    final scale = max / side;
    image = img.copyResize(
      image,
      width: (image.width * scale).round().clamp(1, max),
      height: (image.height * scale).round().clamp(1, max),
      interpolation: img.Interpolation.average,
    );
  }
  return img.encodeJpg(image, quality: 80);
}

/// Writes [bytes] (already shrunk) as the picture of [itemId] in [dir] and
/// returns its file name. The name carries the time, so replacing a
/// picture never shows the old one from Flutter's image cache.
Future<String> writeShopImage(String dir, String itemId, Uint8List bytes) async {
  await Directory(dir).create(recursive: true);
  final name = '$itemId-${DateTime.now().millisecondsSinceEpoch ~/ 1000}.jpg';
  final tmp = File('$dir/$name.tmp');
  await tmp.writeAsBytes(bytes, flush: true);
  await tmp.rename('$dir/$name');
  return name;
}
