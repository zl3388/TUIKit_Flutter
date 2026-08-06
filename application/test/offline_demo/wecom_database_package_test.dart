import 'dart:io';

import 'package:application/src/offline_demo/data/wecom_database_package.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory temporaryDirectory;
  late Directory sourceDirectory;
  late Directory destinationDirectory;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory =
        await Directory.systemTemp.createTemp('tui_wecom_package_');
    sourceDirectory =
        await Directory(p.join(temporaryDirectory.path, 'source')).create();
    destinationDirectory =
        Directory(p.join(temporaryDirectory.path, 'destination'));
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('current schema contract matches the approved baseline', () async {
    final contract = WeComPackageContract.fromJsonString(
      await File(
        p.join(
          'assets',
          'offline_demo',
          'wecom_schema_contract.json',
        ),
      ).readAsString(),
    );

    expect(contract.formatVersion, 1);
    expect(contract.databases, hasLength(21));
    expect(contract.expectedTableCount, 321);
    expect(contract.expectedIndexCount, 225);
    final crm = contract.databases
        .singleWhere((database) => database.fileName == 'crm.db');
    expect(
      crm.skipColumnValidation,
      contains('idx_crm_service_group_index_table'),
    );
    expect(
      crm.expectedFtsTokenizers['idx_crm_service_group_index_table'],
      'unicode61',
    );
  });

  test('imports a validated copy and reuses the content-addressed dataset',
      () async {
    await _createValidSourcePackage(sourceDirectory);
    final sourceBefore = await _snapshotSource(sourceDirectory);
    final importer = _importer(_validContract());

    final imported = await importer.importPackage(
      sourceDirectory: sourceDirectory,
      destinationRoot: destinationDirectory,
    );

    expect(imported.reusedExisting, isFalse);
    expect(imported.datasetId, hasLength(64));
    expect(imported.files.keys, containsAll(['main.db', 'empty.db']));
    expect(
      await File(
        p.join(imported.directory.path, 'dataset.json'),
      ).exists(),
      isTrue,
    );
    expect(await imported.databaseFile('main.db').exists(), isTrue);
    expect(await _snapshotSource(sourceDirectory), sourceBefore);

    final readOnlyDatabase = await imported.openReadOnly(
      'main.db',
      factory: databaseFactoryFfi,
    );
    addTearDown(readOnlyDatabase.close);
    expect(
      await readOnlyDatabase.rawQuery('SELECT body FROM notes'),
      [
        {'body': 'baseline'}
      ],
    );
    await expectLater(
      readOnlyDatabase.insert('notes', {'body': 'not allowed'}),
      throwsA(isA<DatabaseException>()),
    );

    final reused = await importer.importPackage(
      sourceDirectory: sourceDirectory,
      destinationRoot: destinationDirectory,
    );
    expect(reused.reusedExisting, isTrue);
    expect(reused.datasetId, imported.datasetId);
    expect(reused.directory.path, imported.directory.path);
    expect(await _snapshotSource(sourceDirectory), sourceBefore);
  });

  test('missing required database fails before creating a destination',
      () async {
    await _createMainDatabase(sourceDirectory);
    final importer = _importer(_validContract());

    await expectLater(
      importer.importPackage(
        sourceDirectory: sourceDirectory,
        destinationRoot: destinationDirectory,
      ),
      throwsA(
        isA<WeComPackageException>()
            .having(
              (error) => error.code,
              'code',
              WeComPackageIssueCode.requiredFileMissing,
            )
            .having((error) => error.fileName, 'fileName', 'empty.db'),
      ),
    );

    expect(await destinationDirectory.exists(), isFalse);
  });

  test('schema mismatch removes staging data and preserves the source',
      () async {
    await _createValidSourcePackage(sourceDirectory);
    final sourceBefore = await _snapshotSource(sourceDirectory);
    final invalidContract = WeComPackageContract(
      formatVersion: 1,
      scope: 'test',
      databases: [
        WeComDatabaseContract(
          fileName: 'main.db',
          allowEmpty: false,
          tables: {
            ..._mainTableContract(),
            'missing_table': const <WeComColumnContract>[],
          },
          indexes: {'idx_notes_body'},
        ),
        WeComDatabaseContract(
          fileName: 'empty.db',
          allowEmpty: true,
          tables: const {},
          indexes: const {},
        ),
      ],
    );

    await expectLater(
      _importer(invalidContract).importPackage(
        sourceDirectory: sourceDirectory,
        destinationRoot: destinationDirectory,
      ),
      throwsA(
        isA<WeComPackageException>().having(
          (error) => error.code,
          'code',
          WeComPackageIssueCode.schemaMismatch,
        ),
      ),
    );

    expect(await _snapshotSource(sourceDirectory), sourceBefore);
    final datasets = Directory(
      p.join(destinationDirectory.path, 'datasets'),
    );
    expect(
      await datasets
          .list()
          .where((entity) => p.basename(entity.path).startsWith('.import-'))
          .isEmpty,
      isTrue,
    );
  });

  test('existing dataset is revalidated against the active contract', () async {
    await _createValidSourcePackage(sourceDirectory);
    await _importer(_validContract()).importPackage(
      sourceDirectory: sourceDirectory,
      destinationRoot: destinationDirectory,
    );
    final changedContract = WeComPackageContract(
      formatVersion: 1,
      scope: 'changed-test-contract',
      databases: [
        WeComDatabaseContract(
          fileName: 'main.db',
          allowEmpty: false,
          tables: {
            ..._mainTableContract(),
            'new_required_table': const <WeComColumnContract>[],
          },
          indexes: {'idx_notes_body'},
        ),
        WeComDatabaseContract(
          fileName: 'empty.db',
          allowEmpty: true,
          tables: const {},
          indexes: const {},
        ),
      ],
    );

    await expectLater(
      _importer(changedContract).importPackage(
        sourceDirectory: sourceDirectory,
        destinationRoot: destinationDirectory,
      ),
      throwsA(
        isA<WeComPackageException>().having(
          (error) => error.code,
          'code',
          WeComPackageIssueCode.schemaMismatch,
        ),
      ),
    );
  });

  test('corrupt existing manifest is rejected', () async {
    await _createValidSourcePackage(sourceDirectory);
    final sourceBefore = await _snapshotSource(sourceDirectory);
    final importer = _importer(_validContract());
    final imported = await importer.importPackage(
      sourceDirectory: sourceDirectory,
      destinationRoot: destinationDirectory,
    );
    await File(
      p.join(imported.directory.path,
          WeComDatabasePackageImporter.manifestFileName),
    ).writeAsString('{}', flush: true);

    await expectLater(
      importer.importPackage(
        sourceDirectory: sourceDirectory,
        destinationRoot: destinationDirectory,
      ),
      throwsA(
        isA<WeComPackageException>().having(
          (error) => error.code,
          'code',
          WeComPackageIssueCode.existingPackageCorrupt,
        ),
      ),
    );
    expect(await _snapshotSource(sourceDirectory), sourceBefore);
  });

  test('non-plaintext input is rejected without touching the source', () async {
    final main = File(p.join(sourceDirectory.path, 'main.db'));
    await main.writeAsBytes(List<int>.filled(4096, 7), flush: true);
    await File(p.join(sourceDirectory.path, 'empty.db')).create();
    final sourceBefore = await _snapshotSource(sourceDirectory);

    await expectLater(
      _importer(_validContract()).importPackage(
        sourceDirectory: sourceDirectory,
        destinationRoot: destinationDirectory,
      ),
      throwsA(
        isA<WeComPackageException>()
            .having(
              (error) => error.code,
              'code',
              WeComPackageIssueCode.encryptedOrUnsupportedInput,
            )
            .having((error) => error.fileName, 'fileName', 'main.db'),
      ),
    );

    expect(await destinationDirectory.exists(), isFalse);
    expect(await _snapshotSource(sourceDirectory), sourceBefore);
  });
}

