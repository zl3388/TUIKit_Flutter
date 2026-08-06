import 'dart:io';

import 'package:application/src/offline_demo/data/wecom_database_package.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _publicTestKey = '79fbb424f3035e57c6d4cde3a6981de3';
const _publicTestSalt = '86dbbb39ecd0da3e6e11df85f7a3da47';
const _decryptedJournalSha256 =
    '4abc4f053409a193c109576999f3deca4a213806aac6f82cecd9f72de36c4ca4';

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

  test('imports an encrypted package with a salt-matched default key',
      () async {
    await _createEncryptedSourcePackage(sourceDirectory);
    final sourceBefore = await _snapshotSource(sourceDirectory);

    final imported = await _importer(_encryptedContract()).importPackage(
      sourceDirectory: sourceDirectory,
      destinationRoot: destinationDirectory,
      defaultRawKeysBySalt: {
        _publicTestSalt.toUpperCase(): _publicTestKey,
      },
    );

    expect(imported.files['main.db']!.sha256, _decryptedJournalSha256);
    expect(await _snapshotSource(sourceDirectory), sourceBefore);
    final database = await imported.openReadOnly(
      'main.db',
      factory: databaseFactoryFfi,
    );
    addTearDown(database.close);
    expect(
      await database.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
      ),
      [
        {'name': 'journal_template_v2'},
        {'name': 'journal_v1'},
      ],
    );
  });

  test('temporary key is tried after a mismatched default key', () async {
    await _createEncryptedSourcePackage(sourceDirectory);

    final imported = await _importer(_encryptedContract()).importPackage(
      sourceDirectory: sourceDirectory,
      destinationRoot: destinationDirectory,
      defaultRawKeysBySalt: {
        _publicTestSalt: '79fbb424f3035e57c6d4cde3a6981de2',
      },
      temporaryRawKeyHex: _publicTestKey,
    );

    expect(imported.files['main.db']!.sha256, _decryptedJournalSha256);
  });

  test('wrong decryption key preserves the source and destination', () async {
    await _createEncryptedSourcePackage(sourceDirectory);
    final sourceBefore = await _snapshotSource(sourceDirectory);

    await expectLater(
      _importer(_encryptedContract()).importPackage(
        sourceDirectory: sourceDirectory,
        destinationRoot: destinationDirectory,
        temporaryRawKeyHex: '79fbb424f3035e57c6d4cde3a6981de2',
      ),
      throwsA(
        isA<WeComPackageException>().having(
          (error) => error.code,
          'code',
          WeComPackageIssueCode.decryptionFailed,
        ),
      ),
    );

    expect(await _snapshotSource(sourceDirectory), sourceBefore);
    expect(await destinationDirectory.exists(), isFalse);
  });

  test('normalizes an empty private FTS table in the imported copy', () async {
    await _createPrivateFtsSourcePackage(sourceDirectory, withContent: false);
    final sourceBefore = await _snapshotSource(sourceDirectory);

    final imported = await _importer(_privateFtsContract()).importPackage(
      sourceDirectory: sourceDirectory,
      destinationRoot: destinationDirectory,
    );

    expect(await _snapshotSource(sourceDirectory), sourceBefore);
    final database = await imported.openReadOnly(
      'main.db',
      factory: databaseFactoryFfi,
    );
    addTearDown(database.close);
    final schema = await database.rawQuery(
      "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
      ['fts_probe'],
    );
    expect(schema.single['sql'], contains('tokenize=unicode61'));
    expect(
      await database.rawQuery('SELECT COUNT(*) AS count FROM fts_probe'),
      [
        {'count': 0}
      ],
    );
    expect(
      await database.rawQuery('PRAGMA integrity_check'),
      [
        {'integrity_check': 'ok'}
      ],
    );
  });

  test('rejects a non-empty private FTS index without changing the source',
      () async {
    await _createPrivateFtsSourcePackage(sourceDirectory, withContent: true);
    final sourceBefore = await _snapshotSource(sourceDirectory);

    await expectLater(
      _importer(_privateFtsContract()).importPackage(
        sourceDirectory: sourceDirectory,
        destinationRoot: destinationDirectory,
      ),
      throwsA(
        isA<WeComPackageException>().having(
          (error) => error.code,
          'code',
          WeComPackageIssueCode.privateFtsIndexNotEmpty,
        ),
      ),
    );

    expect(await _snapshotSource(sourceDirectory), sourceBefore);
    expect(await destinationDirectory.exists(), isFalse);
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

  test('encrypted input requests a key without touching the source', () async {
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
              WeComPackageIssueCode.decryptionKeyRequired,
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

WeComPackageContract _encryptedContract() {
  return WeComPackageContract(
    formatVersion: 1,
    scope: 'encrypted-test',
    databases: [
      WeComDatabaseContract(
        fileName: 'main.db',
        allowEmpty: false,
        tables: const {
          'journal_v1': <WeComColumnContract>[],
          'journal_template_v2': <WeComColumnContract>[],
        },
        indexes: const {},
        skipColumnValidation: const {
          'journal_v1',
          'journal_template_v2',
        },
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

WeComPackageContract _privateFtsContract() {
  const ftsTables = {
    'fts_probe': <WeComColumnContract>[],
    'fts_probe_config': <WeComColumnContract>[],
    'fts_probe_content': <WeComColumnContract>[],
    'fts_probe_data': <WeComColumnContract>[],
    'fts_probe_docsize': <WeComColumnContract>[],
    'fts_probe_idx': <WeComColumnContract>[],
  };
  return WeComPackageContract(
    formatVersion: 1,
    scope: 'private-fts-test',
    databases: [
      WeComDatabaseContract(
        fileName: 'main.db',
        allowEmpty: false,
        tables: ftsTables,
        indexes: const {},
        skipColumnValidation: ftsTables.keys.toSet(),
        expectedFtsTokenizers: const {'fts_probe': 'unicode61'},
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

Future<void> _createEncryptedSourcePackage(Directory source) async {
  await File(
    p.join('test', 'fixtures', 'offline_demo', 'encrypted_journal.db'),
  ).copy(p.join(source.path, 'main.db'));
  await File(p.join(source.path, 'empty.db')).create();
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

Future<void> _createPrivateFtsSourcePackage(
  Directory source, {
  required bool withContent,
}) async {
  final database = await databaseFactoryFfi.openDatabase(
    p.join(source.path, 'main.db'),
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await database.execute(
    'CREATE VIRTUAL TABLE fts_probe USING fts5('
    "content, prefix='1 2 3 4 5 6 7 8 9 10', tokenize='unicode61'"
    ')',
  );
  if (withContent) {
    await database.execute(
      "INSERT INTO fts_probe(content) VALUES ('indexed content')",
    );
  }
  await database.execute('PRAGMA writable_schema = ON');
  try {
    final updated = await database.rawUpdate(
      "UPDATE sqlite_master SET sql = 'CREATE VIRTUAL TABLE fts_probe "
      "USING fts5(content, prefix=''1 2 3 4 5 6 7 8 9 10'', "
      "tokenize=fts5word)' WHERE type = 'table' AND name = 'fts_probe'",
    );
    if (updated != 1) {
      throw StateError('Could not prepare the private FTS test fixture');
    }
  } finally {
    await database.execute('PRAGMA writable_schema = OFF');
  }
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
