import 'dart:io';
import 'dart:typed_data';

import 'package:application/src/offline_demo/data/wecom_database_package.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const testCorporationId = 100;
const testCurrentUserId = 1;

List<WeComDatabaseContract> identityDatabaseContracts() {
  return [
    WeComDatabaseContract(
      fileName: 'company.db',
      allowEmpty: false,
      tables: {
        'self_corp_list_table': [
          testColumn('corpany_id', 'INTEGER', primaryKeyPosition: 1),
          testColumn('self_corp_info', '', notNull: true),
        ],
      },
      indexes: const {},
    ),
    WeComDatabaseContract(
      fileName: 'user.db',
      allowEmpty: false,
      tables: {
        'user_table': [
          testColumn(
            'id',
            'INTEGER',
            notNull: true,
            primaryKeyPosition: 1,
          ),
          testColumn('real_name', 'TEXT', notNull: true),
          testColumn('name', 'TEXT', notNull: true),
          testColumn('account', 'TEXT', notNull: true),
          testColumn('external_corp_name', 'TEXT', notNull: true),
          testColumn('external_job', 'TEXT', notNull: true),
          testColumn('corp_id', 'INTEGER', notNull: true),
          testColumn('mobile', 'TEXT', notNull: true),
          testColumn('phone', 'TEXT', notNull: true),
          testColumn('office_phone', 'TEXT', notNull: true),
          testColumn('email', 'TEXT', notNull: true),
          testColumn('position', 'TEXT', notNull: true),
          testColumn('pb_content', ''),
        ],
        'department_tableV2': [
          testColumn(
            'id',
            'INTEGER',
            notNull: true,
            primaryKeyPosition: 1,
          ),
          testColumn('name', 'TEXT', notNull: true),
          testColumn('parent_id', 'INTEGER', notNull: true),
          testColumn('display_order', 'INTEGER', notNull: true),
          testColumn('corpany_id', 'INTEGER', notNull: true),
        ],
        'user_dept_tableV2': [
          testColumn(
            'department_id',
            'INTEGER',
            notNull: true,
            primaryKeyPosition: 1,
          ),
          testColumn(
            'user_id',
            'INTEGER',
            notNull: true,
            primaryKeyPosition: 2,
          ),
          testColumn('job', 'TEXT', notNull: true),
          testColumn('is_main_job', 'INTEGER', notNull: true),
          testColumn('sort', 'INTEGER', notNull: true),
        ],
      },
      indexes: const {},
    ),
  ];
}

