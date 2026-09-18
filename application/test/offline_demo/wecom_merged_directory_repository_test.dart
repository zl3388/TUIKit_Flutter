import 'dart:io';

import 'package:application/src/offline_demo/data/wecom_contact_repository.dart';
import 'package:application/src/offline_demo/data/wecom_database_package.dart';
import 'package:application/src/offline_demo/data/wecom_directory_editor.dart';
import 'package:application/src/offline_demo/data/wecom_directory_repository.dart';
import 'package:application/src/offline_demo/data/wecom_identity_repository.dart';
import 'package:application/src/offline_demo/data/wecom_merged_directory_repository.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_command_service.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_database.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_schema.dart';
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
  late WeComDirectoryEditor editor;
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
      identityScope: const WeComIdentityScope(
        corporationId: 700,
        userId: 1,
      ),
    );
    repository = WeComMergedDirectoryRepository(
      datasetId: datasetId,
      identityScope: const WeComIdentityScope(
        corporationId: 700,
        userId: 1,
      ),
      baseRepository: WeComDirectoryRepository(baseDatabase),
      overlayDatabase: overlayDatabase,
    );
    editor = WeComDirectoryEditor(
      datasetId: datasetId,
      directory: repository,
      commands: commands,
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
    final allContacts = await repository.listAllInternalContacts();
    expect(allContacts.map((contact) => contact.id), [1, 2, 4]);
    expect(
      allContacts.map((contact) => contact.displayName),
      ['Base real', 'Restored', 'Overlay only'],
    );

    final viewContacts = await WeComContactRepository(
      repository,
      currentCorporationId: 700,
    ).listContacts();
    expect(viewContacts.map((contact) => contact.id), ['1', '2', '4']);
    expect(viewContacts[2].organizationName, 'Overlay corp');
    expect(viewContacts[2].account, isNull);

    final page = await repository.listInternalContacts(limit: 2, offset: 1);
    expect(page.map((contact) => contact.id), [2, 4]);
  });

  test('projects the current corporation organization and primary membership',
      () async {
    final contacts = WeComContactRepository(
      repository,
      currentCorporationId: 700,
    );

    final units = await contacts.listOrganizationUnits();
    expect(units.map((unit) => unit.id), ['20', '10']);
    expect(units.first.parentId, '10');
    expect(units.last.parentId, isNull);

    final childContacts = await contacts.listContacts(
      organizationUnitId: '20',
    );
    expect(childContacts.map((contact) => contact.id), ['1']);
    expect(childContacts.single.organizationUnitId, '10');
    expect(childContacts.single.departmentName, 'Root');
    expect(childContacts.single.jobTitle, 'Legacy position');

    final rootContacts = await contacts.listContacts(
      organizationUnitId: '10',
    );
    expect(rootContacts.map((contact) => contact.id), ['1', '2']);
    expect(rootContacts.last.organizationUnitId, '10');
    expect(rootContacts.last.departmentName, 'Root');
    expect(rootContacts.last.jobTitle, 'Lead');
  });

  test('edits a contact and its composite-key membership then undoes it',
      () async {
    final edit = await editor.updateContact(
      contactId: 2,
      displayName: 'Renamed second',
      jobTitle: 'Director',
      departmentId: 10,
    );

    final projected = await WeComContactRepository(
      repository,
      currentCorporationId: 700,
    ).listContacts(organizationUnitId: '10');
    final contact = projected.singleWhere((item) => item.id == '2');
    expect(contact.displayName, 'Renamed second');
    expect(contact.jobTitle, 'Director');

    final baseContact = await baseDatabase.query(
      'user_table',
      columns: ['real_name'],
      where: 'id = ?',
      whereArgs: [2],
    );
    final baseMembership = await baseDatabase.query(
      'user_dept_tableV2',
      columns: ['job'],
      where: 'department_id = ? AND user_id = ?',
      whereArgs: [10, 2],
    );
    expect(baseContact.single['real_name'], '');
    expect(baseMembership.single['job'], 'Lead');

    final reopenedRepository = WeComMergedDirectoryRepository(
      datasetId: datasetId,
      identityScope: const WeComIdentityScope(
        corporationId: 700,
        userId: 1,
      ),
      baseRepository: WeComDirectoryRepository(baseDatabase),
      overlayDatabase: overlayDatabase,
    );
    final reopenedContact = (await WeComContactRepository(
      reopenedRepository,
      currentCorporationId: 700,
    ).listContacts(organizationUnitId: '10'))
        .singleWhere((item) => item.id == '2');
    expect(reopenedContact.displayName, 'Renamed second');
    expect(reopenedContact.jobTitle, 'Director');

    await editor.undo(edit);
    final restored = await WeComContactRepository(
      repository,
      currentCorporationId: 700,
    ).listContacts(organizationUnitId: '10');
    final restoredContact = restored.singleWhere((item) => item.id == '2');
    expect(restoredContact.displayName, 'Second');
    expect(restoredContact.jobTitle, 'Lead');
    await expectLater(editor.undo(edit), throwsStateError);

    final operations = await overlayDatabase.connection.query(
      WeComOverlaySchema.operationsTable,
      columns: [
        'revision_id',
        'table_name',
        'row_key_json',
        'reverts_revision_id'
      ],
      orderBy: 'revision_id',
    );
    expect(operations, hasLength(4));
    expect(operations[1]['table_name'], 'user_dept_tableV2');
    expect(
      operations[1]['row_key_json'],
      '{"department_id":10,"user_id":2}',
    );
    expect(operations[2]['reverts_revision_id'], operations[0]['revision_id']);
    expect(operations[3]['reverts_revision_id'], operations[1]['revision_id']);
  });

  test('uses the contact position when no department membership exists',
      () async {
    final edit = await editor.updateContact(
      contactId: 3,
      displayName: 'Third renamed',
      jobTitle: 'Analyst',
    );

    var contact = (await repository.listAllInternalContacts())
        .singleWhere((item) => item.id == 3);
    expect(contact.displayName, 'Third renamed');
    expect(contact.position, 'Analyst');

    await editor.undo(edit);
    contact = (await repository.listAllInternalContacts())
        .singleWhere((item) => item.id == 3);
    expect(contact.displayName, 'Third');
    expect(contact.position, '');
  });

  test('does not materialize unchanged display fallbacks into overlay',
      () async {
    await expectLater(
      editor.updateContact(
        contactId: 1,
        displayName: 'Base real',
        jobTitle: 'Legacy position',
        departmentId: 10,
      ),
      throwsA(isA<WeComDirectoryNoChangesException>()),
    );
    await expectLater(
      editor.updateContact(
        contactId: 2,
        displayName: 'Second',
        jobTitle: 'Lead',
        departmentId: 10,
      ),
      throwsA(isA<WeComDirectoryNoChangesException>()),
    );
    expect(
      await overlayDatabase.connection.query(
        WeComOverlaySchema.operationsTable,
      ),
      isEmpty,
    );
  });

  test('clears the legacy position fallback and can undo the change', () async {
    final edit = await editor.updateContact(
      contactId: 1,
      displayName: 'Base real',
      jobTitle: '',
      departmentId: 10,
    );

    var contact = (await WeComContactRepository(
      repository,
      currentCorporationId: 700,
    ).listContacts(organizationUnitId: '10'))
        .singleWhere((item) => item.id == '1');
    expect(contact.jobTitle, isNull);
    expect(edit.revisionIds, hasLength(1));

    await editor.undo(edit);
    contact = (await WeComContactRepository(
      repository,
      currentCorporationId: 700,
    ).listContacts(organizationUnitId: '10'))
        .singleWhere((item) => item.id == '1');
    expect(contact.jobTitle, 'Legacy position');
  });

  test('renames a department within one identity scope and undoes it',
      () async {
    final otherIdentityRepository = WeComMergedDirectoryRepository(
      datasetId: datasetId,
      identityScope: const WeComIdentityScope(
        corporationId: 701,
        userId: 2,
      ),
      baseRepository: WeComDirectoryRepository(baseDatabase),
      overlayDatabase: overlayDatabase,
    );

    final edit = await editor.renameDepartment(
      departmentId: 10,
      name: 'Renamed root',
    );
    expect(
      (await repository.listDepartments())
          .singleWhere((item) => item.id == 10)
          .name,
      'Renamed root',
    );
    expect(
      (await otherIdentityRepository.listDepartments())
          .singleWhere((item) => item.id == 10)
          .name,
      'Root',
    );
    final baseDepartment = await baseDatabase.query(
      'department_tableV2',
      columns: ['name'],
      where: 'id = ?',
      whereArgs: [10],
    );
    expect(baseDepartment.single['name'], 'Root');

    await editor.undo(edit);
    expect(
      (await repository.listDepartments())
          .singleWhere((item) => item.id == 10)
          .name,
      'Root',
    );
  });

  test('isolates datasets and preserves pagination validation', () async {
    await commands.upsert(
      datasetId: otherDatasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 1},
      values: const {'real_name': 'Other dataset'},
    );
    final otherIdentity = WeComOverlayCommandService(
      overlayDatabase: overlayDatabase,
      contract: contract,
      identityScope: const WeComIdentityScope(
        corporationId: 701,
        userId: 2,
      ),
    );
    await otherIdentity.upsert(
      datasetId: datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 1},
      values: const {'real_name': 'Other identity'},
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
  external_job TEXT DEFAULT '',
  position TEXT DEFAULT ''
)
''');
        await database.execute('''
