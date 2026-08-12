import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'wecom_database_package.dart';
import 'wecom_incremental_merge_planner.dart';
import 'wecom_overlay_database.dart';
import 'wecom_overlay_schema.dart';

enum WeComIncrementalMigrationStatus {
  applied,
  conflicted,
}

enum WeComIncrementalMigrationIssueCode {
  sourceOverlayChanged,
  targetOverlayNotEmpty,
  activeDatasetMismatch,
  invalidPersistedState,
}

class WeComIncrementalMigrationException implements Exception {
  const WeComIncrementalMigrationException(
    this.code,
    this.message, {
    this.cause,
  });

  final WeComIncrementalMigrationIssueCode code;
  final String message;
  final Object? cause;

  @override
  String toString() {
    return 'WeComIncrementalMigrationException.${code.name}: $message';
  }
}

class WeComIncrementalMigrationResult {
  const WeComIncrementalMigrationResult({
    required this.mergeId,
    required this.status,
    required this.reusedExisting,
    required this.sourceRevisionCount,
    required this.firstAppliedRevisionId,
    required this.lastAppliedRevisionId,
    required this.conflictCount,
    required this.activationId,
  });

  final int mergeId;
  final WeComIncrementalMigrationStatus status;
  final bool reusedExisting;
  final int sourceRevisionCount;
  final int? firstAppliedRevisionId;
  final int? lastAppliedRevisionId;
  final int conflictCount;
  final int? activationId;

  bool get applied => status == WeComIncrementalMigrationStatus.applied;
}

class WeComPersistedMergeConflict {
  WeComPersistedMergeConflict({
    required this.conflictId,
    required this.mergeId,
    required this.kind,
    required this.databaseName,
    required this.tableName,
    required Map<String, Object?> rowKey,
    required List<int> sourceRevisionIds,
    required List<String> conflictingColumns,
    required this.oldBaseRowSha256,
    required this.newBaseRowSha256,
    required this.createdAtMicros,
  })  : rowKey = Map.unmodifiable(rowKey),
        sourceRevisionIds = List.unmodifiable(sourceRevisionIds),
        conflictingColumns = List.unmodifiable(conflictingColumns);

  final int conflictId;
  final int mergeId;
  final WeComIncrementalConflictKind kind;
  final String databaseName;
  final String tableName;
  final Map<String, Object?> rowKey;
  final List<int> sourceRevisionIds;
  final List<String> conflictingColumns;
  final String oldBaseRowSha256;
  final String newBaseRowSha256;
  final int createdAtMicros;
}

class WeComIncrementalMigrationService {
  WeComIncrementalMigrationService({
    required WeComOverlayDatabase overlayDatabase,
    required WeComIncrementalMergePlanner planner,
  })  : _overlayDatabase = overlayDatabase,
        _planner = planner;

  final WeComOverlayDatabase _overlayDatabase;
  final WeComIncrementalMergePlanner _planner;

  Future<WeComIncrementalMigrationResult> migrate({
    required WeComImportedPackage oldBasePackage,
    required WeComImportedPackage newBasePackage,
  }) async {
    final plan = await _planner.plan(
      oldBasePackage: oldBasePackage,
      newBasePackage: newBasePackage,
      overlayDatabase: _overlayDatabase,
    );
    return _overlayDatabase.connection.transaction(
      (transaction) => _persistPlan(transaction, plan),
    );
  }

  Future<String?> currentActiveDatasetId() {
    return _readActiveDataset(_overlayDatabase.connection);
  }

  Future<List<WeComPersistedMergeConflict>> listConflicts({
    int? mergeId,
  }) async {
    if (mergeId != null && mergeId < 1) {
      throw ArgumentError.value(mergeId, 'mergeId', 'Must be positive');
    }
    final rows = await _overlayDatabase.connection.query(
      WeComOverlaySchema.mergeConflictsTable,
      where: mergeId == null ? null : 'merge_id = ?',
      whereArgs: mergeId == null ? null : [mergeId],
      orderBy: 'conflict_id',
    );
    try {
      return List.unmodifiable(rows.map(_decodeConflict));
    } catch (error) {
      throw WeComIncrementalMigrationException(
        WeComIncrementalMigrationIssueCode.invalidPersistedState,
        'Persisted merge conflict metadata is malformed',
        cause: error,
      );
    }
  }

