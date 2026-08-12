import 'dart:io';

import 'package:sqflite/sqflite.dart';

import 'wecom_conversation_repository.dart';
import 'wecom_database_package.dart';
import 'wecom_directory_repository.dart';
import 'wecom_merged_conversation_repository.dart';
import 'wecom_merged_directory_repository.dart';
import 'wecom_overlay_database.dart';
import 'wecom_overlay_schema.dart';

enum WeComActiveDatasetIssueCode {
  noActiveDataset,
  activeDatasetMismatch,
  activeDatasetChanged,
  invalidActivation,
}

class WeComActiveDatasetException implements Exception {
  const WeComActiveDatasetException(
    this.code,
    this.message,
  );

  final WeComActiveDatasetIssueCode code;
  final String message;

  @override
  String toString() {
    return 'WeComActiveDatasetException.${code.name}: $message';
  }
}

class WeComActiveDatasetRuntime {
  WeComActiveDatasetRuntime._({
    required this.package,
    required this.directory,
    required this.conversations,
    required List<Database> connections,
  }) : _connections = connections;

  final WeComImportedPackage package;
  final WeComMergedDirectoryRepository directory;
  final WeComMergedConversationRepository conversations;
  final List<Database> _connections;

  bool _closed = false;

  String get datasetId => package.datasetId;

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await Future.wait(
      _connections.reversed.map((connection) => connection.close()),
    );
  }
}

class WeComActiveDatasetResolver {
  const WeComActiveDatasetResolver({
    required Directory destinationRoot,
    required WeComDatabasePackageImporter packageImporter,
    required DatabaseFactory databaseFactory,
    required WeComOverlayDatabase overlayDatabase,
  })  : _destinationRoot = destinationRoot,
        _packageImporter = packageImporter,
        _databaseFactory = databaseFactory,
        _overlayDatabase = overlayDatabase;

  final Directory _destinationRoot;
  final WeComDatabasePackageImporter _packageImporter;
  final DatabaseFactory _databaseFactory;
  final WeComOverlayDatabase _overlayDatabase;

  Future<bool> ensureInitialDataset(String datasetId) async {
    await _packageImporter.openImportedPackage(
      destinationRoot: _destinationRoot,
      datasetId: datasetId,
    );
    return _overlayDatabase.connection.transaction((transaction) async {
      final current = await _readLatestActivation(transaction);
      if (current == null) {
        await transaction.insert(
          WeComOverlaySchema.datasetActivationsTable,
          {
            'previous_dataset_id': null,
            'dataset_id': datasetId,
            'merge_id': null,
            'created_at_micros': DateTime.now().toUtc().microsecondsSinceEpoch,
          },
        );
        return true;
      }
      if (current.datasetId != datasetId) {
        throw WeComActiveDatasetException(
          WeComActiveDatasetIssueCode.activeDatasetMismatch,
          'A different dataset is already active',
        );
      }
      return false;
    });
  }

  Future<WeComActiveDatasetRuntime> openActive() async {
    final activation = await _readLatestActivation(
      _overlayDatabase.connection,
    );
    if (activation == null) {
      throw const WeComActiveDatasetException(
        WeComActiveDatasetIssueCode.noActiveDataset,
        'No active WeCom dataset has been selected',
      );
    }

    final package = await _packageImporter.openImportedPackage(
      destinationRoot: _destinationRoot,
      datasetId: activation.datasetId,
    );
    Database? userDatabase;
    Database? sessionDatabase;
    try {
      userDatabase = await package.openReadOnly(
        'user.db',
        factory: _databaseFactory,
      );
      sessionDatabase = await package.openReadOnly(
        'session.db',
        factory: _databaseFactory,
      );
      final current = await _readLatestActivation(
        _overlayDatabase.connection,
      );
      if (current == null ||
          current.activationId != activation.activationId ||
          current.datasetId != activation.datasetId) {
        throw const WeComActiveDatasetException(
          WeComActiveDatasetIssueCode.activeDatasetChanged,
          'Active dataset changed while repositories were being opened',
        );
      }

      return WeComActiveDatasetRuntime._(
        package: package,
        directory: WeComMergedDirectoryRepository(
          datasetId: package.datasetId,
          baseRepository: WeComDirectoryRepository(userDatabase),
          overlayDatabase: _overlayDatabase,
        ),
        conversations: WeComMergedConversationRepository(
          datasetId: package.datasetId,
          baseRepository: WeComConversationRepository(sessionDatabase),
          overlayDatabase: _overlayDatabase,
        ),
        connections: [userDatabase, sessionDatabase],
      );
    } catch (_) {
      await _closeQuietly(sessionDatabase);
      await _closeQuietly(userDatabase);
      rethrow;
    }
  }

  Future<_DatasetActivation?> _readLatestActivation(
    DatabaseExecutor executor,
  ) async {
    final rows = await executor.query(
      WeComOverlaySchema.datasetActivationsTable,
      columns: ['activation_id', 'dataset_id'],
      orderBy: 'activation_id DESC',
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    final activationId = rows.single['activation_id'];
    final datasetId = rows.single['dataset_id'];
    if (activationId is! int || datasetId is! String) {
      throw const WeComActiveDatasetException(
        WeComActiveDatasetIssueCode.invalidActivation,
        'Active dataset metadata is malformed',
      );
    }
    return _DatasetActivation(
      activationId: activationId,
      datasetId: datasetId,
    );
  }

  Future<void> _closeQuietly(Database? database) async {
    if (database == null) {
      return;
    }
    try {
      await database.close();
    } catch (_) {
      // Preserve the error that prevented the runtime from opening.
    }
  }
}

class _DatasetActivation {
  const _DatasetActivation({
    required this.activationId,
    required this.datasetId,
  });

  final int activationId;
  final String datasetId;
}
