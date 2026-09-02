import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'wecom_database_package.dart';
import 'wecom_overlay_contract_validator.dart';
import 'wecom_overlay_database.dart';
import 'wecom_overlay_schema.dart';

class WeComOverlayMutation {
  const WeComOverlayMutation.upsert({
    required this.databaseName,
    required this.tableName,
    required this.rowKey,
    required Map<String, Object?> values,
    this.baseRowSha256,
    this.revertsRevisionId,
  })  : operation = 'upsert',
        _values = values;

  const WeComOverlayMutation.tombstone({
    required this.databaseName,
    required this.tableName,
    required this.rowKey,
    this.baseRowSha256,
    this.revertsRevisionId,
  })  : operation = 'tombstone',
        _values = null;

  final String databaseName;
  final String tableName;
  final Map<String, Object?> rowKey;
  final String operation;
  final Map<String, Object?>? _values;
  final String? baseRowSha256;
  final int? revertsRevisionId;
}

class WeComOverlayCommandService {
  WeComOverlayCommandService({
    required WeComOverlayDatabase overlayDatabase,
    required WeComPackageContract contract,
  })  : _overlayDatabase = overlayDatabase,
        _validator = WeComOverlayContractValidator(contract);

  static final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
  final WeComOverlayDatabase _overlayDatabase;
  final WeComOverlayContractValidator _validator;

  Future<int> upsert({
    required String datasetId,
    required String databaseName,
    required String tableName,
    required Map<String, Object?> rowKey,
    required Map<String, Object?> values,
    String? baseRowSha256,
    int? revertsRevisionId,
  }) async {
    final revisions = await appendBatch(
      datasetId: datasetId,
      mutations: [
        WeComOverlayMutation.upsert(
          databaseName: databaseName,
          tableName: tableName,
          rowKey: rowKey,
          values: values,
          baseRowSha256: baseRowSha256,
          revertsRevisionId: revertsRevisionId,
        ),
      ],
    );
    return revisions.single;
  }

  Future<int> tombstone({
    required String datasetId,
    required String databaseName,
    required String tableName,
    required Map<String, Object?> rowKey,
    String? baseRowSha256,
    int? revertsRevisionId,
  }) async {
    final revisions = await appendBatch(
      datasetId: datasetId,
      mutations: [
        WeComOverlayMutation.tombstone(
          databaseName: databaseName,
          tableName: tableName,
          rowKey: rowKey,
          baseRowSha256: baseRowSha256,
          revertsRevisionId: revertsRevisionId,
        ),
      ],
    );
    return revisions.single;
  }

  Future<List<int>> appendBatch({
    required String datasetId,
    required List<WeComOverlayMutation> mutations,
  }) async {
    _validateSha256(datasetId, 'datasetId');
    if (mutations.isEmpty) {
      throw ArgumentError.value(mutations, 'mutations', 'Must not be empty');
    }
    final canonicalMutations =
        mutations.map(_canonicalMutation).toList(growable: false);

    return _overlayDatabase.connection.transaction((transaction) async {
      final revisionIds = <int>[];
      for (final mutation in canonicalMutations) {
        final revertsRevisionId = mutation.revertsRevisionId;
        if (revertsRevisionId != null) {
          await _validateRevertTarget(
            transaction,
            revisionId: revertsRevisionId,
            datasetId: datasetId,
            databaseName: mutation.databaseName,
            tableName: mutation.tableName,
            rowKeyJson: mutation.rowKeyJson,
          );
        }
        revisionIds.add(
          await transaction.insert(
            WeComOverlaySchema.operationsTable,
            {
              'dataset_id': datasetId,
              'database_name': mutation.databaseName,
              'table_name': mutation.tableName,
              'row_key_json': mutation.rowKeyJson,
              'operation': mutation.operation,
              'values_json': mutation.valuesJson,
              'base_row_sha256': mutation.baseRowSha256,
              'reverts_revision_id': revertsRevisionId,
              'created_at_micros':
                  DateTime.now().toUtc().microsecondsSinceEpoch,
            },
          ),
        );
      }
      return List<int>.unmodifiable(revisionIds);
    });
  }

  _CanonicalWeComOverlayMutation _canonicalMutation(
    WeComOverlayMutation mutation,
  ) {
    final baseRowSha256 = mutation.baseRowSha256;
    if (baseRowSha256 != null) {
      _validateSha256(baseRowSha256, 'baseRowSha256');
    }
    final revertsRevisionId = mutation.revertsRevisionId;
    if (revertsRevisionId != null && revertsRevisionId < 1) {
      throw ArgumentError.value(
        revertsRevisionId,
        'revertsRevisionId',
        'Must be positive',
      );
    }

    final target = _validator.resolveTarget(
      mutation.databaseName,
      mutation.tableName,
    );
    final rowKeyJson = jsonEncode(
      _validator.canonicalRowKey(target, mutation.rowKey),
    );
    final values = mutation._values;
    final valuesJson = values == null
        ? null
        : jsonEncode(_validator.canonicalValues(target, values));
    return _CanonicalWeComOverlayMutation(
      databaseName: mutation.databaseName,
      tableName: mutation.tableName,
      rowKeyJson: rowKeyJson,
      operation: mutation.operation,
      valuesJson: valuesJson,
      baseRowSha256: baseRowSha256,
      revertsRevisionId: revertsRevisionId,
    );
  }

  Future<void> _validateRevertTarget(
    Transaction transaction, {
    required int revisionId,
    required String datasetId,
    required String databaseName,
    required String tableName,
    required String rowKeyJson,
  }) async {
    final rows = await transaction.query(
      WeComOverlaySchema.operationsTable,
      columns: [
        'dataset_id',
        'database_name',
        'table_name',
        'row_key_json',
      ],
      where: 'revision_id = ?',
      whereArgs: [revisionId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw StateError('Reverted overlay revision does not exist: $revisionId');
    }
    final row = rows.single;
    if (row['dataset_id'] != datasetId ||
        row['database_name'] != databaseName ||
        row['table_name'] != tableName ||
        row['row_key_json'] != rowKeyJson) {
      throw StateError(
        'A revert must target the same dataset, table, and row key',
      );
    }
  }

  void _validateSha256(String value, String name) {
    if (!_sha256Pattern.hasMatch(value)) {
      throw ArgumentError.value(value, name, 'Must be a lowercase SHA-256');
    }
  }
}

class _CanonicalWeComOverlayMutation {
  const _CanonicalWeComOverlayMutation({
    required this.databaseName,
    required this.tableName,
    required this.rowKeyJson,
    required this.operation,
    required this.valuesJson,
    required this.baseRowSha256,
    required this.revertsRevisionId,
  });

  final String databaseName;
  final String tableName;
  final String rowKeyJson;
  final String operation;
  final String? valuesJson;
  final String? baseRowSha256;
  final int? revertsRevisionId;
}