WeComDatabasePackageImporter _importer(WeComPackageContract contract) {
  return WeComDatabasePackageImporter(
    contract: contract,
    databaseFactory: databaseFactoryFfi,
  );
}

WeComPackageContract _validContract() {
  return WeComPackageContract(
    formatVersion: 1,
    scope: 'test',
    databases: [
      WeComDatabaseContract(
        fileName: 'main.db',
        allowEmpty: false,
        tables: _mainTableContract(),
        indexes: {'idx_notes_body'},
      ),
      WeComDatabaseContract(
        fileName: 'empty.db',
        allowEmpty: true,
        tables: const {},
        indexes: const {},
      ),
    ],
  );
}

Map<String, List<WeComColumnContract>> _mainTableContract() {
  return {
    'notes': const [
      WeComColumnContract(
        name: 'id',
        type: 'INTEGER',
        notNull: false,
        primaryKeyPosition: 1,
      ),
      WeComColumnContract(
        name: 'body',
        type: 'TEXT',
        notNull: true,
        primaryKeyPosition: 0,
      ),
    ],
  };
}

Future<void> _createValidSourcePackage(Directory source) async {
  await _createMainDatabase(source);
  await File(p.join(source.path, 'empty.db')).create();
}

Future<void> _createMainDatabase(Directory source) async {
  final database = await databaseFactoryFfi.openDatabase(
    p.join(source.path, 'main.db'),
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (database, version) async {
        await database.execute(
          'CREATE TABLE notes ('
          'id INTEGER PRIMARY KEY, '
          'body TEXT NOT NULL'
          ')',
        );
        await database.execute(
          'CREATE INDEX idx_notes_body ON notes(body)',
        );
        await database.insert('notes', {'body': 'baseline'});
      },
    ),
  );
  await database.close();
}

Future<Map<String, List<int>>> _snapshotSource(Directory source) async {
  final files = await source
      .list()
      .where((entity) => entity is File)
      .cast<File>()
      .toList();
  files.sort((left, right) => left.path.compareTo(right.path));
  return {
    for (final file in files) p.basename(file.path): await file.readAsBytes(),
  };
}
