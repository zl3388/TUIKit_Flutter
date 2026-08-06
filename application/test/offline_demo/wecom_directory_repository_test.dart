import 'dart:io';

import 'package:application/src/offline_demo/data/wecom_directory_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory temporaryDirectory;
  late String databasePath;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory =
        await Directory.systemTemp.createTemp('tui_wecom_directory_');
    databasePath = p.join(temporaryDirectory.path, 'user.db');
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('lists internal contacts with the approved non-empty fallback',
      () async {
    final database = await _openFixture(databasePath);
    addTearDown(database.close);
    final repository = WeComDirectoryRepository(database);

    final firstPage = await repository.listInternalContacts(limit: 2);
    final secondPage = await repository.listInternalContacts(
      limit: 2,
      offset: 2,
    );

    expect(firstPage.map((contact) => contact.id), [1, 2]);
    expect(firstPage.map((contact) => contact.displayName), [
      'Name fallback',
      'Real name',
    ]);
    expect(secondPage.map((contact) => contact.id), [3, 4]);
    expect(secondPage.map((contact) => contact.displayName), [
      'account-fallback',
      '',
    ]);
    expect(secondPage.first.account, 'account-fallback');
    expect(secondPage.last.account, isNull);
  });

  test('maps departments and raw membership values without reinterpretation',
      () async {
    final database = await _openFixture(databasePath);
    addTearDown(database.close);
    final repository = WeComDirectoryRepository(database);

    final departments = await repository.listDepartments();
    final memberships = await repository.listDepartmentMemberships();

    expect(departments.map((department) => department.id), [10, 20]);
    expect(departments.first.name, 'Root');
    expect(departments.last.parentId, 10);
    expect(departments.last.displayOrder, 900);
    expect(departments.last.corporationId, 700);

    expect(
      memberships.map(
        (membership) => [membership.departmentId, membership.userId],
      ),
      [
        [10, 2],
        [20, 1],
      ],
    );
    expect(memberships.first.job, 'Lead');
    expect(memberships.first.mainJobFlag, 1);
    expect(memberships.first.sortOrder, 8);
  });

  test('rejects pagination outside the documented query bounds', () async {
    final database = await _openFixture(databasePath);
    addTearDown(database.close);
    final repository = WeComDirectoryRepository(database);

    await expectLater(
      repository.listInternalContacts(limit: 0),
      throwsRangeError,
    );
    await expectLater(
      repository.listInternalContacts(
        limit: WeComDirectoryRepository.maxPageSize + 1,
      ),
      throwsRangeError,
    );
    await expectLater(
      repository.listInternalContacts(offset: -1),
      throwsRangeError,
    );
  });
}

Future<Database> _openFixture(String path) async {
  final writer = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
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
        await _seedFixture(database);
      },
      version: 1,
    ),
  );
  await writer.close();
  return databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      readOnly: true,
      singleInstance: false,
    ),
  );
}

Future<void> _seedFixture(Database database) async {
  final batch = database.batch();
  batch.insert('user_table', {
    'id': 3,
    'name': '',
    'account': 'account-fallback',
    'real_name': '',
  });
  batch.insert('user_table', {
    'id': 1,
    'name': 'Name fallback',
    'account': 'ignored-account',
    'real_name': '',
  });
  batch.insert('user_table', {
    'id': 4,
    'name': '',
    'account': null,
    'real_name': null,
  });
  batch.insert('user_table', {
    'id': 2,
    'name': 'Ignored name',
    'account': 'ignored-account',
    'real_name': 'Real name',
  });
  batch.insert('department_tableV2', {
    'id': 20,
    'name': 'Child',
    'parent_id': 10,
    'display_order': 900,
    'corpany_id': 700,
  });
  batch.insert('department_tableV2', {
    'id': 10,
    'name': 'Root',
    'parent_id': 0,
    'display_order': 1000,
    'corpany_id': 700,
  });
  batch.insert('user_dept_tableV2', {
    'department_id': 20,
    'user_id': 1,
    'job': 'Member',
    'is_main_job': 0,
    'sort': 9,
  });
  batch.insert('user_dept_tableV2', {
    'department_id': 10,
    'user_id': 2,
    'job': 'Lead',
    'is_main_job': 1,
    'sort': 8,
  });
  await batch.commit(noResult: true);
}
