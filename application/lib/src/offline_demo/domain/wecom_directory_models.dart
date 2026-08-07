class WeComInternalContact {
  const WeComInternalContact({
    required this.id,
    required this.displayName,
    required this.name,
    this.realName,
    this.account,
    this.externalCorporationName,
    this.externalJob,
  });

  final int id;
  final String displayName;
  final String name;
  final String? realName;
  final String? account;
  final String? externalCorporationName;
  final String? externalJob;

  factory WeComInternalContact.fromRow(Map<String, Object?> row) {
    return WeComInternalContact(
      id: row['id']! as int,
      displayName: row['display_name']! as String,
      name: row['name']! as String,
      realName: row['real_name'] as String?,
      account: row['account'] as String?,
      externalCorporationName: row['external_corp_name'] as String?,
      externalJob: row['external_job'] as String?,
    );
  }

  factory WeComInternalContact.fromFields({
    required int id,
    required String name,
    String? realName,
    String? account,
    String? externalCorporationName,
    String? externalJob,
  }) {
    return WeComInternalContact(
      id: id,
      displayName: _firstNonEmpty([realName, name, account]),
      name: name,
      realName: realName,
      account: account,
      externalCorporationName: externalCorporationName,
      externalJob: externalJob,
    );
  }

  static String _firstNonEmpty(Iterable<String?> values) {
    for (final value in values) {
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
    return '';
  }
}

class WeComDepartment {
  const WeComDepartment({
    required this.id,
    required this.name,
    required this.parentId,
    required this.displayOrder,
    required this.corporationId,
  });

  final int id;
  final String name;
  final int parentId;
  final int displayOrder;
  final int corporationId;

  factory WeComDepartment.fromRow(Map<String, Object?> row) {
    return WeComDepartment(
      id: row['id']! as int,
      name: row['name']! as String,
      parentId: row['parent_id']! as int,
      displayOrder: row['display_order']! as int,
      corporationId: row['corporation_id']! as int,
    );
  }
}

class WeComDepartmentMembership {
  const WeComDepartmentMembership({
    required this.departmentId,
    required this.userId,
    required this.job,
    required this.mainJobFlag,
    required this.sortOrder,
  });

  final int departmentId;
  final int userId;
  final String job;
  final int mainJobFlag;
  final int sortOrder;

  factory WeComDepartmentMembership.fromRow(Map<String, Object?> row) {
    return WeComDepartmentMembership(
      departmentId: row['department_id']! as int,
      userId: row['user_id']! as int,
      job: row['job']! as String,
      mainJobFlag: row['main_job_flag']! as int,
      sortOrder: row['sort_order']! as int,
    );
  }
}
