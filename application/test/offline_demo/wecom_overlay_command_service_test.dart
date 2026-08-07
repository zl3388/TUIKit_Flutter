import 'dart:io';

import 'package:application/src/offline_demo/data/wecom_database_package.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_command_service.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_database.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  const datasetId =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  const baseRowSha256 =
      'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
  late Directory temporaryDirectory;
  late WeComOverlayDatabase overlayDatabase;
  late WeComOverlayCommandService service;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory =
        await Directory.systemTemp.createTemp('tui_wecom_overlay_commands_');
    overlayDatabase = await WeComOverlayDatabase.open(
      factory: databaseFactoryFfi,
      databasePath: p.join(temporaryDirectory.path, 'overlay.db'),
    );
    service = WeComOverlayCommandService(
      overlayDatabase: overlayDatabase,
      contract: _contract(),
    );
  });

  tearDown(() async {
    await overlayDatabase.close();
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('appends a canonical upsert for documented scalar fields', () async {
    final revisionId = await service.upsert(
      datasetId: datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 42},
      values: const {'level': 3, 'name': 'Updated'},
      baseRowSha256: baseRowSha256,
    );

    final row = (await overlayDatabase.connection.query(
      WeComOverlaySchema.operationsTable,
      where: 'revision_id = ?',
      whereArgs: [revisionId],
    ))
        .single;
    expect(row['database_name'], 'user.db');
    expect(row['table_name'], 'user_table');
    expect(row['row_key_json'], '{"id":42}');
    expect(row['operation'], 'upsert');
    expect(row['values_json'], '{"name":"Updated","level":3}');
    expect(row['base_row_sha256'], baseRowSha256);
    expect(row['created_at_micros'], isPositive);
  });

  test('allows a revert only for the same canonical target', () async {
    final firstRevision = await service.upsert(
      datasetId: datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 42},
      values: const {'name': 'Updated'},
    );
    final revertRevision = await service.tombstone(
      datasetId: datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 42},
      revertsRevisionId: firstRevision,
    );

    expect(revertRevision, greaterThan(firstRevision));
    await expectLater(
      service.tombstone(
        datasetId: datasetId,
        databaseName: 'user.db',
        tableName: 'user_table',
        rowKey: const {'id': 43},
        revertsRevisionId: firstRevision,
      ),
      throwsStateError,
    );
    expect(
      await overlayDatabase.connection.query(
        WeComOverlaySchema.operationsTable,
      ),
      hasLength(2),
    );
  });

  test('rejects unknown and non-addressable schema targets', () async {
    await expectLater(
      service.upsert(
        datasetId: datasetId,
        databaseName: 'missing.db',
        tableName: 'user_table',
        rowKey: const {'id': 42},
        values: const {'name': 'Updated'},
      ),
      throwsArgumentError,
    );
    await expectLater(
      service.upsert(
        datasetId: datasetId,
        databaseName: 'user.db',
        tableName: 'missing_table',
        rowKey: const {'id': 42},
        values: const {'name': 'Updated'},
      ),
      throwsArgumentError,
    );
    await expectLater(
      service.upsert(
        datasetId: datasetId,
        databaseName: 'user.db',
        tableName: 'event_log',
        rowKey: const {},
        values: const {'payload': 'event'},
      ),
      throwsUnsupportedError,
    );
    await expectLater(
      service.upsert(
        datasetId: datasetId,
        databaseName: 'crm.db',
        tableName: 'search_index_config',
        rowKey: const {'k': 'version'},
        values: const {'v': 1},
      ),
      throwsUnsupportedError,
    );
  });

  test('rejects non-contract keys, fields, and scalar types', () async {
    Future<void> expectInvalid({
      Map<String, Object?> rowKey = const {'id': 42},
      Map<String, Object?> values = const {'name': 'Updated'},
      String dataset = datasetId,
      String? digest,
    }) async {
      await expectLater(
        service.upsert(
          datasetId: dataset,
          databaseName: 'user.db',
          tableName: 'user_table',
          rowKey: rowKey,
          values: values,
          baseRowSha256: digest,
        ),
        throwsA(anyOf(isA<ArgumentError>(), isA<UnsupportedError>())),
      );
    }

    await expectInvalid(rowKey: const {});
    await expectInvalid(rowKey: const {'id': 42, 'extra': 1});
    await expectInvalid(values: const {});
    await expectInvalid(values: const {'id': 43});
    await expectInvalid(values: const {'unknown': 'value'});
    await expectInvalid(values: const {'name': 7});
    await expectInvalid(values: const {'name': null});
    await expectInvalid(values: const {'pb_content': 'opaque'});
    await expectInvalid(dataset: 'invalid');
    await expectInvalid(digest: 'invalid');
  });
}

WeComPackageContract _contract() {
  return WeComPackageContract(
    formatVersion: 1,
    scope: 'overlay command test',
    databases: [
      WeComDatabaseContract(
        fileName: 'user.db',
        allowEmpty: false,
        tables: {
          'user_table': const [
            WeComColumnContract(
              name: 'id',
              type: 'INTEGER',
              notNull: true,
              primaryKeyPosition: 1,
            ),
            WeComColumnContract(
              name: 'name',
              type: 'TEXT',
              notNull: true,
              primaryKeyPosition: 0,
            ),
            WeComColumnContract(
              name: 'level',
              type: 'INTEGER',
              notNull: false,
              primaryKeyPosition: 0,
            ),
            WeComColumnContract(
              name: 'pb_content',
              type: '',
              notNull: false,
              primaryKeyPosition: 0,
            ),
          ],
          'event_log': const [
            WeComColumnContract(
              name: 'payload',
              type: 'TEXT',
              notNull: false,
              primaryKeyPosition: 0,
            ),
          ],
        },
        indexes: const {},
      ),
      WeComDatabaseContract(
        fileName: 'crm.db',
        allowEmpty: false,
        tables: {
          'search_index': const [
            WeComColumnContract(
              name: 'content',
              type: '',
              notNull: false,
              primaryKeyPosition: 0,
            ),
          ],
          'search_index_config': const [
            WeComColumnContract(
              name: 'k',
              type: '',
              notNull: true,
              primaryKeyPosition: 1,
            ),
            WeComColumnContract(
              name: 'v',
              type: '',
              notNull: false,
              primaryKeyPosition: 0,
            ),
          ],
        },
        indexes: const {},
        skipColumnValidation: const {'search_index'},
        expectedFtsTokenizers: const {'search_index': 'unicode61'},
      ),
    ],
  );
}
