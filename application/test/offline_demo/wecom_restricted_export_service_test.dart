import 'dart:io';

import 'package:application/src/offline_demo/data/wecom_active_dataset_runtime.dart';
import 'package:application/src/offline_demo/data/wecom_database_package.dart';
import 'package:application/src/offline_demo/data/wecom_database_package_exporter.dart';
import 'package:application/src/offline_demo/data/wecom_identity_repository.dart';
import 'package:application/src/offline_demo/data/wecom_local_simulation_repository.dart';
import 'package:application/src/offline_demo/data/wecom_message_overlay_repository.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_command_service.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_database.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_schema.dart';
import 'package:application/src/offline_demo/data/wecom_restricted_export_service.dart';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'wecom_identity_test_fixture.dart';

const _scope = WeComIdentityScope(corporationId: 100, userId: 1);

void main() {
  late Directory root;
  late Directory scratch;
  late WeComOverlayDatabase overlay;
  late WeComImportedPackage base;
  late WeComPackageContract contract;
  late _FileAccess files;
  late bool admin;
  late DatabaseFactory exportFactory;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('tui_export_service_');
    scratch = Directory(p.join(root.path, 'scratch'));
    final source = await Directory(p.join(root.path, 'source')).create();
    await createIdentityDatabases(source, contactName: 'Base');
    contract = WeComPackageContract(
      formatVersion: 1,
      scope: 'restricted export test',
      databases: identityDatabaseContracts(),
    );
    final importer = WeComDatabasePackageImporter(
        contract: contract, databaseFactory: databaseFactoryFfi);
    final imports = Directory(p.join(root.path, 'imports'));
    base = await importer.importPackage(
        sourceDirectory: source, destinationRoot: imports);
    overlay = await WeComOverlayDatabase.open(
        factory: databaseFactoryFfi,
        databasePath: p.join(root.path, 'overlay.db'));
    await WeComActiveDatasetResolver(
      destinationRoot: imports,
      packageImporter: importer,
      databaseFactory: databaseFactoryFfi,
      overlayDatabase: overlay,
    ).ensureInitialDataset(base.datasetId);
    files = _FileAccess(File(p.join(root.path, 'saved.zip')));
    admin = true;
    exportFactory = databaseFactoryFfi;
  });
  tearDown(() async {
    await overlay.close();
    await root.delete(recursive: true);
  });

  WeComRestrictedExportService service() => WeComRestrictedExportService(
        exporter: WeComDatabasePackageExporter(
            contract: contract, databaseFactory: exportFactory),
        basePackage: base,
        overlayDatabase: overlay,
        identityScope: _scope,
        scratchRoot: scratch,
        canExport: () => admin,
        fileAccess: files,
      );

  Future<void> edit(String name,
          {String scene = 'default', WeComIdentityScope scope = _scope}) =>
      WeComOverlayCommandService(
              overlayDatabase: overlay.forScene(scene),
              contract: contract,
              identityScope: scope)
          .upsert(
              datasetId: base.datasetId,
              databaseName: 'user.db',
              tableName: 'user_table',
              rowKey: const {'id': 1},
              values: {'name': name});

  test('saves only the selected scene and identity as a reimportable ZIP',
      () async {
    final original =
        sha256.convert(await base.databaseFile('user.db').readAsBytes());
    await edit('Selected');
    await edit('Other scene', scene: 'other');
    await edit('Other identity',
        scope: const WeComIdentityScope(corporationId: 200, userId: 2));
    await WeComMessageOverlayRepository(
            overlayDatabase: overlay, identityScope: _scope)
        .append(
            conversationId: 'R:1',
            targetKey: 'overlay:1',
            action: 'add',
            state: WeComMessageOverlayState.text(
                senderId: '2', text: 'Local only', sentAt: DateTime.utc(2026)));
    await WeComLocalSimulationRepository(
            overlayDatabase: overlay, identityScope: _scope)
        .enqueueTextExchange(
            conversationId: 'R:1', senderProfileId: '1', text: 'Simulated');

    expect(await service().export(), 1);
    final zip =
        ZipDecoder().decodeBytes(await files.saved.readAsBytes(), verify: true);
    expect(zip.files.map((entry) => entry.name).toList()..sort(),
        ['Data/company.db', 'Data/user.db']);
    final extracted = Directory(p.join(root.path, 'extracted'));
    for (final entry in zip.files) {
      final file = File(p.join(extracted.path, entry.name));
      await file.create(recursive: true);
      await file.writeAsBytes(entry.content);
    }
    final imported = await WeComDatabasePackageImporter(
            contract: contract, databaseFactory: databaseFactoryFfi)
        .importPackage(
            sourceDirectory: Directory(p.join(extracted.path, 'Data')),
            destinationRoot: Directory(p.join(root.path, 'roundtrip')));
    final db = await databaseFactoryFfi.openDatabase(
        imported.databaseFile('user.db').path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false));
    try {
      expect((await db.query('user_table')).single['name'], 'Selected');
    } finally {
      await db.close();
    }
    expect(sha256.convert(await base.databaseFile('user.db').readAsBytes()),
        original);
    expect(await scratch.list().toList(), isEmpty);
    expect(await files.staged!.exists(), isFalse);
  });

  test('Android metadata is removed from copies without changing the base',
      () async {
    final before =
        sha256.convert(await base.databaseFile('user.db').readAsBytes());
    await edit('Android export');
    exportFactory = _AndroidMetadataFactory();
    expect(await service().export(), 1);
    final zip = ZipDecoder().decodeBytes(await files.saved.readAsBytes());
    final exported = File(p.join(root.path, 'exported_user.db'));
    await exported.writeAsBytes(
        zip.files.singleWhere((entry) => entry.name == 'Data/user.db').content);
    final db = await databaseFactoryFfi.openDatabase(exported.path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false));
    try {
      expect((await db.query('user_table')).single['name'], 'Android export');
      expect(
          await db.rawQuery(
              "SELECT name FROM sqlite_master WHERE name='android_metadata'"),
          isEmpty);
    } finally {
      await db.close();
    }
    expect(sha256.convert(await base.databaseFile('user.db').readAsBytes()),
        before);
  });

  test('cancelled picker publishes nothing and removes the private copy',
      () async {
    files.cancel = true;
    expect(await service().export(), isNull);
    expect(files.writes, 0);
    expect(files.discards, 0);
    expect(await scratch.list().toList(), isEmpty);
  });

  test('denies ordinary mode before creating files or opening the picker',
      () async {
    admin = false;
    await expectLater(service().export(), throwsStateError);
    expect(files.choices, 0);
    expect(await scratch.exists(), isFalse);
  });

  test(
      'expiry during the picker discards the empty destination without writing',
      () async {
    files.onChoose = () async => admin = false;
    await expectLater(service().export(), throwsStateError);
    expect(files.writes, 0);
    expect(files.discards, 1);
    expect(await scratch.list().toList(), isEmpty);
  });

  test('a scene switch during the picker invalidates the prepared export',
      () async {
    files.onChoose = () async {
      await overlay.connection
          .insert(WeComOverlaySchema.datasetActivationsTable, {
        'dataset_id': base.datasetId,
        'scene_id': 'other',
        'current_corp_id': 100,
        'current_user_id': 1,
        'created_at_micros': 1,
      });
    };
    await expectLater(service().export(), throwsStateError);
    expect(files.writes, 0);
    expect(files.discards, 1);
    expect(await scratch.list().toList(), isEmpty);
  });

  test('write failure discards a partial destination and private files',
      () async {
    files.failWrite = true;
    await expectLater(service().export(), throwsA(isA<FileSystemException>()));
    expect(files.discards, 1);
    expect(await files.saved.exists(), isFalse);
    expect(await scratch.list().toList(), isEmpty);
  });

  test('rejects database destinations and immutable package directories',
      () async {
    final before =
        sha256.convert(await base.databaseFile('user.db').readAsBytes());
    for (final target in [
      base.databaseFile('user.db').path,
      p.join(base.directory.path, 'copy.zip'),
      p.join(root.path, 'user.db'),
    ]) {
      files.destination = target;
      await expectLater(service().export(),
          throwsA(anyOf(isA<WeComExportException>(), isA<FormatException>())));
    }
    expect(files.writes, 0);
    expect(await scratch.list().toList(), isEmpty);
    expect(sha256.convert(await base.databaseFile('user.db').readAsBytes()),
        before);
  });
}

class _AndroidMetadataFactory implements DatabaseFactory {
  @override
  Future<Database> openDatabase(String path,
      {OpenDatabaseOptions? options}) async {
    final db = await databaseFactoryFfi.openDatabase(path, options: options);
    if (options?.readOnly != true) {
      await db
          .execute('CREATE TABLE IF NOT EXISTS android_metadata(locale TEXT)');
    }
    return db;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FileAccess implements WeComExportFileAccess {
  _FileAccess(this.saved);
  final File saved;
  String? destination;
  File? staged;
  bool cancel = false;
  bool failWrite = false;
  int choices = 0;
  int writes = 0;
  int discards = 0;
  Future<void> Function()? onChoose;

  @override
  Future<String?> choose(String fileName) async {
    choices++;
    expect(fileName, matches(r'^wecom-copy-[0-9a-f]{8}\.zip$'));
    await onChoose?.call();
    return cancel ? null : destination ?? saved.path;
  }

  @override
  Future<void> write(File archive, String destination) async {
    writes++;
    staged = archive;
    await archive.copy(destination);
    if (failWrite) throw const FileSystemException('test write failure');
  }

  @override
  Future<void> discard(String destination) async {
    discards++;
    if (await saved.exists()) await saved.delete();
  }
}
