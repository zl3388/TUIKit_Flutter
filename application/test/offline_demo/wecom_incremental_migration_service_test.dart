import 'dart:io';

import 'package:application/src/offline_demo/data/wecom_database_package.dart';
import 'package:application/src/offline_demo/data/wecom_incremental_merge_planner.dart';
import 'package:application/src/offline_demo/data/wecom_incremental_migration_service.dart';
import 'package:application/src/offline_demo/data/wecom_identity_repository.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_command_service.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_database.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'wecom_identity_test_fixture.dart';

void main() {
  late Directory temporaryDirectory;
  late WeComPackageContract contract;
  late WeComDatabasePackageImporter importer;
  late WeComOverlayDatabase overlayDatabase;
  late WeComOverlayCommandService commands;
  late WeComIncrementalMigrationService migrations;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory =
        await Directory.systemTemp.createTemp('tui_wecom_migration_');
    contract = _contract();
    importer = WeComDatabasePackageImporter(
      contract: contract,
      databaseFactory: databaseFactoryFfi,
    );
    overlayDatabase = await WeComOverlayDatabase.open(
      factory: databaseFactoryFfi,
      databasePath: p.join(temporaryDirectory.path, 'overlay.db'),
    );
    commands = WeComOverlayCommandService(
      overlayDatabase: overlayDatabase,
      contract: contract,
    );
    migrations = WeComIncrementalMigrationService(
      overlayDatabase: overlayDatabase,
      planner: WeComIncrementalMergePlanner(
        contract: contract,
        databaseFactory: databaseFactoryFfi,
      ),
      identityResolver: WeComIdentityResolver(databaseFactoryFfi),
    );
  });

  tearDown(() async {
    await overlayDatabase.close();
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('does not activate a migration source without an identity', () async {
    final packages = await _importPackages(
      temporaryDirectory,
      importer,
      oldRows: [_user(1, name: 'Alice')],
      newRows: [_user(1, name: 'Alice', account: 'remote')],
    );

    await expectLater(
      migrations.migrate(
        oldBasePackage: packages.oldPackage,
        newBasePackage: packages.newPackage,
      ),
      throwsA(
        isA<WeComIncrementalMigrationException>().having(
          (error) => error.code,
          'code',
          WeComIncrementalMigrationIssueCode.activeIdentityRequired,
        ),
      ),
    );
    expect(
      await _count(
        overlayDatabase,
        WeComOverlaySchema.datasetActivationsTable,
      ),
      0,
    );
  });

  test('persists conflicts without target revisions or business values',
      () async {
    final packages = await _importPackages(
      temporaryDirectory,
      importer,
      oldRows: [_user(1, name: 'Alice')],
      newRows: [_user(1, name: 'Alix')],
    );
    final sourceRevision = await commands.upsert(
      datasetId: packages.oldPackage.datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 1},
      values: const {'name': 'Alicia'},
    );
    await _activate(overlayDatabase, packages.oldPackage.datasetId);

    final result = await migrations.migrate(
      oldBasePackage: packages.oldPackage,
      newBasePackage: packages.newPackage,
    );

    expect(result.status, WeComIncrementalMigrationStatus.conflicted);
    expect(result.applied, isFalse);
    expect(result.conflictCount, 1);
    expect(result.activationId, isNull);
    expect(
      await migrations.currentActiveDatasetId(),
      packages.oldPackage.datasetId,
    );
    expect(await _operationsFor(overlayDatabase, packages.newPackage.datasetId),
        isEmpty);

    final conflicts = await migrations.listConflicts(mergeId: result.mergeId);
    expect(conflicts, hasLength(1));
    expect(conflicts.single.kind, WeComIncrementalConflictKind.fieldUpdate);
    expect(conflicts.single.rowKey, {'id': 1});
    expect(conflicts.single.sourceRevisionIds, [sourceRevision]);
    expect(conflicts.single.conflictingColumns, ['name']);

    final repeated = await migrations.migrate(
      oldBasePackage: packages.oldPackage,
      newBasePackage: packages.newPackage,
    );
    expect(repeated.reusedExisting, isTrue);
    expect(repeated.mergeId, result.mergeId);
    expect(await _count(overlayDatabase, WeComOverlaySchema.mergeAttemptsTable),
        1);
    expect(
        await _count(overlayDatabase, WeComOverlaySchema.mergeConflictsTable),
        1);
    expect(
        await _count(
          overlayDatabase,
          WeComOverlaySchema.datasetActivationsTable,
        ),
        1);

    final rawConflict = (await overlayDatabase.connection.query(
      WeComOverlaySchema.mergeConflictsTable,
    ))
        .single;
    expect(rawConflict.keys, isNot(contains('values_json')));
    expect(rawConflict.keys, isNot(contains('old_value')));
    expect(rawConflict.keys, isNot(contains('new_value')));
    await _expectAppendOnly(
      overlayDatabase,
      WeComOverlaySchema.mergeAttemptsTable,
      'merge_id',
      result.mergeId,
    );
    await _expectAppendOnly(
      overlayDatabase,
      WeComOverlaySchema.mergeConflictsTable,
      'conflict_id',
      conflicts.single.conflictId,
    );
    final bootstrapActivation = (await overlayDatabase.connection.query(
      WeComOverlaySchema.datasetActivationsTable,
    ))
        .single;
    await _expectAppendOnly(
      overlayDatabase,
      WeComOverlaySchema.datasetActivationsTable,
      'activation_id',
      bootstrapActivation['activation_id']! as int,
    );
  });

  test('applies a clean plan and activates its target atomically', () async {
    final packages = await _importPackages(
      temporaryDirectory,
      importer,
      oldRows: [_user(1, name: 'Alice', account: 'alice')],
      newRows: [_user(1, name: 'Alice', account: 'remote-account')],
    );
    await commands.upsert(
      datasetId: packages.oldPackage.datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 1},
      values: const {'name': 'Alicia'},
    );
    await _activate(overlayDatabase, packages.oldPackage.datasetId);

    final result = await migrations.migrate(
      oldBasePackage: packages.oldPackage,
      newBasePackage: packages.newPackage,
    );

    expect(result.status, WeComIncrementalMigrationStatus.applied);
    expect(result.applied, isTrue);
    expect(result.firstAppliedRevisionId, isNotNull);
    expect(result.lastAppliedRevisionId, result.firstAppliedRevisionId);
    expect(result.conflictCount, 0);
    expect(result.activationId, isNotNull);
    expect(
      await migrations.currentActiveDatasetId(),
      packages.newPackage.datasetId,
    );
    expect(
      await _operationsFor(overlayDatabase, packages.newPackage.datasetId),
      [
        {
          'database_name': 'user.db',
          'table_name': 'user_table',
          'row_key_json': '{"id":1}',
          'operation': 'upsert',
          'values_json': '{"name":"Alicia"}',
        },
      ],
    );
    expect(await migrations.listConflicts(mergeId: result.mergeId), isEmpty);

    final activations = await overlayDatabase.connection.query(
      WeComOverlaySchema.datasetActivationsTable,
      orderBy: 'activation_id',
    );
    expect(activations, hasLength(2));
    expect(activations.first['previous_dataset_id'], isNull);
    expect(activations.first['dataset_id'], packages.oldPackage.datasetId);
    expect(activations.first['merge_id'], isNull);
    expect(
      activations.last['previous_dataset_id'],
      packages.oldPackage.datasetId,
    );
    expect(activations.last['dataset_id'], packages.newPackage.datasetId);
    expect(activations.last['merge_id'], result.mergeId);
  });

  test('reuses an applied attempt until a later dataset is active', () async {
    final packages = await _importPackages(
      temporaryDirectory,
      importer,
      oldRows: [_user(1, name: 'Alice')],
      newRows: [_user(1, name: 'Alice', account: 'remote')],
    );
    await commands.upsert(
      datasetId: packages.oldPackage.datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 1},
      values: const {'name': 'Alicia'},
    );
    await _activate(overlayDatabase, packages.oldPackage.datasetId);
    final first = await migrations.migrate(
      oldBasePackage: packages.oldPackage,
      newBasePackage: packages.newPackage,
    );
    final repeated = await migrations.migrate(
      oldBasePackage: packages.oldPackage,
      newBasePackage: packages.newPackage,
    );

    expect(repeated.reusedExisting, isTrue);
    expect(repeated.mergeId, first.mergeId);
    expect(repeated.activationId, first.activationId);
    expect(await _count(overlayDatabase, WeComOverlaySchema.mergeAttemptsTable),
        1);
    expect(
        await _count(
            overlayDatabase, WeComOverlaySchema.datasetActivationsTable),
        2);
    expect(await _operationsFor(overlayDatabase, packages.newPackage.datasetId),
        hasLength(1));

    const laterDataset =
        'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
    final laterMergeId = await overlayDatabase.connection.insert(
      WeComOverlaySchema.mergeAttemptsTable,
      {
        'old_dataset_id': packages.newPackage.datasetId,
        'new_dataset_id': laterDataset,
        'source_revision_count': 1,
        'status': WeComIncrementalMigrationStatus.applied.name,
        'first_applied_revision_id': null,
        'last_applied_revision_id': null,
        'conflict_count': 0,
        'created_at_micros': DateTime.now().toUtc().microsecondsSinceEpoch,
      },
    );
    await overlayDatabase.connection.insert(
      WeComOverlaySchema.datasetActivationsTable,
      {
        'previous_dataset_id': packages.newPackage.datasetId,
        'dataset_id': laterDataset,
        'merge_id': laterMergeId,
        'current_corp_id': 100,
        'current_user_id': 1,
        'created_at_micros': DateTime.now().toUtc().microsecondsSinceEpoch,
      },
    );

    await expectLater(
      migrations.migrate(
        oldBasePackage: packages.oldPackage,
        newBasePackage: packages.newPackage,
      ),
      throwsA(
        isA<WeComIncrementalMigrationException>().having(
          (error) => error.code,
          'code',
          WeComIncrementalMigrationIssueCode.activeDatasetMismatch,
        ),
      ),
    );
  });

  test('rejects a target with independent revisions without activating it',
      () async {
    final packages = await _importPackages(
      temporaryDirectory,
      importer,
      oldRows: [_user(1, name: 'Alice')],
      newRows: [_user(1, name: 'Alice', account: 'remote')],
    );
    await commands.upsert(
      datasetId: packages.oldPackage.datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 1},
      values: const {'name': 'Alicia'},
    );
    await commands.upsert(
      datasetId: packages.newPackage.datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 1},
      values: const {'name': 'Independent target edit'},
    );
    await _activate(overlayDatabase, packages.oldPackage.datasetId);

    await expectLater(
      migrations.migrate(
        oldBasePackage: packages.oldPackage,
        newBasePackage: packages.newPackage,
      ),
      throwsA(
        isA<WeComIncrementalMigrationException>().having(
          (error) => error.code,
          'code',
          WeComIncrementalMigrationIssueCode.targetOverlayNotEmpty,
        ),
      ),
    );

    expect(
      await migrations.currentActiveDatasetId(),
      packages.oldPackage.datasetId,
    );
    expect(await _count(overlayDatabase, WeComOverlaySchema.mergeAttemptsTable),
        0);
    expect(
        await _count(
            overlayDatabase, WeComOverlaySchema.datasetActivationsTable),
        1);
    expect(await _operationsFor(overlayDatabase, packages.newPackage.datasetId),
        hasLength(1));
  });

  test('rejects a merge whose source is not the active dataset', () async {
    const otherDataset =
        'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';
    final packages = await _importPackages(
      temporaryDirectory,
      importer,
      oldRows: [_user(1, name: 'Alice')],
      newRows: [_user(1, name: 'Alice', account: 'remote')],
    );
    await commands.upsert(
      datasetId: packages.oldPackage.datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 1},
      values: const {'name': 'Alicia'},
    );
    await overlayDatabase.connection.insert(
      WeComOverlaySchema.datasetActivationsTable,
      {
        'previous_dataset_id': null,
        'dataset_id': otherDataset,
        'merge_id': null,
        'current_corp_id': 100,
        'current_user_id': 1,
        'created_at_micros': DateTime.now().toUtc().microsecondsSinceEpoch,
      },
    );

    await expectLater(
      migrations.migrate(
        oldBasePackage: packages.oldPackage,
        newBasePackage: packages.newPackage,
      ),
      throwsA(
        isA<WeComIncrementalMigrationException>().having(
          (error) => error.code,
          'code',
          WeComIncrementalMigrationIssueCode.activeDatasetMismatch,
        ),
      ),
    );

    expect(await migrations.currentActiveDatasetId(), otherDataset);
    expect(
        await _operationsFor(
          overlayDatabase,
          packages.newPackage.datasetId,
        ),
        isEmpty);
    expect(await _count(overlayDatabase, WeComOverlaySchema.mergeAttemptsTable),
        0);
  });
  test('rolls back revisions, attempts, and activation on commit failure',
      () async {
    final packages = await _importPackages(
      temporaryDirectory,
      importer,
      oldRows: [_user(1, name: 'Alice')],
      newRows: [_user(1, name: 'Alice', account: 'remote')],
    );
    await commands.upsert(
      datasetId: packages.oldPackage.datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 1},
      values: const {'name': 'Alicia'},
    );
    await _activate(overlayDatabase, packages.oldPackage.datasetId);
    await overlayDatabase.connection.execute(
      'CREATE TRIGGER fail_applied_merge '
      'BEFORE INSERT ON ${WeComOverlaySchema.mergeAttemptsTable} '
      "WHEN NEW.status = 'applied' "
      "BEGIN SELECT RAISE(ABORT, 'injected failure'); END",
    );

    await expectLater(
      migrations.migrate(
        oldBasePackage: packages.oldPackage,
        newBasePackage: packages.newPackage,
      ),
      throwsA(isA<DatabaseException>()),
    );

    expect(
      await migrations.currentActiveDatasetId(),
      packages.oldPackage.datasetId,
    );
    expect(await _operationsFor(overlayDatabase, packages.newPackage.datasetId),
        isEmpty);
    expect(await _count(overlayDatabase, WeComOverlaySchema.mergeAttemptsTable),
        0);
    expect(
        await _count(
            overlayDatabase, WeComOverlaySchema.datasetActivationsTable),
        1);
  });
}

