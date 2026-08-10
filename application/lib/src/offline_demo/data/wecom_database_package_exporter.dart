import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'wecom_database_package.dart';
import 'wecom_overlay_contract_validator.dart';
import 'wecom_overlay_database.dart';
import 'wecom_overlay_schema.dart';

enum WeComExportIssueCode {
  overlappingPaths,
  destinationExists,
  basePackageChanged,
  unsupportedTarget,
  invalidOverlay,
  applyFailed,
  commitFailed,
}

class WeComExportException implements Exception {
  const WeComExportException(
    this.code,
    this.message, {
    this.fileName,
    this.revisionId,
    this.cause,
  });

  final WeComExportIssueCode code;
  final String message;
  final String? fileName;
  final int? revisionId;
  final Object? cause;

  @override
  String toString() {
    final file = fileName == null ? '' : ' [$fileName]';
    final revision = revisionId == null ? '' : ' [revision=$revisionId]';
    return 'WeComExportException.${code.name}$file$revision: $message';
  }
}

class WeComExportedPackage {
  const WeComExportedPackage({
    required this.datasetId,
    required this.directory,
    required this.files,
    required this.appliedRevisionCount,
    required this.lastAppliedRevisionId,
  });

  final String datasetId;
  final Directory directory;
  final Map<String, WeComPackageFile> files;
  final int appliedRevisionCount;
  final int? lastAppliedRevisionId;

  File databaseFile(String fileName) {
    if (!files.containsKey(fileName)) {
      throw ArgumentError.value(fileName, 'fileName', 'Unknown database');
    }
    return File(p.join(directory.path, fileName));
  }
}

class WeComDatabasePackageExporter {
  WeComDatabasePackageExporter({
    required WeComPackageContract contract,
    required DatabaseFactory databaseFactory,
  })  : _contract = contract,
        _databaseFactory = databaseFactory,
        _validator = WeComOverlayContractValidator(contract);

  static const _certifiedTargets = <String>{
    'user.db/user_table',
    'session.db/conversation_table',
    'session.db/unread_conversation_table',
    'session.db/conversation_user_table',
  };

  final WeComPackageContract _contract;
  final DatabaseFactory _databaseFactory;
  final WeComOverlayContractValidator _validator;

  Future<WeComExportedPackage> export({
    required WeComImportedPackage basePackage,
    required WeComOverlayDatabase overlayDatabase,
    required Directory destinationDirectory,
  }) async {
    final basePath = p.normalize(p.absolute(basePackage.directory.path));
    final destinationPath = p.normalize(p.absolute(destinationDirectory.path));
    if (p.equals(basePath, destinationPath) ||
        p.isWithin(basePath, destinationPath) ||
        p.isWithin(destinationPath, basePath)) {
      throw const WeComExportException(
        WeComExportIssueCode.overlappingPaths,
        'Base and export directories must not overlap',
      );
    }
    if (await FileSystemEntity.type(destinationPath) !=
        FileSystemEntityType.notFound) {
      throw const WeComExportException(
        WeComExportIssueCode.destinationExists,
        'Export destination already exists',
      );
    }

    await _verifyBasePackage(basePackage);
    final operations = await _readOperations(
      overlayDatabase,
      basePackage.datasetId,
    );

    final parent = Directory(p.dirname(destinationPath));
    await parent.create(recursive: true);
    final stagingDirectory = Directory(
      p.join(
        parent.path,
        '.wecom-export-'
        '${DateTime.now().toUtc().microsecondsSinceEpoch}-'
        '${Random.secure().nextInt(1 << 32)}',
      ),
    );
    Directory? validationRoot;

    try {
      await stagingDirectory.create();
      validationRoot =
          await Directory.systemTemp.createTemp('tui_wecom_export_validate_');
      await _copyBasePackage(basePackage, stagingDirectory);
      await _verifyBasePackage(basePackage);
      await _applyOperations(stagingDirectory, operations);

      final validated = await WeComDatabasePackageImporter(
        contract: _contract,
        databaseFactory: _databaseFactory,
      ).importPackage(
        sourceDirectory: stagingDirectory,
        destinationRoot: validationRoot,
      );
      await _verifyBasePackage(basePackage);
      if (await FileSystemEntity.type(destinationPath) !=
          FileSystemEntityType.notFound) {
        throw const WeComExportException(
          WeComExportIssueCode.destinationExists,
          'Export destination appeared while export was running',
        );
      }

      try {
        await stagingDirectory.rename(destinationPath);
      } on FileSystemException catch (error) {
        throw WeComExportException(
          WeComExportIssueCode.commitFailed,
          'Could not publish the validated export package',
          cause: error,
        );
      }

      return WeComExportedPackage(
        datasetId: validated.datasetId,
        directory: Directory(destinationPath),
        files: validated.files,
        appliedRevisionCount: operations.length,
        lastAppliedRevisionId:
            operations.isEmpty ? null : operations.last.revisionId,
      );
    } finally {
      await _deleteIfExists(stagingDirectory);
      if (validationRoot != null) {
        await _deleteIfExists(validationRoot);
      }
    }
  }