CREATE TABLE department_tableV2 (
  id INTEGER PRIMARY KEY NOT NULL,
  name TEXT NOT NULL DEFAULT '',
  parent_id INTEGER NOT NULL DEFAULT 0,
  display_order INTEGER NOT NULL DEFAULT 0,
  corpany_id INTEGER NOT NULL DEFAULT 0
)
''');
        await database.execute('''
CREATE TABLE user_dept_tableV2 (
  department_id INTEGER NOT NULL DEFAULT 0,
  user_id INTEGER NOT NULL DEFAULT 0,
  job TEXT NOT NULL DEFAULT '',
  is_main_job INTEGER NOT NULL DEFAULT 0,
  sort INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (department_id, user_id)
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
          'position': 'Legacy position',
        });
        batch.insert('user_table', {
          'id': 2,
          'name': 'Second',
          'account': 'second-account',
          'real_name': '',
        });
        batch.insert('department_tableV2', {
          'id': 10,
          'name': 'Root',
          'parent_id': 0,
          'display_order': 1000,
          'corpany_id': 700,
        });
        batch.insert('department_tableV2', {
          'id': 20,
          'name': 'Child',
          'parent_id': 10,
          'display_order': 900,
          'corpany_id': 700,
        });
        batch.insert('department_tableV2', {
          'id': 30,
          'name': 'Other corporation',
          'parent_id': 0,
          'display_order': 1,
          'corpany_id': 800,
        });
        batch.insert('user_dept_tableV2', {
          'department_id': 20,
          'user_id': 1,
          'job': 'Member job',
          'is_main_job': 0,
          'sort': 9,
        });
        batch.insert('user_dept_tableV2', {
          'department_id': 10,
          'user_id': 1,
          'job': '',
          'is_main_job': 1,
          'sort': 10,
        });
        batch.insert('user_dept_tableV2', {
          'department_id': 10,
          'user_id': 2,
          'job': 'Lead',
          'is_main_job': 1,
          'sort': 8,
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
