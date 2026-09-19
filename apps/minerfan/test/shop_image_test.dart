import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:minerfan/shop/shop_image.dart';

void main() {
  test('a big photo is shrunk, keeping its shape', () {
    final source = img.Image(width: 2000, height: 1200);
    img.fill(source, color: img.ColorRgb8(180, 90, 40));
    final small = shopImage(Uint8List.fromList(img.encodePng(source)));
    expect(small, isNotNull);
    final back = img.decodeImage(small!)!;
    expect(back.width, shopImageSide);
    expect(back.height, (1200 * shopImageSide / 2000).round());
    expect(small.length, lessThan(200 * 1024), reason: 'small enough to keep hundreds of them');
  });

  test('a picture already small is left at its size', () {
    final source = img.Image(width: 200, height: 200);
    final out = shopImage(Uint8List.fromList(img.encodePng(source)));
    final back = img.decodeImage(out!)!;
    expect(back.width, 200);
    expect(back.height, 200);
  });

  test('something that is not a picture gives nothing', () {
    expect(shopImage(Uint8List.fromList(List.filled(64, 7))), isNull);
    expect(shopImage(Uint8List(0)), isNull);
  });

  test('a stored picture is named for its item and its time', () async {
    final tmp = await Directory.systemTemp.createTemp('shopimg');
    addTearDown(() => tmp.delete(recursive: true));
    final name = await writeShopImage(tmp.path, 'i91a', Uint8List.fromList([1, 2, 3]));
    expect(name, startsWith('i91a-'));
    expect(name, endsWith('.jpg'));
    expect(await File('${tmp.path}/$name').readAsBytes(), [1, 2, 3]);
    expect(await Directory(tmp.path).list().length, 1, reason: 'the temporary file is gone');
  });
}
