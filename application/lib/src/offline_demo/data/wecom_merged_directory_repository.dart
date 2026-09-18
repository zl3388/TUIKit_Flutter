import 'dart:convert';

import '../domain/wecom_directory_models.dart';
import 'wecom_directory_repository.dart';
import 'wecom_identity_repository.dart';
import 'wecom_overlay_database.dart';
import 'wecom_overlay_schema.dart';

class WeComMergedDirectoryRepository {
  const WeComMergedDirectoryRepository({
    required this.datasetId,
    required this.identityScope,
    required WeComDirectoryRepository baseRepository,
    required WeComOverlayDatabase overlayDatabase,
  })  : _baseRepository = baseRepository,
        _overlayDatabase = overlayDatabase;

  static const _databaseName = 'user.db';
  static const _userTable = 'user_table';
  static const _departmentTable = 'department_tableV2';
  static const _membershipTable = 'user_dept_tableV2';

  final String datasetId;
  final WeComIdentityScope identityScope;
  final WeComDirectoryRepository _baseRepository;
  final WeComOverlayDatabase _overlayDatabase;

  Future<List<WeComDepartment>> listDepartments({
    int? corporationId,
  }) async {
    final base = await _baseRepository.listDepartments();
    final visible = <int, _DepartmentState>{
      for (final department in base)
        department.id: _DepartmentState.fromDepartment(department),
    };
    for (final operation in await _readOperations(_departmentTable)) {
      final rowKey = _decodeObject(
        operation['row_key_json']! as String,
        'row_key_json',
      );
      final id = rowKey['id'];
      if (rowKey.length != 1 || id is! int) {
        throw const FormatException(
          'Invalid department_tableV2 overlay row key',
        );
      }
      switch (operation['operation']) {
        case 'tombstone':
          visible.remove(id);
        case 'upsert':
          final valuesJson = operation['values_json'];
          if (valuesJson is! String) {
            throw const FormatException('Overlay upsert values are missing');
          }
          final state = visible[id] ?? _DepartmentState.empty(id);
          state.apply(_decodeObject(valuesJson, 'values_json'));
          visible[id] = state;
        default:
          throw FormatException(
            'Unsupported overlay operation: ${operation['operation']}',
          );
      }
    }
    final departments = visible.values
        .map((state) => state.toDepartment())
        .where(
          (department) =>
              corporationId == null ||
              department.corporationId == corporationId,
        )
        .toList(growable: false)
      ..sort((left, right) => left.id.compareTo(right.id));
    return List<WeComDepartment>.unmodifiable(departments);
  }

  Future<List<WeComDepartmentMembership>> listDepartmentMemberships() async {
    final base = await _baseRepository.listDepartmentMemberships();
    final visible = <String, _MembershipState>{
      for (final membership in base)
        _membershipKey(membership.departmentId, membership.userId):
            _MembershipState.fromMembership(membership),
    };
    for (final operation in await _readOperations(_membershipTable)) {
      final rowKey = _decodeObject(
        operation['row_key_json']! as String,
        'row_key_json',
      );
      final departmentId = rowKey['department_id'];
      final userId = rowKey['user_id'];
      if (rowKey.length != 2 || departmentId is! int || userId is! int) {
        throw const FormatException(
          'Invalid user_dept_tableV2 overlay row key',
        );
      }
      final key = _membershipKey(departmentId, userId);
      switch (operation['operation']) {
        case 'tombstone':
          visible.remove(key);
        case 'upsert':
          final valuesJson = operation['values_json'];
          if (valuesJson is! String) {
            throw const FormatException('Overlay upsert values are missing');
          }
          final state = visible[key] ??
              _MembershipState.empty(
                departmentId: departmentId,
                userId: userId,
              );
          state.apply(_decodeObject(valuesJson, 'values_json'));
          visible[key] = state;
        default:
          throw FormatException(
            'Unsupported overlay operation: ${operation['operation']}',
          );
      }
    }
    final memberships = visible.values
        .map((state) => state.toMembership())
        .toList(growable: false)
      ..sort((left, right) {
        final department = left.departmentId.compareTo(right.departmentId);
        return department != 0
            ? department
            : left.userId.compareTo(right.userId);
      });
    return List<WeComDepartmentMembership>.unmodifiable(memberships);
  }

