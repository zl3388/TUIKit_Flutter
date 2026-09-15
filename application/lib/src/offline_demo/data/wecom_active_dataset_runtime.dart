import 'dart:io';

import 'package:sqflite/sqflite.dart';

import 'wecom_conversation_repository.dart';
import 'wecom_database_package.dart';
import 'wecom_directory_repository.dart';
import 'wecom_identity_repository.dart';
import 'wecom_merged_conversation_repository.dart';
import 'wecom_merged_directory_repository.dart';
import 'wecom_media_repository.dart';
import 'wecom_media_snapshot.dart';
import 'wecom_message_repository.dart';
import 'wecom_overlay_database.dart';
import 'wecom_overlay_schema.dart';

enum WeComActiveDatasetIssueCode {
  noActiveDataset,
  activeDatasetMismatch,
  activeDatasetChanged,
  invalidActivation,
  identityRequired,
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
    required this.messages,
    required this.identity,
    required this.media,
    required List<Database> connections,
  }) : _connections = connections;

  final WeComImportedPackage package;
  final WeComMergedDirectoryRepository directory;
  final WeComMergedConversationRepository conversations;
  final WeComMessageRepository messages;
  final WeComCurrentIdentityRepository identity;
  final WeComMediaRepository? media;
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
  WeComActiveDatasetResolver({
    required Directory destinationRoot,
    required WeComDatabasePackageImporter packageImporter,
    required DatabaseFactory databaseFactory,
    required WeComOverlayDatabase overlayDatabase,
  })  : _destinationRoot = destinationRoot,
        _packageImporter = packageImporter,
        _databaseFactory = databaseFactory,
        _overlayDatabase = overlayDatabase,
        _mediaSnapshots = WeComMediaSnapshotManager(
          destinationRoot: destinationRoot,
          databaseFactory: databaseFactory,
        );

  final Directory _destinationRoot;
  final WeComDatabasePackageImporter _packageImporter;
  final DatabaseFactory _databaseFactory;
  final WeComOverlayDatabase _overlayDatabase;
  final WeComMediaSnapshotManager _mediaSnapshots;

  Future<WeComMediaSnapshot> importMediaSnapshot({
    required String datasetId,
    required Directory wxWorkRoot,
  }) async {
    final package = await _packageImporter.openImportedPackage(
      destinationRoot: _destinationRoot,
      datasetId: datasetId,
    );
    return _mediaSnapshots.importReferencedMedia(
      datasetId: datasetId,
      fileDatabase: package.databaseFile('file.db'),
      messageDatabase: package.databaseFile('message.db'),
      wxWorkRoot: wxWorkRoot,
    );
  }

  Future<bool> ensureInitialDataset(
    String datasetId, {
    File? configFile,
    int? selectedCorporationId,
  }) async {
    final package = await _packageImporter.openImportedPackage(
      destinationRoot: _destinationRoot,
      datasetId: datasetId,
    );
    final resolution = await WeComIdentityResolver(_databaseFactory).resolve(
      package: package,
      configFile: configFile,
      selectedCorporationId: selectedCorporationId,
    );
    final identity = resolution.selected;
    if (identity == null) {
      throw const WeComActiveDatasetException(
        WeComActiveDatasetIssueCode.identityRequired,
        'The imported dataset requires an explicit corporation selection',
      );
    }
    return _overlayDatabase.connection.transaction((transaction) async {
      final current = await _readLatestActivation(transaction);
      if (current == null) {
        await transaction.insert(
          WeComOverlaySchema.datasetActivationsTable,
          {
            'previous_dataset_id': null,
            'dataset_id': datasetId,
            'merge_id': null,
            'current_corp_id': identity.corporationId,
            'current_user_id': identity.userId,
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
      if (current.corporationId == null || current.userId == null) {
        await transaction.insert(
          WeComOverlaySchema.datasetActivationsTable,
          {
            'previous_dataset_id': datasetId,
            'dataset_id': datasetId,
            'merge_id': null,
            'current_corp_id': identity.corporationId,
            'current_user_id': identity.userId,
            'created_at_micros': DateTime.now().toUtc().microsecondsSinceEpoch,
          },
        );
        return true;
      }
      return false;
    });
  }

  Future<WeComIdentityResolution> inspectIdentity(
    String datasetId, {
    File? configFile,
    int? selectedCorporationId,
  }) async {
    final package = await _packageImporter.openImportedPackage(
      destinationRoot: _destinationRoot,
      datasetId: datasetId,
    );
    return WeComIdentityResolver(_databaseFactory).resolve(
      package: package,
      configFile: configFile,
      selectedCorporationId: selectedCorporationId,
    );
  }

  Future<void> selectCorporation({
    required String datasetId,
    required int corporationId,
  }) async {
    final package = await _packageImporter.openImportedPackage(
      destinationRoot: _destinationRoot,
      datasetId: datasetId,
    );
    final resolution = await WeComIdentityResolver(_databaseFactory).resolve(
      package: package,
      selectedCorporationId: corporationId,
    );
    final identity = resolution.selected!;
    await _overlayDatabase.connection.transaction((transaction) async {
      final current = await _readLatestActivation(transaction);
      if (current == null || current.datasetId != datasetId) {
        throw const WeComActiveDatasetException(
          WeComActiveDatasetIssueCode.activeDatasetMismatch,
          'Corporation selection does not target the active dataset',
        );
      }
      if (current.corporationId == identity.corporationId &&
          current.userId == identity.userId) {
        return;
      }
      await transaction.insert(
        WeComOverlaySchema.datasetActivationsTable,
        {
          'previous_dataset_id': datasetId,
          'dataset_id': datasetId,
          'merge_id': null,
          'current_corp_id': identity.corporationId,
          'current_user_id': identity.userId,
          'created_at_micros': DateTime.now().toUtc().microsecondsSinceEpoch,
        },
      );
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
    Database? messageDatabase;
    Database? messageLookupDatabase;
    Database? fileDatabase;
    Database? cacheMappingDatabase;
    try {
      final corporationId = activation.corporationId;
      final userId = activation.userId;
      if (corporationId == null || userId == null) {
        throw const WeComActiveDatasetException(
          WeComActiveDatasetIssueCode.identityRequired,
          'The active dataset does not have a selected corporation identity',
        );
      }
      final resolution = await WeComIdentityResolver(_databaseFactory).resolve(
        package: package,
        selectedCorporationId: corporationId,
      );
      final identity = resolution.selected!;
      if (identity.userId != userId) {
        throw const WeComActiveDatasetException(
          WeComActiveDatasetIssueCode.invalidActivation,
          'Active corporation/user identity no longer matches company.db',
        );
      }
      userDatabase = await package.openReadOnly(
        'user.db',
        factory: _databaseFactory,
      );
      sessionDatabase = await package.openReadOnly(
        'session.db',
        factory: _databaseFactory,
      );
      messageDatabase = await package.openReadOnly(
        'message.db',
        factory: _databaseFactory,
      );
      messageLookupDatabase = await package.openReadOnly(
        'message_lookup.db',
        factory: _databaseFactory,
      );
      final mediaSnapshot = await _mediaSnapshots.openSnapshot(
        package.datasetId,
        verifyMediaHashes: false,
      );
      WeComMediaRepository? media;
      if (mediaSnapshot != null) {
        fileDatabase = await package.openReadOnly(
          'file.db',
          factory: _databaseFactory,
        );
        cacheMappingDatabase = await mediaSnapshot.openCacheMappingReadOnly(
          _databaseFactory,
        );
        media = WeComMediaRepository(
          fileDatabase: fileDatabase,
          cacheMappingDatabase: cacheMappingDatabase,
          mediaRoot: mediaSnapshot.mediaRoot,
        );
      }
      final current = await _readLatestActivation(
        _overlayDatabase.connection,
      );
      if (current == null ||
          current.activationId != activation.activationId ||
          current.datasetId != activation.datasetId ||
          current.corporationId != activation.corporationId ||
          current.userId != activation.userId) {
        throw const WeComActiveDatasetException(
          WeComActiveDatasetIssueCode.activeDatasetChanged,
          'Active dataset changed while repositories were being opened',
        );
      }

      return WeComActiveDatasetRuntime._(
        package: package,
        directory: WeComMergedDirectoryRepository(
          datasetId: package.datasetId,
          identityScope: identity.scope,
          baseRepository: WeComDirectoryRepository(userDatabase),
          overlayDatabase: _overlayDatabase,
        ),
        conversations: WeComMergedConversationRepository(
          datasetId: package.datasetId,
          identityScope: identity.scope,
          baseRepository: WeComConversationRepository(sessionDatabase),
          overlayDatabase: _overlayDatabase,
        ),
        messages: WeComMessageRepository(
          messageDatabase: messageDatabase,
          lookupDatabase: messageLookupDatabase,
        ),
        identity: WeComCurrentIdentityRepository(userDatabase, identity),
        media: media,
        connections: [
          userDatabase,
          sessionDatabase,
          messageDatabase,
          messageLookupDatabase,
          if (fileDatabase != null) fileDatabase,
          if (cacheMappingDatabase != null) cacheMappingDatabase,
        ],
      );
    } catch (_) {
      await _closeQuietly(cacheMappingDatabase);
      await _closeQuietly(fileDatabase);
      await _closeQuietly(messageLookupDatabase);
      await _closeQuietly(messageDatabase);
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
      columns: [
        'activation_id',
        'dataset_id',
        'current_corp_id',
        'current_user_id',
      ],
      orderBy: 'activation_id DESC',
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    final activationId = rows.single['activation_id'];
    final datasetId = rows.single['dataset_id'];
    final corporationId = rows.single['current_corp_id'];
    final userId = rows.single['current_user_id'];
    if (activationId is! int ||
        datasetId is! String ||
        (corporationId != null && corporationId is! int) ||
        (userId != null && userId is! int) ||
        ((corporationId == null) != (userId == null))) {
      throw const WeComActiveDatasetException(
        WeComActiveDatasetIssueCode.invalidActivation,
        'Active dataset metadata is malformed',
      );
    }
    return _DatasetActivation(
      activationId: activationId,
      datasetId: datasetId,
      corporationId: corporationId as int?,
      userId: userId as int?,
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
    required this.corporationId,
    required this.userId,
  });

  final int activationId;
  final String datasetId;
  final int? corporationId;
  final int? userId;
}