  Future<WeComIncrementalMigrationResult> _persistPlan(
    Transaction transaction,
    WeComIncrementalMergePlan plan,
  ) async {
    final sourceRevisionCount = await _operationCount(
      transaction,
      plan.oldDatasetId,
    );
    if (sourceRevisionCount != plan.sourceRevisionCount) {
      throw const WeComIncrementalMigrationException(
        WeComIncrementalMigrationIssueCode.sourceOverlayChanged,
        'Source overlay changed after the merge plan was created',
      );
    }

    final activeDatasetId = await _readActiveDataset(transaction);
    final existing = await transaction.query(
      WeComOverlaySchema.mergeAttemptsTable,
      where: 'old_dataset_id = ? AND new_dataset_id = ? '
          'AND source_revision_count = ?',
      whereArgs: [
        plan.oldDatasetId,
        plan.newDatasetId,
        plan.sourceRevisionCount,
      ],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      return _decodeExistingAttempt(
        transaction,
        existing.single,
        activeDatasetId,
        plan,
      );
    }

    if (activeDatasetId != null && activeDatasetId != plan.oldDatasetId) {
      throw WeComIncrementalMigrationException(
        WeComIncrementalMigrationIssueCode.activeDatasetMismatch,
        'Active dataset is not the merge source: $activeDatasetId',
      );
    }
    if (await _operationCount(transaction, plan.newDatasetId) != 0) {
      throw const WeComIncrementalMigrationException(
        WeComIncrementalMigrationIssueCode.targetOverlayNotEmpty,
        'Target dataset already has overlay revisions',
      );
    }

    final createdAtMicros = DateTime.now().toUtc().microsecondsSinceEpoch;
    if (activeDatasetId == null) {
      await transaction.insert(
        WeComOverlaySchema.datasetActivationsTable,
        {
          'previous_dataset_id': null,
          'dataset_id': plan.oldDatasetId,
          'merge_id': null,
          'created_at_micros': createdAtMicros,
        },
      );
    }

    if (!plan.canApply) {
      final mergeId = await _insertAttempt(
        transaction,
        plan: plan,
        status: WeComIncrementalMigrationStatus.conflicted,
        firstRevisionId: null,
        lastRevisionId: null,
        conflictCount: plan.conflicts.length,
        createdAtMicros: createdAtMicros,
      );
      for (final conflict in plan.conflicts) {
        await transaction.insert(
          WeComOverlaySchema.mergeConflictsTable,
          {
            'merge_id': mergeId,
            'database_name': conflict.databaseName,
            'table_name': conflict.tableName,
            'row_key_json': jsonEncode(conflict.rowKey),
            'kind': conflict.kind.name,
            'source_revision_ids_json': jsonEncode(conflict.sourceRevisionIds),
            'conflicting_columns_json': jsonEncode(conflict.conflictingColumns),
            'old_base_row_sha256': conflict.oldBaseRowSha256,
            'new_base_row_sha256': conflict.newBaseRowSha256,
            'created_at_micros': createdAtMicros,
          },
        );
      }
      return WeComIncrementalMigrationResult(
        mergeId: mergeId,
        status: WeComIncrementalMigrationStatus.conflicted,
        reusedExisting: false,
        sourceRevisionCount: plan.sourceRevisionCount,
        firstAppliedRevisionId: null,
        lastAppliedRevisionId: null,
        conflictCount: plan.conflicts.length,
        activationId: null,
      );
    }

    int? firstRevisionId;
    int? lastRevisionId;
    for (final operation in plan.operations) {
      final revisionId = await transaction.insert(
        WeComOverlaySchema.operationsTable,
        {
          'dataset_id': plan.newDatasetId,
          'database_name': operation.databaseName,
          'table_name': operation.tableName,
          'row_key_json': jsonEncode(operation.rowKey),
          'operation': operation.type.name,
          'values_json':
              operation.values == null ? null : jsonEncode(operation.values),
          'base_row_sha256': operation.baseRowSha256,
          'reverts_revision_id': null,
          'created_at_micros': createdAtMicros,
        },
      );
      firstRevisionId ??= revisionId;
      lastRevisionId = revisionId;
    }
    final mergeId = await _insertAttempt(
      transaction,
      plan: plan,
      status: WeComIncrementalMigrationStatus.applied,
      firstRevisionId: firstRevisionId,
      lastRevisionId: lastRevisionId,
      conflictCount: 0,
      createdAtMicros: createdAtMicros,
    );
    final activationId = await transaction.insert(
      WeComOverlaySchema.datasetActivationsTable,
      {
        'previous_dataset_id': plan.oldDatasetId,
        'dataset_id': plan.newDatasetId,
        'merge_id': mergeId,
        'created_at_micros': createdAtMicros,
      },
    );
    return WeComIncrementalMigrationResult(
      mergeId: mergeId,
      status: WeComIncrementalMigrationStatus.applied,
      reusedExisting: false,
      sourceRevisionCount: plan.sourceRevisionCount,
      firstAppliedRevisionId: firstRevisionId,
      lastAppliedRevisionId: lastRevisionId,
      conflictCount: 0,
      activationId: activationId,
    );
  }

  Future<int> _insertAttempt(
    Transaction transaction, {
    required WeComIncrementalMergePlan plan,
    required WeComIncrementalMigrationStatus status,
    required int? firstRevisionId,
    required int? lastRevisionId,
    required int conflictCount,
    required int createdAtMicros,
  }) {
    return transaction.insert(
      WeComOverlaySchema.mergeAttemptsTable,
      {
        'old_dataset_id': plan.oldDatasetId,
        'new_dataset_id': plan.newDatasetId,
        'source_revision_count': plan.sourceRevisionCount,
        'status': status.name,
        'first_applied_revision_id': firstRevisionId,
        'last_applied_revision_id': lastRevisionId,
        'conflict_count': conflictCount,
        'created_at_micros': createdAtMicros,
      },
    );
  }

