import 'dart:io';

import 'package:application/src/offline_demo/data/local_media_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image_lib;
import 'package:path/path.dart' as p;

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory =
        await Directory.systemTemp.createTemp('tui_offline_media_');
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('imports image, stores relative paths, and generates thumbnail',
      () async {
    final root = Directory(p.join(temporaryDirectory.path, 'store'));
    final source = File(p.join(temporaryDirectory.path, '示例 图片.png'));
    final image = image_lib.Image(width: 640, height: 480);
    await source.writeAsBytes(image_lib.encodePng(image));

    final store = await LocalMediaStore.forRoot(root);
    final asset = await store.importFile(source);

    expect(p.isAbsolute(asset.relativePath), isFalse);
    expect(asset.thumbnailRelativePath, isNotNull);
    expect(asset.width, 640);
    expect(asset.height, 480);
    expect(await store.resolve(asset.relativePath).exists(), isTrue);

    final thumbnail = image_lib.decodeImage(
      await store.resolve(asset.thumbnailRelativePath!).readAsBytes(),
    );
    expect(thumbnail, isNotNull);
    expect(thumbnail!.width, 320);

    final retained = await store.cleanupUnreferenced({
      asset.relativePath,
      asset.thumbnailRelativePath!,
    });
    expect(retained, 0);

    final deleted = await store.cleanupUnreferenced({});
    expect(deleted, 2);
    expect(await store.resolve(asset.relativePath).exists(), isFalse);
  });

  test('rejects relative paths that escape the media root', () async {
    final store = await LocalMediaStore.forRoot(
      Directory(p.join(temporaryDirectory.path, 'store')),
    );
    expect(() => store.resolve('../outside.txt'), throwsArgumentError);
  });
}