Future<void> _expectAppendOnly(
  WeComOverlayDatabase overlayDatabase,
  String tableName,
  String primaryKey,
  int id,
) async {
  await expectLater(
    overlayDatabase.connection.update(
      tableName,
      {'created_at_micros': 1},
      where: '$primaryKey = ?',
      whereArgs: [id],
    ),
    throwsA(isA<DatabaseException>()),
  );
  await expectLater(
    overlayDatabase.connection.delete(
      tableName,
      where: '$primaryKey = ?',
      whereArgs: [id],
    ),
    throwsA(isA<DatabaseException>()),
  );
}

Future<List<Map<String, Object?>>> _operationsFor(
  WeComOverlayDatabase overlayDatabase,
  String datasetId,
) {
  return overlayDatabase.connection.query(
    WeComOverlaySchema.operationsTable,
    columns: [
      'database_name',
      'table_name',
      'row_key_json',
      'operation',
      'values_json',
    ],
    where: 'dataset_id = ?',
    whereArgs: [datasetId],
    orderBy: 'revision_id',
  );
}

Future<int> _count(
  WeComOverlayDatabase overlayDatabase,
  String tableName,
) async {
  final rows = await overlayDatabase.connection.rawQuery(
    'SELECT COUNT(*) AS count FROM $tableName',
  );
  return rows.single['count']! as int;
}