  Future<WeComIncrementalMigrationResult> _decodeExistingAttempt(
    Transaction transaction,
    Map<String, Object?> row,
    String? activeDatasetId,
    WeComIncrementalMergePlan plan,
  ) async {
    try {
      final mergeId = row['merge_id'] as int;
      final status = WeComIncrementalMigrationStatus.values.byName(
        row['status']! as String,
      );
      final firstRevisionId = row['first_applied_revision_id'] as int?;
      final lastRevisionId = row['last_applied_revision_id'] as int?;
      final conflictCount = row['conflict_count'] as int;
      int? activationId;

      if (status == WeComIncrementalMigrationStatus.applied) {
        final activations = await transaction.query(
          WeComOverlaySchema.datasetActivationsTable,
          columns: [
            'activation_id',
            'previous_dataset_id',
            'dataset_id',
          ],
          where: 'merge_id = ?',
          whereArgs: [mergeId],
          limit: 1,
        );
        if (activations.length != 1 ||
            activations.single['previous_dataset_id'] != plan.oldDatasetId ||
            activations.single['dataset_id'] != plan.newDatasetId) {
          throw StateError('Applied merge activation is missing');
        }
        activationId = activations.single['activation_id']! as int;
        if (activeDatasetId != plan.newDatasetId) {
          throw WeComIncrementalMigrationException(
            WeComIncrementalMigrationIssueCode.activeDatasetMismatch,
            'Applied merge target is no longer active',
          );
        }
      } else {
        final persistedCount = Sqflite.firstIntValue(
              await transaction.rawQuery(
                'SELECT COUNT(*) FROM '
                '${WeComOverlaySchema.mergeConflictsTable} '
                'WHERE merge_id = ?',
                [mergeId],
              ),
            ) ??
            0;
        if (persistedCount != conflictCount) {
          throw StateError('Persisted conflict count does not match attempt');
        }
        if (activeDatasetId != plan.oldDatasetId) {
          throw WeComIncrementalMigrationException(
            WeComIncrementalMigrationIssueCode.activeDatasetMismatch,
            'Conflicted merge source is no longer active',
          );
        }
      }

      return WeComIncrementalMigrationResult(
        mergeId: mergeId,
        status: status,
        reusedExisting: true,
        sourceRevisionCount: plan.sourceRevisionCount,
        firstAppliedRevisionId: firstRevisionId,
        lastAppliedRevisionId: lastRevisionId,
        conflictCount: conflictCount,
        activationId: activationId,
      );
    } on WeComIncrementalMigrationException {
      rethrow;
    } catch (error) {
      throw WeComIncrementalMigrationException(
        WeComIncrementalMigrationIssueCode.invalidPersistedState,
        'Persisted merge attempt metadata is inconsistent',
        cause: error,
      );
    }
  }

  Future<int> _operationCount(
    DatabaseExecutor executor,
    String datasetId,
  ) async {
    return Sqflite.firstIntValue(
          await executor.rawQuery(
            'SELECT COUNT(*) FROM ${WeComOverlaySchema.operationsTable} '
            'WHERE dataset_id = ?',
            [datasetId],
          ),
        ) ??
        0;
  }

  Future<String?> _readActiveDataset(DatabaseExecutor executor) async {
    final rows = await executor.query(
      WeComOverlaySchema.datasetActivationsTable,
      columns: ['dataset_id'],
      orderBy: 'activation_id DESC',
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    final datasetId = rows.single['dataset_id'];
    if (datasetId is! String) {
      throw const WeComIncrementalMigrationException(
        WeComIncrementalMigrationIssueCode.invalidPersistedState,
        'Active dataset metadata is malformed',
      );
    }
    return datasetId;
  }

  WeComPersistedMergeConflict _decodeConflict(
    Map<String, Object?> row,
  ) {
    final rowKey = jsonDecode(row['row_key_json']! as String);
    final sourceRevisionIds =
        jsonDecode(row['source_revision_ids_json']! as String);
    final conflictingColumns =
        jsonDecode(row['conflicting_columns_json']! as String);
    if (rowKey is! Map ||
        sourceRevisionIds is! List ||
        !sourceRevisionIds.every((value) => value is int) ||
        conflictingColumns is! List ||
        !conflictingColumns.every((value) => value is String)) {
      throw const FormatException('Conflict JSON payload is malformed');
    }
    return WeComPersistedMergeConflict(
      conflictId: row['conflict_id']! as int,
      mergeId: row['merge_id']! as int,
      kind: WeComIncrementalConflictKind.values.byName(
        row['kind']! as String,
      ),
      databaseName: row['database_name']! as String,
      tableName: row['table_name']! as String,
      rowKey: Map<String, Object?>.from(rowKey),
      sourceRevisionIds: sourceRevisionIds.cast<int>(),
      conflictingColumns: conflictingColumns.cast<String>(),
      oldBaseRowSha256: row['old_base_row_sha256']! as String,
      newBaseRowSha256: row['new_base_row_sha256']! as String,
      createdAtMicros: row['created_at_micros']! as int,
    );
  }
}
