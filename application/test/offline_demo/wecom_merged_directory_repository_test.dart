import 'dart:io';

import 'package:application/src/offline_demo/data/wecom_database_package.dart';
import 'package:application/src/offline_demo/data/wecom_directory_repository.dart';
import 'package:application/src/offline_demo/data/wecom_merged_directory_repository.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_command_service.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  const datasetId =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  const otherDatasetId =
      'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
  late WeComPackageContract contract;
  late Directory temporaryDirectory;
  late Database baseDatabase;
  late WeComOverlayDatabase overlayDatabase;
  late WeComOverlayCommandService commands;
  late WeComMergedDirectoryRepository repository;

  setUpAll(() async {
    sqfliteFfiInit();
    contract = WeComPackageContract.fromJsonString(
      await File(
        p.join(
          Directory.current.path,
          'assets',
          'offline_demo',
          'wecom_schema_contract.json',
        ),
      ).readAsString(),
    );
  });

  setUp(() async {
    temporaryDirectory =
        await Directory.systemTemp.createTemp('tui_wecom_merged_directory_');
    final basePath = p.join(temporaryDirectory.path, 'user.db');
    await _createBaseFixture(basePath);
    baseDatabase = await databaseFactoryFfi.openDatabase(
      basePath,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    overlayDatabase = await WeComOverlayDatabase.open(
      factory: databaseFactoryFfi,
      databasePath: p.join(temporaryDirectory.path, 'overlay.db'),
    );
    commands = WeComOverlayCommandService(
      overlayDatabase: overlayDatabase,
      contract: contract,
    );
    repository = WeComMergedDirectoryRepository(
      datasetId: datasetId,
      baseRepository: WeComDirectoryRepository(baseDatabase),
      overlayDatabase: overlayDatabase,
    );
  });

  tearDown(() async {
    await overlayDatabase.close();
    await baseDatabase.close();
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('applies ordered field patches and a reverse revision', () async {
    final firstRevision = await commands.upsert(
      datasetId: datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 1},
      values: const {
        'real_name': '',
        'name': 'Overlay name',
        'external_job': 'Overlay job',
      },
    );
    await commands.upsert(
      datasetId: datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 1},
      values: const {'account': 'overlay-account'},
    );

    var contact = (await repository.listInternalContacts()).first;
    expect(contact.displayName, 'Overlay name');
    expect(contact.realName, '');
    expect(contact.account, 'overlay-account');
    expect(contact.externalJob, 'Overlay job');

    await commands.upsert(
      datasetId: datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 1},
      values: const {
        'real_name': 'Base real',
        'name': 'Base name',
        'external_job': 'Base job',
      },
      revertsRevisionId: firstRevision,
    );

    contact = (await repository.listInternalContacts()).first;
    expect(contact.displayName, 'Base real');
    expect(contact.account, 'overlay-account');
    expect(contact.externalJob, 'Base job');
  });

  test('projects deletion, restoration, creation, sorting, and pagination',
      () async {
    final deletedRevision = await commands.tombstone(
      datasetId: datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 2},
    );
    await commands.upsert(
      datasetId: datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 2},
      values: const {'name': 'Restored'},
      revertsRevisionId: deletedRevision,
    );
    await commands.tombstone(
      datasetId: datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 3},
    );
    await commands.upsert(
      datasetId: datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 4},
      values: const {
        'name': 'Overlay only',
        'external_corp_name': 'Overlay corp',
      },
    );

    final contacts = await repository.listInternalContacts();
    expect(contacts.map((contact) => contact.id), [1, 2, 4]);
    expect(contacts[1].displayName, 'Restored');
    expect(contacts[2].displayName, 'Overlay only');
    expect(contacts[2].externalCorporationName, 'Overlay corp');

    final page = await repository.listInternalContacts(limit: 2, offset: 1);
    expect(page.map((contact) => contact.id), [2, 4]);
  });

  test('isolates datasets and preserves pagination validation', () async {
    await commands.upsert(
      datasetId: otherDatasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 1},
      values: const {'real_name': 'Other dataset'},
    );

    final contacts = await repository.listInternalContacts();
    expect(contacts.first.displayName, 'Base real');
    await expectLater(
      repository.listInternalContacts(limit: 0),
      throwsRangeError,
    );
    await expectLater(
      repository.listInternalContacts(offset: -1),
      throwsRangeError,
    );
  });
}

Future<void> _createBaseFixture(String path) async {
  final database = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 1,
      singleInstance: false,
      onCreate: (database, version) async {
        await database.execute('''
CREATE TABLE user_table (
  id INTEGER PRIMARY KEY NOT NULL,
  name TEXT NOT NULL DEFAULT '',
  account TEXT DEFAULT '',
  real_name TEXT DEFAULT '',
  external_corp_name TEXT DEFAULT '',
  external_job TEXT DEFAULT ''
)
''');
        final batch = database.batch();
        batch.insert('user_table', {
          'id': 1,
          'name': 'Base name',
          'account': 'base-account',
          'real_name': 'Base real',
          'external_corp_name': 'Base corp',
          'external_job': 'Base job',
        });
        batch.insert('user_table', {
          'id': 2,
          'name': 'Second',
          'account': 'second-account',
          'real_name': '',
        });
        batch.insert('user_table', {
          'id': 3,
          'name': 'Third',
          'account': 'third-account',
          'real_name': '',
        });
        await batch.commit(noResult: true);
      },
    ),
  );
  await database.close();
}