Future<void> createIdentityDatabases(
  Directory source, {
  required String contactName,
  String account = 'contact.account',
  String externalCorporationName = 'External Corp',
  String externalJob = 'External Job',
}) async {
  final company = await databaseFactoryFfi.openDatabase(
    p.join(source.path, 'company.db'),
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await company.execute(
    'CREATE TABLE self_corp_list_table ('
    'corpany_id INTEGER PRIMARY KEY, '
    'self_corp_info NOT NULL'
    ')',
  );
  await company.insert(
    'self_corp_list_table',
    {
      'corpany_id': testCorporationId,
      'self_corp_info': Uint8List.fromList(
        encodeSelfCorporation(
          corporationId: testCorporationId,
          userId: testCurrentUserId,
          shortName: 'Example',
          fullName: 'Example Corporation',
        ),
      ),
    },
  );
  await company.close();

  final user = await databaseFactoryFfi.openDatabase(
    p.join(source.path, 'user.db'),
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await user.execute(
    'CREATE TABLE user_table ('
    'id INTEGER PRIMARY KEY NOT NULL, '
    "real_name TEXT NOT NULL DEFAULT '', "
    "name TEXT NOT NULL DEFAULT '', "
    "account TEXT NOT NULL DEFAULT '', "
    "external_corp_name TEXT NOT NULL DEFAULT '', "
    "external_job TEXT NOT NULL DEFAULT '', "
    'corp_id INTEGER NOT NULL DEFAULT 0, '
    "mobile TEXT NOT NULL DEFAULT '', "
    "phone TEXT NOT NULL DEFAULT '', "
    "office_phone TEXT NOT NULL DEFAULT '', "
    "email TEXT NOT NULL DEFAULT '', "
    "position TEXT NOT NULL DEFAULT '', "
    'pb_content'
    ')',
  );
  await user.execute(
    'CREATE TABLE department_tableV2 ('
    'id INTEGER PRIMARY KEY NOT NULL, '
    "name TEXT NOT NULL DEFAULT '', "
    'parent_id INTEGER NOT NULL DEFAULT 0, '
    'display_order INTEGER NOT NULL DEFAULT 0, '
    'corpany_id INTEGER NOT NULL DEFAULT 0'
    ')',
  );
  await user.execute(
    'CREATE TABLE user_dept_tableV2 ('
    'department_id INTEGER NOT NULL, '
    'user_id INTEGER NOT NULL, '
    "job TEXT NOT NULL DEFAULT '', "
    'is_main_job INTEGER NOT NULL DEFAULT 0, '
    'sort INTEGER NOT NULL DEFAULT 0, '
    'PRIMARY KEY (department_id, user_id)'
    ')',
  );
  await user.insert(
    'user_table',
    {
      'id': testCurrentUserId,
      'name': contactName,
      'account': account,
      'external_corp_name': externalCorporationName,
      'external_job': externalJob,
      'corp_id': testCorporationId,
      'mobile': '13800000000',
      'email': 'current@example.test',
      'pb_content': Uint8List.fromList(
        encodeUserProfile(
          shortAccount: 'current',
          officePhone: '010-12345678',
        ),
      ),
    },
  );
  await user.insert('department_tableV2', {
    'id': 10,
    'name': 'Engineering',
    'parent_id': 0,
    'display_order': 1,
    'corpany_id': testCorporationId,
  });
  await user.insert(
    'user_dept_tableV2',
    {
      'department_id': 10,
      'user_id': testCurrentUserId,
      'job': 'Developer',
      'is_main_job': 1,
      'sort': 1,
    },
  );
  await user.close();
}

Future<void> addIdentityCandidate(
  Directory source, {
  required int corporationId,
  required int userId,
  required String name,
}) async {
  final company = await databaseFactoryFfi.openDatabase(
    p.join(source.path, 'company.db'),
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await company.insert(
    'self_corp_list_table',
    {
      'corpany_id': corporationId,
      'self_corp_info': Uint8List.fromList(
        encodeSelfCorporation(
          corporationId: corporationId,
          userId: userId,
          shortName: '$name Short',
          fullName: '$name Corporation',
        ),
      ),
    },
  );
  await company.close();

  final user = await databaseFactoryFfi.openDatabase(
    p.join(source.path, 'user.db'),
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await user.insert(
    'user_table',
    {
      'id': userId,
      'name': name,
      'account': '$name.account',
      'corp_id': corporationId,
    },
  );
  await user.close();
}

List<int> encodeSelfCorporation({
  required int corporationId,
  required int userId,
  required String shortName,
  required String fullName,
}) {
  return [
    ..._varintField(1, corporationId),
    ..._varintField(2, userId),
    ..._stringField(3, shortName),
    ..._stringField(24, fullName),
  ];
}

List<int> encodeUserProfile({
  required String shortAccount,
  required String officePhone,
}) {
  return [
    ..._stringField(6, officePhone),
    ..._stringField(32, shortAccount),
  ];
}

WeComColumnContract testColumn(
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

List<int> _varintField(int fieldNumber, int value) {
  return [..._varint(fieldNumber << 3), ..._varint(value)];
}

List<int> _stringField(int fieldNumber, String value) {
  final bytes = value.codeUnits;
  return [
    ..._varint((fieldNumber << 3) | 2),
    ..._varint(bytes.length),
    ...bytes,
  ];
}

List<int> _varint(int value) {
  final bytes = <int>[];
  var remaining = value;
  do {
    var byte = remaining & 0x7f;
    remaining >>= 7;
    if (remaining != 0) {
      byte |= 0x80;
    }
    bytes.add(byte);
  } while (remaining != 0);
  return bytes;
}
