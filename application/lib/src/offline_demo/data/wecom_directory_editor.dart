import 'wecom_merged_directory_repository.dart';
import 'wecom_overlay_command_service.dart';

class WeComDirectoryEdit {
  WeComDirectoryEdit._({
    required this.revisionIds,
    required List<_ReverseDirectoryMutation> reverseMutations,
  }) : _reverseMutations = reverseMutations;

  final List<int> revisionIds;
  final List<_ReverseDirectoryMutation> _reverseMutations;
  bool _undone = false;
}

class WeComDirectoryEditor {
  const WeComDirectoryEditor({
    required this.datasetId,
    required WeComMergedDirectoryRepository directory,
    required WeComOverlayCommandService commands,
  })  : _directory = directory,
        _commands = commands;

  static const _databaseName = 'user.db';
  static const _userTable = 'user_table';
  static const _departmentTable = 'department_tableV2';
  static const _membershipTable = 'user_dept_tableV2';

  final String datasetId;
  final WeComMergedDirectoryRepository _directory;
  final WeComOverlayCommandService _commands;

  Future<WeComDirectoryEdit> updateContact({
    required int contactId,
    required String displayName,
    required String jobTitle,
    int? departmentId,
  }) async {
    final normalizedName = displayName.trim();
    final normalizedJob = jobTitle.trim();
    if (normalizedName.isEmpty) {
      throw ArgumentError.value(
          displayName, 'displayName', 'Must not be empty');
    }
    final contacts = await _directory.listAllInternalContacts();
    final contact = contacts.where((item) => item.id == contactId).firstOrNull;
    if (contact == null) {
      throw StateError('Contact does not exist: $contactId');
    }

    final forward = <WeComOverlayMutation>[];
    final reverse = <_ReverseDirectoryMutation>[];
    if (contact.displayName != normalizedName) {
      final rowKey = <String, Object?>{'id': contactId};
      forward.add(
        WeComOverlayMutation.upsert(
          databaseName: _databaseName,
          tableName: _userTable,
          rowKey: rowKey,
          values: {'real_name': normalizedName},
        ),
      );
      reverse.add(
        _ReverseDirectoryMutation(
          tableName: _userTable,
          rowKey: rowKey,
          values: {'real_name': contact.realName},
        ),
      );
    }

    if (departmentId == null) {
      if ((contact.position ?? '').trim() != normalizedJob) {
        final rowKey = <String, Object?>{'id': contactId};
        forward.add(
          WeComOverlayMutation.upsert(
            databaseName: _databaseName,
            tableName: _userTable,
            rowKey: rowKey,
            values: {'position': normalizedJob},
          ),
        );
        reverse.add(
          _ReverseDirectoryMutation(
            tableName: _userTable,
            rowKey: rowKey,
            values: {'position': contact.position},
          ),
        );
      }
    } else {
      final memberships = await _directory.listDepartmentMemberships();
      final membership = memberships
          .where(
            (item) =>
                item.departmentId == departmentId && item.userId == contactId,
          )
          .firstOrNull;
      if (membership == null) {
        throw StateError(
          'Department membership does not exist: $departmentId/$contactId',
        );
      }
      final storedJob = membership.job.trim();
      final fallbackPosition = (contact.position ?? '').trim();
      final visibleJob = storedJob.isNotEmpty ? storedJob : fallbackPosition;
      if (visibleJob != normalizedJob && storedJob != normalizedJob) {
        final rowKey = <String, Object?>{
          'department_id': departmentId,
          'user_id': contactId,
        };
        forward.add(
          WeComOverlayMutation.upsert(
            databaseName: _databaseName,
            tableName: _membershipTable,
            rowKey: rowKey,
            values: {'job': normalizedJob},
          ),
        );
        reverse.add(
          _ReverseDirectoryMutation(
            tableName: _membershipTable,
            rowKey: rowKey,
            values: {'job': membership.job},
          ),
        );
      }
      if (visibleJob != normalizedJob &&
          normalizedJob.isEmpty &&
          fallbackPosition.isNotEmpty) {
        final rowKey = <String, Object?>{'id': contactId};
        forward.add(
          WeComOverlayMutation.upsert(
            databaseName: _databaseName,
            tableName: _userTable,
            rowKey: rowKey,
            values: const {'position': ''},
          ),
        );
        reverse.add(
          _ReverseDirectoryMutation(
            tableName: _userTable,
            rowKey: rowKey,
            values: {'position': contact.position},
          ),
        );
      }
    }
    return _append(forward, reverse);
  }

  Future<WeComDirectoryEdit> renameDepartment({
    required int departmentId,
    required String name,
  }) async {
    final normalized = name.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Must not be empty');
    }
    final departments = await _directory.listDepartments();
    final department =
        departments.where((item) => item.id == departmentId).firstOrNull;
    if (department == null) {
      throw StateError('Department does not exist: $departmentId');
    }
    if (department.name == normalized) {
      throw const WeComDirectoryNoChangesException();
    }
    final rowKey = <String, Object?>{'id': departmentId};
    return _append(
      [
        WeComOverlayMutation.upsert(
          databaseName: _databaseName,
          tableName: _departmentTable,
          rowKey: rowKey,
          values: {'name': normalized},
        ),
      ],
      [
        _ReverseDirectoryMutation(
          tableName: _departmentTable,
          rowKey: rowKey,
          values: {'name': department.name},
        ),
      ],
    );
  }

  Future<void> undo(WeComDirectoryEdit edit) async {
    if (edit._undone) {
      throw StateError('This directory edit was already undone');
    }
    if (edit.revisionIds.length != edit._reverseMutations.length) {
      throw StateError('Directory edit metadata is inconsistent');
    }
    await _commands.appendBatch(
      datasetId: datasetId,
      mutations: [
        for (var index = 0; index < edit._reverseMutations.length; index++)
          edit._reverseMutations[index].toMutation(
            edit.revisionIds[index],
          ),
      ],
    );
    edit._undone = true;
  }

  Future<WeComDirectoryEdit> _append(
    List<WeComOverlayMutation> forward,
    List<_ReverseDirectoryMutation> reverse,
  ) async {
    if (forward.isEmpty) {
      throw const WeComDirectoryNoChangesException();
    }
    final revisions = await _commands.appendBatch(
      datasetId: datasetId,
      mutations: forward,
    );
    return WeComDirectoryEdit._(
      revisionIds: revisions,
      reverseMutations: reverse,
    );
  }
}

class WeComDirectoryNoChangesException implements Exception {
  const WeComDirectoryNoChangesException();
}

class _ReverseDirectoryMutation {
  const _ReverseDirectoryMutation({
    required this.tableName,
    required this.rowKey,
    required this.values,
  });

  final String tableName;
  final Map<String, Object?> rowKey;
  final Map<String, Object?> values;

  WeComOverlayMutation toMutation(int revisionId) =>
      WeComOverlayMutation.upsert(
        databaseName: WeComDirectoryEditor._databaseName,
        tableName: tableName,
        rowKey: rowKey,
        values: values,
        revertsRevisionId: revisionId,
      );
}
