import 'package:sqflite/sqflite.dart';

import '../domain/wecom_directory_models.dart';

class WeComDirectoryRepository {
  const WeComDirectoryRepository(this._database);

  static const maxPageSize = 100;

  final Database _database;

  Future<List<WeComInternalContact>> listInternalContacts({
    int limit = maxPageSize,
    int offset = 0,
  }) async {
    if (limit < 1 || limit > maxPageSize) {
      throw RangeError.range(limit, 1, maxPageSize, 'limit');
    }
    if (offset < 0) {
      throw RangeError.value(offset, 'offset', 'Must not be negative');
    }

    final rows = await _database.rawQuery(
      '''
SELECT
  id,
  real_name,
  name,
  COALESCE(
    NULLIF(real_name, ''),
    NULLIF(name, ''),
    NULLIF(account, ''),
    ''
  ) AS display_name,
  account,
  external_corp_name,
  external_job
FROM user_table
ORDER BY id
LIMIT ? OFFSET ?
''',
      [limit, offset],
    );
    return rows.map(WeComInternalContact.fromRow).toList(growable: false);
  }

  Future<List<WeComDepartment>> listDepartments() async {
    final rows = await _database.rawQuery('''
SELECT
  id,
  name,
  parent_id,
  display_order,
  corpany_id AS corporation_id
FROM department_tableV2
ORDER BY id
''');
    return rows.map(WeComDepartment.fromRow).toList(growable: false);
  }

  Future<List<WeComDepartmentMembership>> listDepartmentMemberships() async {
    final rows = await _database.rawQuery('''
SELECT
  department_id,
  user_id,
  job,
  is_main_job AS main_job_flag,
  sort AS sort_order
FROM user_dept_tableV2
ORDER BY department_id, user_id
''');
    return rows.map(WeComDepartmentMembership.fromRow).toList(growable: false);
  }
}
