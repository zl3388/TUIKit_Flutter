import 'dart:io';

import 'package:application/src/offline_demo/data/wecom_database_package.dart';
import 'package:application/src/offline_demo/data/wecom_identity_repository.dart';
import 'package:application/src/offline_demo/data/wecom_incremental_merge_planner.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_command_service.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_database.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_contract_validator.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory temporaryDirectory;
  late WeComPackageContract contract;
  late WeComDatabasePackageImporter importer;
  late WeComIncrementalMergePlanner planner;
  late WeComOverlayDatabase overlayDatabase;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory =
        await Directory.systemTemp.createTemp('tui_wecom_incremental_merge_');
    contract = _contract();
    importer = WeComDatabasePackageImporter(
      contract: contract,
      databaseFactory: databaseFactoryFfi,
    );
    planner = WeComIncrementalMergePlanner(
      contract: contract,
      databaseFactory: databaseFactoryFfi,
    );
    overlayDatabase = await WeComOverlayDatabase.open(
      factory: databaseFactoryFfi,
      databasePath: p.join(temporaryDirectory.path, 'overlay.db'),
    );
  });

  tearDown(() async {
    await overlayDatabase.close();
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('base row fingerprints are typed, ordered, and require every column',
      () {
    final target = WeComOverlayContractValidator(contract).resolveTarget(
      'user.db',
      'user_table',
    );
    final row = <String, Object?>{
      'id': 1,
      'real_name': '',
      'name': 'Alice',
      'account': 'alice',
      'external_corp_name': '',
      'external_job': '',
    };
    final reordered = <String, Object?>{
      'external_job': '',
      'account': 'alice',
      'id': 1,
      'name': 'Alice',
      'external_corp_name': '',
      'real_name': '',
    };

    expect(
      WeComBaseRowFingerprint.compute(target, row),
      WeComBaseRowFingerprint.compute(target, reordered),
    );
    expect(
      WeComBaseRowFingerprint.compute(target, null),
      isNot(WeComBaseRowFingerprint.compute(target, row)),
    );
    expect(
      () => WeComBaseRowFingerprint.compute(target, {'id': 1}),
      throwsFormatException,
    );
  });
  test('migrates only local fields and drops changes already in the new base',
      () async {
    final packages = await _importPair(
      temporaryDirectory,
      importer,
      oldRows: [
        _user(1, name: 'Alice', account: 'alice'),
        _user(2, name: 'Bob', account: 'bob'),
      ],
      newRows: [
        _user(1, name: 'Alice', account: 'remote-account'),
        _user(2, name: 'Bobby', account: 'bob'),
      ],
    );
    final commands = _commands(overlayDatabase, contract);
    final firstRevision = await commands.upsert(
      datasetId: packages.oldPackage.datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 1},
      values: const {'name': 'Alicia'},
    );
    await commands.upsert(
      datasetId: packages.oldPackage.datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 2},
      values: const {'name': 'Bobby'},
    );

    final plan = await planner.plan(
      oldBasePackage: packages.oldPackage,
      newBasePackage: packages.newPackage,
      overlayDatabase: overlayDatabase,
      identityScope: const WeComIdentityScope(
        corporationId: 100,
        userId: 1,
      ),
    );

    expect(plan.canApply, isTrue);
    expect(plan.sourceRevisionCount, 2);
    expect(plan.conflicts, isEmpty);
    expect(plan.operations, hasLength(1));
    expect(
        plan.operations.single.type, WeComPlannedOverlayOperationType.upsert);
    expect(plan.operations.single.rowKey, {'id': 1});
    expect(plan.operations.single.values, {'name': 'Alicia'});
    expect(plan.operations.single.sourceRevisionIds, [firstRevision]);
    expect(plan.operations.single.baseRowSha256, matches(r'^[0-9a-f]{64}$'));
  });

  test('reports a field conflict when both sides change the same field',
      () async {
    final packages = await _importPair(
      temporaryDirectory,
      importer,
      oldRows: [_user(1, name: 'Alice')],
      newRows: [_user(1, name: 'Alix')],
    );
    final commands = _commands(overlayDatabase, contract);
    await commands.upsert(
      datasetId: packages.oldPackage.datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 1},
      values: const {'name': 'Alicia'},
    );

    final plan = await planner.plan(
      oldBasePackage: packages.oldPackage,
      newBasePackage: packages.newPackage,
      overlayDatabase: overlayDatabase,
      identityScope: const WeComIdentityScope(
        corporationId: 100,
        userId: 1,
      ),
    );

    expect(plan.canApply, isFalse);
    expect(plan.operations, isEmpty);
    expect(plan.conflicts, hasLength(1));
    expect(
      plan.conflicts.single.kind,
      WeComIncrementalConflictKind.fieldUpdate,
    );
    expect(plan.conflicts.single.conflictingColumns, ['name']);
  });

  test('reports update-delete and delete-update conflicts', () async {
    final packages = await _importPair(
      temporaryDirectory,
      importer,
      oldRows: [
        _user(1, name: 'Alice', account: 'alice'),
        _user(2, name: 'Bob'),
      ],
      newRows: [
        _user(1, name: 'Alice', account: 'remote-account'),
      ],
    );
    final commands = _commands(overlayDatabase, contract);
    await commands.tombstone(
      datasetId: packages.oldPackage.datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 1},
    );
    await commands.upsert(
      datasetId: packages.oldPackage.datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 2},
      values: const {'name': 'Bobby'},
    );

    final plan = await planner.plan(
      oldBasePackage: packages.oldPackage,
      newBasePackage: packages.newPackage,
      overlayDatabase: overlayDatabase,
      identityScope: const WeComIdentityScope(
        corporationId: 100,
        userId: 1,
      ),
    );

    expect(plan.operations, isEmpty);
    expect(
      plan.conflicts.map((conflict) => conflict.kind),
      [
        WeComIncrementalConflictKind.localDeleteRemoteUpdate,
        WeComIncrementalConflictKind.remoteDelete,
      ],
    );
  });

  test('reports concurrent inserts and replacement-update conflicts', () async {
    final packages = await _importPair(
      temporaryDirectory,
      importer,
      oldRows: [_user(4, name: 'Original')],
      newRows: [
        _user(3, name: 'Remote creation'),
        _user(4, name: 'Remote update'),
      ],
    );
    final commands = _commands(overlayDatabase, contract);
    await commands.upsert(
      datasetId: packages.oldPackage.datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 3},
      values: const {'name': 'Local creation'},
    );
    await commands.tombstone(
      datasetId: packages.oldPackage.datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 4},
    );
    await commands.upsert(
      datasetId: packages.oldPackage.datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 4},
      values: const {'name': 'Local replacement'},
    );

    final plan = await planner.plan(
      oldBasePackage: packages.oldPackage,
      newBasePackage: packages.newPackage,
      overlayDatabase: overlayDatabase,
      identityScope: const WeComIdentityScope(
        corporationId: 100,
        userId: 1,
      ),
    );

    expect(plan.operations, isEmpty);
    expect(
      plan.conflicts.map((conflict) => conflict.kind),
      [
        WeComIncrementalConflictKind.concurrentInsert,
        WeComIncrementalConflictKind.localReplaceRemoteUpdate,
      ],
    );
    expect(plan.conflicts.last.sourceRevisionIds, [2, 3]);
  });

  test('preserves safe deletes and delete-then-recreate semantics', () async {
    final rows = [
      _user(1, name: 'Alice'),
      _user(2, name: 'Bob'),
    ];
    final packages = await _importPair(
      temporaryDirectory,
      importer,
      oldRows: rows,
      newRows: rows,
      mutateNewFile: true,
    );
    final commands = _commands(overlayDatabase, contract);
    await commands.tombstone(
      datasetId: packages.oldPackage.datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 1},
    );
    await commands.tombstone(
      datasetId: packages.oldPackage.datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 2},
    );
    await commands.upsert(
      datasetId: packages.oldPackage.datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 2},
      values: const {'name': 'Replacement'},
    );

    final plan = await planner.plan(
      oldBasePackage: packages.oldPackage,
      newBasePackage: packages.newPackage,
      overlayDatabase: overlayDatabase,
      identityScope: const WeComIdentityScope(
        corporationId: 100,
        userId: 1,
      ),
    );

    expect(plan.canApply, isTrue);
    expect(plan.conflicts, isEmpty);
    expect(
      plan.operations.map((operation) => operation.type),
      [
        WeComPlannedOverlayOperationType.tombstone,
        WeComPlannedOverlayOperationType.tombstone,
        WeComPlannedOverlayOperationType.upsert,
      ],
    );
    expect(plan.operations[1].rowKey, {'id': 2});
    expect(plan.operations[2].values, {'name': 'Replacement'});
    expect(plan.operations[1].sourceRevisionIds, [2, 3]);
    expect(plan.operations[2].sourceRevisionIds, [2, 3]);
  });

  test('treats a stale base fingerprint as a conflict without writing data',
      () async {
    final packages = await _importPair(
      temporaryDirectory,
      importer,
      oldRows: [_user(1, name: 'Alice')],
      newRows: [_user(1, name: 'Alice', account: 'remote')],
    );
    final commands = _commands(overlayDatabase, contract);
    await commands.upsert(
      datasetId: packages.oldPackage.datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 1},
      values: const {'name': 'Alicia'},
      baseRowSha256:
          '0000000000000000000000000000000000000000000000000000000000000000',
    );
    final oldBytes =
        await packages.oldPackage.databaseFile('user.db').readAsBytes();
    final newBytes =
        await packages.newPackage.databaseFile('user.db').readAsBytes();
    final overlayBefore = await overlayDatabase.connection.query(
      WeComOverlaySchema.operationsTable,
    );

    final plan = await planner.plan(
      oldBasePackage: packages.oldPackage,
      newBasePackage: packages.newPackage,
      overlayDatabase: overlayDatabase,
      identityScope: const WeComIdentityScope(
        corporationId: 100,
        userId: 1,
      ),
    );

    expect(plan.operations, isEmpty);
    expect(plan.conflicts.single.kind,
        WeComIncrementalConflictKind.baseFingerprintMismatch);
    expect(
      await packages.oldPackage.databaseFile('user.db').readAsBytes(),
      oldBytes,
    );
    expect(
      await packages.newPackage.databaseFile('user.db').readAsBytes(),
      newBytes,
    );
    expect(
      await overlayDatabase.connection.query(
        WeComOverlaySchema.operationsTable,
      ),
      overlayBefore,
    );
  });

  test('rejects revisions outside the certified merge surface', () async {
    final packages = await _importPair(
      temporaryDirectory,
      importer,
      oldRows: [_user(1, name: 'Alice')],
      newRows: [_user(1, name: 'Alice', account: 'remote')],
    );
    await overlayDatabase.connection.insert(
      WeComOverlaySchema.operationsTable,
      {
        'dataset_id': packages.oldPackage.datasetId,
        'identity_corp_id': 100,
        'identity_user_id': 1,
        'database_name': 'user.db',
        'table_name': 'user_dept_tableV2',
        'row_key_json': '{"user_id":1,"department_id":10}',
        'operation': 'upsert',
        'values_json': '{"status":1}',
        'created_at_micros': DateTime.now().toUtc().microsecondsSinceEpoch,
      },
    );

    await expectLater(
      planner.plan(
        oldBasePackage: packages.oldPackage,
        newBasePackage: packages.newPackage,
        overlayDatabase: overlayDatabase,
        identityScope: const WeComIdentityScope(
          corporationId: 100,
          userId: 1,
        ),
      ),
      throwsA(
        isA<WeComIncrementalMergeException>().having(
          (error) => error.code,
          'code',
          WeComIncrementalMergeIssueCode.unsupportedTarget,
        ),
      ),
    );
  });

  test('ignores revisions owned by another identity', () async {
    final packages = await _importPair(
      temporaryDirectory,
      importer,
      oldRows: [_user(1, name: 'Alice')],
      newRows: [_user(1, name: 'Alice', account: 'remote')],
    );
    await overlayDatabase.connection.insert(
      WeComOverlaySchema.operationsTable,
      {
        'dataset_id': packages.oldPackage.datasetId,
        'identity_corp_id': 200,
        'identity_user_id': 2,
        'database_name': 'user.db',
        'table_name': 'user_dept_tableV2',
        'row_key_json': '{"user_id":1,"department_id":10}',
        'operation': 'upsert',
        'values_json': '{"status":1}',
        'created_at_micros': DateTime.now().toUtc().microsecondsSinceEpoch,
      },
    );

    final plan = await planner.plan(
      oldBasePackage: packages.oldPackage,
      newBasePackage: packages.newPackage,
      overlayDatabase: overlayDatabase,
      identityScope: const WeComIdentityScope(
        corporationId: 100,
        userId: 1,
      ),
    );

    expect(plan.sourceRevisionCount, 0);
    expect(plan.operations, isEmpty);
    expect(plan.conflicts, isEmpty);
  });
}