  Future<List<WeComInternalContact>> listInternalContacts({
    int limit = WeComDirectoryRepository.maxPageSize,
    int offset = 0,
  }) async {
    if (limit < 1 || limit > WeComDirectoryRepository.maxPageSize) {
      throw RangeError.range(
        limit,
        1,
        WeComDirectoryRepository.maxPageSize,
        'limit',
      );
    }
    if (offset < 0) {
      throw RangeError.value(offset, 'offset', 'Must not be negative');
    }

    final contacts = await listAllInternalContacts();
    if (offset >= contacts.length) {
      return const [];
    }
    final requestedEnd = offset + limit;
    final end = requestedEnd < contacts.length ? requestedEnd : contacts.length;
    return List<WeComInternalContact>.unmodifiable(
      contacts.sublist(offset, end),
    );
  }

  Future<List<WeComInternalContact>> listAllInternalContacts() async {
    final baseContacts = await _readAllBaseContacts();
    final baseById = <int, WeComInternalContact>{
      for (final contact in baseContacts) contact.id: contact,
    };
    final visible = <int, _ContactState>{
      for (final contact in baseContacts)
        contact.id: _ContactState.fromContact(contact),
    };
    final operations = await _readOperations(_userTable);

    for (final operation in operations) {
      final rowKey = _decodeObject(
        operation['row_key_json']! as String,
        'row_key_json',
      );
      final id = rowKey['id'];
      if (rowKey.length != 1 || id is! int) {
        throw const FormatException('Invalid user_table overlay row key');
      }

      switch (operation['operation']) {
        case 'tombstone':
          visible.remove(id);
        case 'upsert':
          final valuesJson = operation['values_json'];
          if (valuesJson is! String) {
            throw const FormatException('Overlay upsert values are missing');
          }
          final state = visible[id] ??
              (baseById[id] == null
                  ? _ContactState.empty(id)
                  : _ContactState.fromContact(baseById[id]!));
          state.apply(_decodeObject(valuesJson, 'values_json'));
          visible[id] = state;
        default:
          throw FormatException(
            'Unsupported overlay operation: ${operation['operation']}',
          );
      }
    }

    final contacts = visible.values
        .map((state) => state.toContact())
        .toList(growable: false)
      ..sort((left, right) => left.id.compareTo(right.id));
    return List<WeComInternalContact>.unmodifiable(contacts);
  }

  Future<List<WeComInternalContact>> _readAllBaseContacts() async {
    final contacts = <WeComInternalContact>[];
    var offset = 0;
    while (true) {
      final page = await _baseRepository.listInternalContacts(offset: offset);
      contacts.addAll(page);
      if (page.length < WeComDirectoryRepository.maxPageSize) {
        return contacts;
      }
      offset += page.length;
    }
  }

  Future<List<Map<String, Object?>>> _readOperations(String tableName) {
    return _overlayDatabase.connection.query(
      WeComOverlaySchema.operationsTable,
      columns: ['row_key_json', 'operation', 'values_json'],
      where: 'dataset_id = ? AND identity_corp_id = ? '
          'AND identity_user_id = ? AND database_name = ? AND table_name = ?',
      whereArgs: [
        datasetId,
        identityScope.corporationId,
        identityScope.userId,
        _databaseName,
        tableName,
      ],
      orderBy: 'revision_id',
    );
  }

  static String _membershipKey(int departmentId, int userId) =>
      '$departmentId:$userId';

  Map<String, Object?> _decodeObject(String source, String fieldName) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw FormatException('$fieldName must be a JSON object');
    }
    return Map<String, Object?>.from(decoded);
  }
}

class _DepartmentState {
  _DepartmentState({
    required this.id,
    required this.name,
    required this.parentId,
    required this.displayOrder,
    required this.corporationId,
  });

  factory _DepartmentState.fromDepartment(WeComDepartment department) =>
      _DepartmentState(
        id: department.id,
        name: department.name,
        parentId: department.parentId,
        displayOrder: department.displayOrder,
        corporationId: department.corporationId,
      );

  factory _DepartmentState.empty(int id) => _DepartmentState(
        id: id,
        name: '',
        parentId: 0,
        displayOrder: 0,
        corporationId: 0,
      );

  final int id;
  String name;
  int parentId;
  int displayOrder;
  int corporationId;

