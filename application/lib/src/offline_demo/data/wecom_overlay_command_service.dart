import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'wecom_database_package.dart';
import 'wecom_overlay_contract_validator.dart';
import 'wecom_overlay_database.dart';
import 'wecom_overlay_schema.dart';

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
  }) {
    return _append(
      datasetId: datasetId,
      databaseName: databaseName,
      tableName: tableName,
      rowKey: rowKey,
      operation: 'upsert',
      values: values,
      baseRowSha256: baseRowSha256,
      revertsRevisionId: revertsRevisionId,
    );
  }

  Future<int> tombstone({
    required String datasetId,
    required String databaseName,
    required String tableName,
    required Map<String, Object?> rowKey,
    String? baseRowSha256,
    int? revertsRevisionId,
  }) {
    return _append(
      datasetId: datasetId,
      databaseName: databaseName,
      tableName: tableName,
      rowKey: rowKey,
      operation: 'tombstone',
      baseRowSha256: baseRowSha256,
      revertsRevisionId: revertsRevisionId,
    );
  }

  Future<int> _append({
    required String datasetId,
    required String databaseName,
    required String tableName,
    required Map<String, Object?> rowKey,
    required String operation,
    Map<String, Object?>? values,
    String? baseRowSha256,
    int? revertsRevisionId,
  }) async {
    _validateSha256(datasetId, 'datasetId');
    if (baseRowSha256 != null) {
      _validateSha256(baseRowSha256, 'baseRowSha256');
    }
    if (revertsRevisionId != null && revertsRevisionId < 1) {
      throw ArgumentError.value(
        revertsRevisionId,
        'revertsRevisionId',
        'Must be positive',
      );
    }

    final target = _validator.resolveTarget(databaseName, tableName);
    final rowKeyJson = jsonEncode(_validator.canonicalRowKey(target, rowKey));
    final valuesJson = values == null
        ? null
        : jsonEncode(_validator.canonicalValues(target, values));

    return _overlayDatabase.connection.transaction((transaction) async {
      if (revertsRevisionId != null) {
        await _validateRevertTarget(
          transaction,
          revisionId: revertsRevisionId,
          datasetId: datasetId,
          databaseName: databaseName,
          tableName: tableName,
          rowKeyJson: rowKeyJson,
        );
      }
      return transaction.insert(
        WeComOverlaySchema.operationsTable,
        {
          'dataset_id': datasetId,
          'database_name': databaseName,
          'table_name': tableName,
          'row_key_json': rowKeyJson,
          'operation': operation,
          'values_json': valuesJson,
          'base_row_sha256': baseRowSha256,
          'reverts_revision_id': revertsRevisionId,
          'created_at_micros': DateTime.now().toUtc().microsecondsSinceEpoch,
        },
      );
    });
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