  Future<List<_ExportOperation>> _readOperations(
    WeComOverlayDatabase overlayDatabase,
    String datasetId,
  ) async {
    final rows = await overlayDatabase.connection.query(
      WeComOverlaySchema.operationsTable,
      where: 'dataset_id = ?',
      whereArgs: [datasetId],
      orderBy: 'revision_id',
    );
    final operations = <_ExportOperation>[];
    for (final row in rows) {
      final revisionId = row['revision_id'];
      final databaseName = row['database_name'];
      final tableName = row['table_name'];
      final operation = row['operation'];
      if (revisionId is! int ||
          databaseName is! String ||
          tableName is! String ||
          operation is! String) {
        throw const WeComExportException(
          WeComExportIssueCode.invalidOverlay,
          'Overlay revision metadata is malformed',
        );
      }
      if (!_certifiedTargets.contains('$databaseName/$tableName')) {
        throw WeComExportException(
          WeComExportIssueCode.unsupportedTarget,
          'Overlay target has not passed export certification',
          fileName: databaseName,
          revisionId: revisionId,
        );
      }

      try {
        final target = _validator.resolveTarget(databaseName, tableName);
        final rowKey = _validator.canonicalRowKey(
          target,
          _decodeMap(row['row_key_json']),
        );
        Map<String, Object?>? values;
        if (operation == 'upsert') {
          values = _validator.canonicalValues(
            target,
            _decodeMap(row['values_json']),
          );
        } else if (operation != 'tombstone' || row['values_json'] != null) {
          throw const FormatException('Invalid overlay operation payload');
        }
        operations.add(
          _ExportOperation(
            revisionId: revisionId,
            databaseName: databaseName,
            tableName: tableName,
            operation: operation,
            rowKey: rowKey,
            values: values,
          ),
        );
      } catch (error) {
        throw WeComExportException(
          WeComExportIssueCode.invalidOverlay,
          'Overlay revision does not match the active schema contract',
          fileName: databaseName,
          revisionId: revisionId,
          cause: error,
        );
      }
    }
    return operations;
  }