WeComOverlayCommandService _commands(
  WeComOverlayDatabase database,
  WeComPackageContract contract,
) {
  return WeComOverlayCommandService(
    overlayDatabase: database,
    contract: contract,
    identityScope: const WeComIdentityScope(
      corporationId: 100,
      userId: 1,
    ),
  );
}

Future<_ImportedPair> _importPair(
  Directory root,
  WeComDatabasePackageImporter importer, {
  required List<Map<String, Object?>> oldRows,
  required List<Map<String, Object?>> newRows,
  bool mutateNewFile = false,
}) async {
  final oldSource = await Directory(p.join(root.path, 'old-source')).create();
  final newSource = await Directory(p.join(root.path, 'new-source')).create();
  await _createSource(oldSource, oldRows);
  await _createSource(newSource, newRows);
  if (mutateNewFile) {
    final database = await databaseFactoryFfi.openDatabase(
      p.join(newSource.path, 'user.db'),
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await database.execute('PRAGMA user_version = 1');
    await database.close();
  }
  final imports = Directory(p.join(root.path, 'imports'));
  return _ImportedPair(
    oldPackage: await importer.importPackage(
      sourceDirectory: oldSource,
      destinationRoot: imports,
    ),
    newPackage: await importer.importPackage(
      sourceDirectory: newSource,
      destinationRoot: imports,
    ),
  );
}

Future<void> _createSource(
  Directory source,
  List<Map<String, Object?>> rows,
) async {
  final database = await databaseFactoryFfi.openDatabase(
    p.join(source.path, 'user.db'),
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await database.execute(
    'CREATE TABLE user_table ('
    'id INTEGER NOT NULL PRIMARY KEY, '
    "real_name TEXT NOT NULL DEFAULT '', "
    "name TEXT NOT NULL DEFAULT '', "
    "account TEXT NOT NULL DEFAULT '', "
    "external_corp_name TEXT NOT NULL DEFAULT '', "
    "external_job TEXT NOT NULL DEFAULT ''"
    ')',
  );
  for (final row in rows) {
    await database.insert('user_table', row);
  }
  await database.close();
}

Map<String, Object?> _user(
  int id, {
  required String name,
  String account = '',
}) {
  return {
    'id': id,
    'name': name,
    'account': account,
  };
}

WeComPackageContract _contract() {
  return WeComPackageContract(
    formatVersion: 1,
    scope: 'incremental merge contract test',
    databases: [
      WeComDatabaseContract(
        fileName: 'user.db',
        allowEmpty: false,
        tables: {
          'user_table': [
            _column('id', 'INTEGER', notNull: true, primaryKeyPosition: 1),
            _column('real_name', 'TEXT', notNull: true),
            _column('name', 'TEXT', notNull: true),
            _column('account', 'TEXT', notNull: true),
            _column('external_corp_name', 'TEXT', notNull: true),
            _column('external_job', 'TEXT', notNull: true),
          ],
        },
        indexes: const {},
      ),
    ],
  );
}

WeComColumnContract _column(
  String name,
  String type, {
  bool notNull = false,
  int primaryKeyPosition = 0,
}) {
  return WeComColumnContract(
    name: name,
    type: type,
    notNull: notNull,
    primaryKeyPosition: primaryKeyPosition,
  );
}

class _ImportedPair {
  const _ImportedPair({
    required this.oldPackage,
    required this.newPackage,
  });

  final WeComImportedPackage oldPackage;
  final WeComImportedPackage newPackage;
}
