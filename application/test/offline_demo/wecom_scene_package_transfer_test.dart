import 'dart:io';

import 'package:application/src/offline_demo/data/wecom_restricted_export_service.dart';
import 'package:application/src/offline_demo/data/wecom_scene_package.dart';
import 'package:application/src/offline_demo/data/wecom_scene_package_transfer.dart';
import 'package:application/src/offline_demo/data/wecom_scene_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory scratch;
  late Directory base;
  late _Scenes scenes;
  late _Files files;
  File? selected;
  Future<void> Function()? onPick;
  var picks = 0;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('tui_scene_transfer_');
    scratch = Directory(p.join(root.path, 'scratch'));
    base = await Directory(p.join(root.path, 'base')).create();
    scenes = _Scenes();
    files = _Files(File(p.join(root.path, 'saved.json')));
    selected = null;
    onPick = null;
    picks = 0;
  });
  tearDown(() => root.delete(recursive: true));

  WeComScenePackageTransfer transfer() => WeComScenePackageTransfer(
      scenes: scenes,
      baseDirectory: base,
      overlayPath: p.join(root.path, 'overlay.db'),
      scratchRoot: scratch,
      fileAccess: files,
      pickImport: () async {
        picks++;
        await onPick?.call();
        return selected;
      });

  test('saves a JSON scene file and imports it without rewriting that file',
      () async {
    expect(await transfer().export(), isTrue);
    expect(await files.saved.readAsString(), scenes.text);
    expect(await scratch.list().toList(), isEmpty);
    selected = files.saved;
    final imported = await transfer().import();
    expect(imported!.id, 'imported');
    expect(scenes.imported, scenes.text);
    expect(await files.saved.readAsString(), scenes.text);
  });

  test('cancelled export and import leave no private or published files',
      () async {
    files.cancel = true;
    expect(await transfer().export(), isFalse);
    expect(await transfer().import(), isNull);
    expect(await scratch.list().toList(), isEmpty);
    expect(await files.saved.exists(), isFalse);
    expect(files.writes, 0);
    expect(files.discards, 0);
    expect(scenes.imported, isNull);
  });

  test('expiry in the save picker discards its empty document and staging',
      () async {
    files.onChoose = () => scenes.allowed = false;
    await expectLater(transfer().export(), throwsStateError);
    expect(files.writes, 0);
    expect(files.discards, 1);
    expect(await scratch.list().toList(), isEmpty);
  });

  test('failed save removes its partial output and private staging', () async {
    files.fail = true;
    await expectLater(transfer().export(), throwsA(isA<FileSystemException>()));
    expect(files.discards, 1);
    expect(await files.saved.exists(), isFalse);
    expect(await scratch.list().toList(), isEmpty);
  });

  test('rejects base directory, overlay and non-JSON save destinations',
      () async {
    for (final path in [
      p.join(base.path, 'copy.json'),
      p.join(root.path, 'overlay.db'),
      p.join(root.path, 'copy.zip')
    ]) {
      files.destination = path;
      await expectLater(transfer().export(),
          throwsA(anyOf(isA<FormatException>(), isA<Exception>())));
    }
    expect(files.writes, 0);
    expect(await base.list().toList(), isEmpty);
    expect(await scratch.list().toList(), isEmpty);
  });

  test('rejects oversized and invalid UTF-8 imports before inserting logs',
      () async {
    selected = File(p.join(root.path, 'bad.json'));
    await selected!.writeAsBytes([0xff]);
    await expectLater(
        transfer().import(), throwsA(isA<WeComScenePackageException>()));
    final handle = await selected!.open(mode: FileMode.write);
    await handle.truncate(WeComScenePackage.maxBytes + 1);
    await handle.close();
    await expectLater(
        transfer().import(), throwsA(isA<WeComScenePackageException>()));
    expect(scenes.imported, isNull);
  });

  test('denies an import when management expires in the open picker', () async {
    selected =
        await File(p.join(root.path, 'scene.json')).writeAsString(scenes.text);
    onPick = () async => scenes.allowed = false;
    await expectLater(transfer().import(), throwsStateError);
    expect(scenes.imported, isNull);
  });

  test('ordinary mode never opens either picker or creates staging', () async {
    scenes.allowed = false;
    await expectLater(transfer().export(), throwsStateError);
    await expectLater(transfer().import(), throwsStateError);
    expect(picks, 0);
    expect(files.choices, 0);
    expect(await scratch.exists(), isFalse);
  });
}

class _Scenes implements WeComSceneService {
  bool allowed = true;
  final text = '{"format":"tui-overlay-scene"}';
  String? imported;
  @override
  String get datasetId => 'a' * 64;
  @override
  Future<void> validateAccess() async {
    if (!allowed) throw StateError('Management expired');
  }

  @override
  Future<String> exportPackage() async {
    await validateAccess();
    return text;
  }

  @override
  Future<WeComOverlayScene> importPackage(String text) async {
    await validateAccess();
    imported = text;
    return WeComOverlayScene(
        id: 'imported',
        name: 'Imported',
        datasetId: datasetId,
        isSnapshot: false,
        createdAt: DateTime.utc(2026));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Files implements WeComExportFileAccess {
  _Files(this.saved);
  final File saved;
  String? destination;
  bool cancel = false;
  bool fail = false;
  int choices = 0;
  int writes = 0;
  int discards = 0;
  void Function()? onChoose;
  @override
  Future<String?> choose(String name) async {
    expect(name, 'tui-scene-${'a' * 8}.json');
    choices++;
    onChoose?.call();
    return cancel ? null : destination ?? saved.path;
  }

  @override
  Future<void> write(File archive, String destination) async {
    writes++;
    await archive.copy(destination);
    if (fail) throw const FileSystemException('Test write failure');
  }

  @override
  Future<void> discard(String destination) async {
    discards++;
    if (await saved.exists()) await saved.delete();
  }
}