  Map<String, Object?> _decodeMap(Object? source) {
    if (source is! String) {
      throw const FormatException('Overlay JSON is missing');
    }
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('Overlay JSON must be an object');
    }
    return Map<String, Object?>.from(decoded);
  }

  Future<void> _applyOperations(
    Directory stagingDirectory,
    List<_ExportOperation> operations,
  ) async {
    final byDatabase = <String, List<_ExportOperation>>{};
    for (final operation in operations) {
      byDatabase.putIfAbsent(operation.databaseName, () => []).add(operation);
    }

    for (final entry in byDatabase.entries) {
      final file = File(p.join(stagingDirectory.path, entry.key));
      Database? database;
      try {
        database = await _databaseFactory.openDatabase(
          file.path,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        await database.rawQuery('PRAGMA journal_mode = DELETE');
        await database.transaction((transaction) async {
          for (final operation in entry.value) {
            await _applyOperation(transaction, operation);
          }
        });
      } catch (error) {
        throw WeComExportException(
          WeComExportIssueCode.applyFailed,
          'Could not apply certified overlay revisions',
          fileName: entry.key,
          cause: error,
        );
      } finally {
        await database?.close();
      }
      if (await File('${file.path}-wal').exists()) {
        throw WeComExportException(
          WeComExportIssueCode.applyFailed,
          'Export left an uncommitted WAL sidecar',
          fileName: entry.key,
        );
      }
    }
  }

  Future<void> _applyOperation(
    Transaction transaction,
    _ExportOperation operation,
  ) async {
    final where = operation.rowKey.keys
        .map((column) => '${_quoteIdentifier(column)} = ?')
        .join(' AND ');
    final whereArgs = operation.rowKey.values.toList(growable: false);
    if (operation.operation == 'tombstone') {
      await transaction.delete(
        operation.tableName,
        where: where,
        whereArgs: whereArgs,
      );
      return;
    }

    final existing = await transaction.query(
      operation.tableName,
      columns: operation.rowKey.keys.toList(growable: false),
      where: where,
      whereArgs: whereArgs,
      limit: 1,
    );
    if (existing.isEmpty) {
      await transaction.insert(
        operation.tableName,
        {...operation.rowKey, ...operation.values!},
      );
    } else {
      await transaction.update(
        operation.tableName,
        operation.values!,
        where: where,
        whereArgs: whereArgs,
      );
    }
  }

  String _quoteIdentifier(String value) {
    return '"${value.replaceAll('"', '""')}"';
  }

  Future<void> _copyBasePackage(
    WeComImportedPackage basePackage,
    Directory stagingDirectory,
  ) async {
    for (final database in _contract.databases) {
      final metadata = basePackage.files[database.fileName]!;
      final copied = await basePackage.databaseFile(database.fileName).copy(
            p.join(stagingDirectory.path, database.fileName),
          );
      if (await copied.length() != metadata.sizeBytes ||
          await _hashFile(copied) != metadata.sha256) {
        throw WeComExportException(
          WeComExportIssueCode.basePackageChanged,
          'Copied base database does not match the imported dataset',
          fileName: database.fileName,
        );
      }
    }
  }

  Future<void> _verifyBasePackage(WeComImportedPackage basePackage) async {
    final expectedNames =
        _contract.databases.map((database) => database.fileName).toSet();
    if (basePackage.files.length != expectedNames.length ||
        !basePackage.files.keys.toSet().containsAll(expectedNames)) {
      throw const WeComExportException(
        WeComExportIssueCode.basePackageChanged,
        'Imported dataset does not match the active package contract',
      );
    }
    for (final database in _contract.databases) {
      final metadata = basePackage.files[database.fileName]!;
      final file = basePackage.databaseFile(database.fileName);
      if (!await file.exists() ||
          await file.length() != metadata.sizeBytes ||
          await _hashFile(file) != metadata.sha256) {
        throw WeComExportException(
          WeComExportIssueCode.basePackageChanged,
          'Base database changed after import',
          fileName: database.fileName,
        );
      }
    }
  }

  Future<String> _hashFile(File file) async {
    return (await sha256.bind(file.openRead()).first).toString();
  }

  Future<void> _deleteIfExists(Directory directory) async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}

class _ExportOperation {
  const _ExportOperation({
    required this.revisionId,
    required this.databaseName,
    required this.tableName,
    required this.operation,
    required this.rowKey,
    required this.values,
  });

  final int revisionId;
  final String databaseName;
  final String tableName;
  final String operation;
  final Map<String, Object?> rowKey;
  final Map<String, Object?>? values;
}