Future<void> _activate(
  WeComOverlayDatabase overlayDatabase,
  String datasetId,
) async {
  await overlayDatabase.connection.insert(
    WeComOverlaySchema.datasetActivationsTable,
    {
      'previous_dataset_id': null,
      'dataset_id': datasetId,
      'merge_id': null,
      'current_corp_id': 100,
      'current_user_id': 1,
      'created_at_micros': DateTime.now().toUtc().microsecondsSinceEpoch,
    },
  );
}

Future<_ImportedPackages> _importPackages(
  Directory root,
  WeComDatabasePackageImporter importer, {
  required List<Map<String, Object?>> oldRows,
  required List<Map<String, Object?>> newRows,
}) async {
  final oldSource = await Directory(p.join(root.path, 'old-source')).create();
  final newSource = await Directory(p.join(root.path, 'new-source')).create();
  await _createSource(oldSource, oldRows);
  await _createSource(newSource, newRows);
  final imports = Directory(p.join(root.path, 'imports'));
  return _ImportedPackages(
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
  final current = rows.single;
  await createIdentityDatabases(
    source,
    contactName: current['name']! as String,
    account: current['account']! as String,
  );
  final database = await databaseFactoryFfi.openDatabase(
    p.join(source.path, 'user.db'),
    options: OpenDatabaseOptions(singleInstance: false),
  );
  for (final row in rows) {
    await database.update(
      'user_table',
      row,
      where: 'id = ?',
      whereArgs: [row['id']],
    );
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
    scope: 'incremental migration test',
    databases: identityDatabaseContracts(),
  );
}

class _ImportedPackages {
  const _ImportedPackages({
    required this.oldPackage,
    required this.newPackage,
  });

  final WeComImportedPackage oldPackage;
  final WeComImportedPackage newPackage;
}