  void apply(Map<String, Object?> values) {
    if (values.containsKey('name')) {
      name = _ContactState._requiredString(values['name'], 'name');
    }
    if (values.containsKey('parent_id')) {
      parentId = _requiredInt(values['parent_id'], 'parent_id');
    }
    if (values.containsKey('display_order')) {
      displayOrder = _requiredInt(values['display_order'], 'display_order');
    }
    if (values.containsKey('corpany_id')) {
      corporationId = _requiredInt(values['corpany_id'], 'corpany_id');
    }
  }

  WeComDepartment toDepartment() => WeComDepartment(
        id: id,
        name: name,
        parentId: parentId,
        displayOrder: displayOrder,
        corporationId: corporationId,
      );
}

class _MembershipState {
  _MembershipState({
    required this.departmentId,
    required this.userId,
    required this.job,
    required this.mainJobFlag,
    required this.sortOrder,
  });

  factory _MembershipState.fromMembership(
    WeComDepartmentMembership membership,
  ) =>
      _MembershipState(
        departmentId: membership.departmentId,
        userId: membership.userId,
        job: membership.job,
        mainJobFlag: membership.mainJobFlag,
        sortOrder: membership.sortOrder,
      );

  factory _MembershipState.empty({
    required int departmentId,
    required int userId,
  }) =>
      _MembershipState(
        departmentId: departmentId,
        userId: userId,
        job: '',
        mainJobFlag: 0,
        sortOrder: 0,
      );

  final int departmentId;
  final int userId;
  String job;
  int mainJobFlag;
  int sortOrder;

  void apply(Map<String, Object?> values) {
    if (values.containsKey('job')) {
      job = _ContactState._requiredString(values['job'], 'job');
    }
    if (values.containsKey('is_main_job')) {
      mainJobFlag = _requiredInt(values['is_main_job'], 'is_main_job');
    }
    if (values.containsKey('sort')) {
      sortOrder = _requiredInt(values['sort'], 'sort');
    }
  }

  WeComDepartmentMembership toMembership() => WeComDepartmentMembership(
        departmentId: departmentId,
        userId: userId,
        job: job,
        mainJobFlag: mainJobFlag,
        sortOrder: sortOrder,
      );
}

int _requiredInt(Object? value, String fieldName) {
  if (value is! int) {
    throw FormatException('$fieldName must be an integer');
  }
  return value;
}

class _ContactState {
  _ContactState({
    required this.id,
    required this.name,
    this.realName,
    this.account,
    this.position,
    this.externalCorporationName,
    this.externalJob,
  });

  factory _ContactState.fromContact(WeComInternalContact contact) {
    return _ContactState(
      id: contact.id,
      name: contact.name,
      realName: contact.realName,
      account: contact.account,
      position: contact.position,
      externalCorporationName: contact.externalCorporationName,
      externalJob: contact.externalJob,
    );
  }

  factory _ContactState.empty(int id) {
    return _ContactState(
      id: id,
      name: '',
      realName: '',
      account: '',
      position: '',
      externalCorporationName: '',
      externalJob: '',
    );
  }

  final int id;
  String name;
  String? realName;
  String? account;
  String? position;
  String? externalCorporationName;
  String? externalJob;

  void apply(Map<String, Object?> values) {
    if (values.containsKey('name')) {
      name = _requiredString(values['name'], 'name');
    }
    if (values.containsKey('real_name')) {
      realName = _nullableString(values['real_name'], 'real_name');
    }
    if (values.containsKey('account')) {
      account = _nullableString(values['account'], 'account');
    }
    if (values.containsKey('position')) {
      position = _nullableString(values['position'], 'position');
    }
    if (values.containsKey('external_corp_name')) {
      externalCorporationName = _nullableString(
        values['external_corp_name'],
        'external_corp_name',
      );
    }
    if (values.containsKey('external_job')) {
      externalJob = _nullableString(values['external_job'], 'external_job');
    }
  }

  WeComInternalContact toContact() {
    return WeComInternalContact.fromFields(
      id: id,
      name: name,
      realName: realName,
      account: account,
      position: position,
      externalCorporationName: externalCorporationName,
      externalJob: externalJob,
    );
  }

  static String _requiredString(Object? value, String fieldName) {
    if (value is! String) {
      throw FormatException('$fieldName must be a string');
    }
    return value;
  }

  static String? _nullableString(Object? value, String fieldName) {
    if (value != null && value is! String) {
      throw FormatException('$fieldName must be a nullable string');
    }
    return value as String?;
  }
}
