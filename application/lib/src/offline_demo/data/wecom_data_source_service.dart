import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'wecom_active_dataset_runtime.dart';
import 'wecom_database_package.dart';
import 'wecom_identity_repository.dart';
import 'wecom_incremental_migration_service.dart';
import 'wecom_overlay_database.dart';
import 'wecom_overlay_schema.dart';
import 'wecom_source_directory_access.dart';

enum WeComDataSourceIssueCode {
  invalidSourceDirectory,
  invalidKeyFormat,
  identityUnavailable,
  corporationSelectionRequired,
  corporationSwitchDeferred,
  activeIdentityUnavailable,
  activeDatasetChanged,
  migrationConflict,
  savedSourceUnavailable,
}

class WeComDataSourceException implements Exception {
  const WeComDataSourceException(this.code, this.message, {this.cause});

  final WeComDataSourceIssueCode code;
  final String message;
  final Object? cause;

  @override
  String toString() => 'WeComDataSourceException.${code.name}: $message';
}

enum WeComDataSourceActivationStatus {
  activated,
  migrated,
  switched,
  unchanged,
}

class WeComSavedDataSource {
  const WeComSavedDataSource({
    required this.sourceLocator,
    required this.selectedPath,
    required this.dataPath,
    required this.datasetId,
    required this.corporationId,
    required this.userId,
    required this.updatedAtMicros,
  });

  final String sourceLocator;
  final String selectedPath;
  final String dataPath;
  final String datasetId;
  final int corporationId;
  final int userId;
  final int updatedAtMicros;

  Map<String, Object?> toJson() => {
        'format_version': 2,
        'source_locator': sourceLocator,
        'selected_path': selectedPath,
        'data_path': dataPath,
        'dataset_id': datasetId,
        'current_corp_id': corporationId,
        'current_user_id': userId,
        'updated_at_micros': updatedAtMicros,
      };

  static WeComSavedDataSource fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        (value['format_version'] != 1 && value['format_version'] != 2)) {
      throw const FormatException('Unsupported data source metadata');
    }
    final sourceLocator = value['format_version'] == 1
        ? value['selected_path']
        : value['source_locator'];
    final selectedPath = value['selected_path'];
    final dataPath = value['data_path'];
    final datasetId = value['dataset_id'];
    final corporationId = value['current_corp_id'];
    final userId = value['current_user_id'];
    final updatedAtMicros = value['updated_at_micros'];
    if (sourceLocator is! String ||
        sourceLocator.isEmpty ||
        selectedPath is! String ||
        selectedPath.isEmpty ||
        dataPath is! String ||
        dataPath.isEmpty ||
        datasetId is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(datasetId) ||
        corporationId is! int ||
        corporationId <= 0 ||
        userId is! int ||
        userId <= 0 ||
        updatedAtMicros is! int ||
        updatedAtMicros <= 0) {
      throw const FormatException('Invalid data source metadata');
    }
    return WeComSavedDataSource(
      sourceLocator: sourceLocator,
      selectedPath: selectedPath,
      dataPath: dataPath,
      datasetId: datasetId,
      corporationId: corporationId,
      userId: userId,
      updatedAtMicros: updatedAtMicros,
    );
  }
}

class WeComPreparedDataSource {
  const WeComPreparedDataSource({
    required this.sourceLocator,
    required this.selectedDirectory,
    required this.dataDirectory,
    required this.configFile,
    required this.package,
    required this.identityResolution,
  });

  final String sourceLocator;
  final Directory selectedDirectory;
  final Directory dataDirectory;
  final File? configFile;
  final WeComImportedPackage package;
  final WeComIdentityResolution identityResolution;
}

class WeComDataSourceActivationResult {
  const WeComDataSourceActivationResult({
    required this.status,
    required this.datasetId,
    required this.identity,
  });

  final WeComDataSourceActivationStatus status;
  final String datasetId;
  final WeComDatasetIdentity identity;
}

abstract interface class WeComDataSourceManager {
  Future<WeComSavedDataSource?> loadSelectedSource();

  Future<bool> hasDefaultRawKey();

  Future<void> clearDefaultRawKey();

  Future<WeComPreparedDataSource> prepare(
    Directory selectedDirectory, {
    String? sourceLocator,
    String? temporaryRawKeyHex,
  });

  Future<WeComPreparedDataSource> prepareSaved({
    String? temporaryRawKeyHex,
  });

  Future<WeComDataSourceActivationResult> activate(
    WeComPreparedDataSource prepared, {
    int? selectedCorporationId,
    String? defaultRawKeyToSave,
  });
}

abstract interface class WeComDefaultKeyStore {
  Future<String?> read();

  Future<void> write(String rawKeyHex);

  Future<void> clear();
}

class SecureWeComDefaultKeyStore implements WeComDefaultKeyStore {
  SecureWeComDefaultKeyStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  static const _key = 'offline_demo_wecom_default_raw_key';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String rawKeyHex) =>
      _storage.write(key: _key, value: rawKeyHex);

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

abstract interface class WeComSourceSelectionStore {
  Future<WeComSavedDataSource?> read();

  Future<void> write(WeComSavedDataSource source);
}

class FileWeComSourceSelectionStore implements WeComSourceSelectionStore {
  const FileWeComSourceSelectionStore(this.file);

  final File file;

  @override
  Future<WeComSavedDataSource?> read() async {
    if (!await file.exists()) {
      return null;
    }
    return WeComSavedDataSource.fromJson(
      jsonDecode(await file.readAsString()),
    );
  }

  @override
  Future<void> write(WeComSavedDataSource source) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(source.toJson()), flush: true);
  }
}

class WeComDataSourceService implements WeComDataSourceManager {
  WeComDataSourceService({
    required Directory destinationRoot,
    required WeComDatabasePackageImporter packageImporter,
    required WeComActiveDatasetResolver datasetResolver,
    required WeComIncrementalMigrationService migrationService,
    required WeComOverlayDatabase overlayDatabase,
    required WeComDefaultKeyStore defaultKeyStore,
    required WeComSourceSelectionStore selectionStore,
    WeComSourceDirectoryResolver sourceDirectoryResolver =
        const FileSystemWeComSourceDirectoryResolver(),
  })  : _destinationRoot = destinationRoot,
        _packageImporter = packageImporter,
        _datasetResolver = datasetResolver,
        _migrationService = migrationService,
        _overlayDatabase = overlayDatabase,
        _defaultKeyStore = defaultKeyStore,
        _selectionStore = selectionStore,
        _sourceDirectoryResolver = sourceDirectoryResolver;

  static final _rawKeyPattern = RegExp(r'^[0-9a-fA-F]{32}$');

  final Directory _destinationRoot;
  final WeComDatabasePackageImporter _packageImporter;
  final WeComActiveDatasetResolver _datasetResolver;
  final WeComIncrementalMigrationService _migrationService;
  final WeComOverlayDatabase _overlayDatabase;
  final WeComDefaultKeyStore _defaultKeyStore;
  final WeComSourceSelectionStore _selectionStore;
  final WeComSourceDirectoryResolver _sourceDirectoryResolver;

  @override
  Future<WeComSavedDataSource?> loadSelectedSource() => _selectionStore.read();

  @override
  Future<bool> hasDefaultRawKey() async =>
      (await _defaultKeyStore.read()) != null;

  @override
  Future<void> clearDefaultRawKey() => _defaultKeyStore.clear();

  @override
  Future<WeComPreparedDataSource> prepare(
    Directory selectedDirectory, {
    String? sourceLocator,
    String? temporaryRawKeyHex,
  }) async {
    final location = await _resolveLocation(selectedDirectory);
    final temporaryKey = _normalizeKey(temporaryRawKeyHex);
    final defaultKey = _normalizeKey(await _defaultKeyStore.read());
    final imported = await _packageImporter.importPackage(
      sourceDirectory: location.dataDirectory,
      destinationRoot: _destinationRoot,
      defaultRawKeyHex: defaultKey,
      temporaryRawKeyHex: temporaryKey,
    );
    final resolution = await _datasetResolver.inspectIdentity(
      imported.datasetId,
      configFile: location.configFile,
    );
    return WeComPreparedDataSource(
      sourceLocator: sourceLocator ?? selectedDirectory.path,
      selectedDirectory: location.selectedDirectory,
      dataDirectory: location.dataDirectory,
      configFile: location.configFile,
      package: imported,
      identityResolution: resolution,
    );
  }

  @override
  Future<WeComPreparedDataSource> prepareSaved({
    String? temporaryRawKeyHex,
  }) async {
    final saved = await _selectionStore.read();
    if (saved == null) {
      throw const WeComDataSourceException(
        WeComDataSourceIssueCode.savedSourceUnavailable,
        'No saved data source is available',
      );
    }
    try {
      return prepare(
        await _sourceDirectoryResolver.resolve(saved.sourceLocator),
        sourceLocator: saved.sourceLocator,
        temporaryRawKeyHex: temporaryRawKeyHex,
      );
    } catch (error) {
      if (error is WeComDataSourceException || error is WeComPackageException) {
        rethrow;
      }
      throw WeComDataSourceException(
        WeComDataSourceIssueCode.savedSourceUnavailable,
        'The saved source directory cannot be materialized',
        cause: error,
      );
    }
  }

  @override
  Future<WeComDataSourceActivationResult> activate(
    WeComPreparedDataSource prepared, {
    int? selectedCorporationId,
    String? defaultRawKeyToSave,
  }) async {
    final identity = await _resolveSelectedIdentity(
      prepared,
      selectedCorporationId,
    );
    final keyToSave = _normalizeKey(defaultRawKeyToSave);
    final active = await _readLatestActivation(_overlayDatabase.connection);
    late WeComDataSourceActivationStatus status;

    if (active == null) {
      await _datasetResolver.ensureInitialDataset(
        prepared.package.datasetId,
        configFile: prepared.configFile,
        selectedCorporationId: identity.corporationId,
      );
      status = WeComDataSourceActivationStatus.activated;
    } else if (active.datasetId == prepared.package.datasetId) {
      if (!active.matches(identity)) {
        throw const WeComDataSourceException(
          WeComDataSourceIssueCode.corporationSwitchDeferred,
          'Switching corporations inside one dataset is not available yet',
        );
      }
      status = WeComDataSourceActivationStatus.unchanged;
    } else {
      if (!active.hasIdentity) {
        throw const WeComDataSourceException(
          WeComDataSourceIssueCode.activeIdentityUnavailable,
          'The active dataset has no validated identity',
        );
      }
      final targetActivations = await _readDatasetActivations(
        _overlayDatabase.connection,
        prepared.package.datasetId,
      );
      final knownTarget = targetActivations.any(
        (activation) => activation.matches(identity),
      );
      if (!knownTarget && targetActivations.isNotEmpty) {
        throw const WeComDataSourceException(
          WeComDataSourceIssueCode.corporationSwitchDeferred,
          'Switching corporations inside one dataset is not available yet',
        );
      }

      if (knownTarget) {
        await _activateDirect(active, prepared.package.datasetId, identity);
        status = WeComDataSourceActivationStatus.switched;
      } else if (active.matches(identity)) {
        final oldPackage = await _packageImporter.openImportedPackage(
          destinationRoot: _destinationRoot,
          datasetId: active.datasetId,
        );
        final migration = await _migrationService.migrate(
          oldBasePackage: oldPackage,
          newBasePackage: prepared.package,
        );
        if (!migration.applied) {
          throw const WeComDataSourceException(
            WeComDataSourceIssueCode.migrationConflict,
            'The new snapshot conflicts with local overlay changes',
          );
        }
        status = WeComDataSourceActivationStatus.migrated;
      } else {
        await _activateDirect(active, prepared.package.datasetId, identity);
        status = WeComDataSourceActivationStatus.switched;
      }
    }

    await _selectionStore.write(
      WeComSavedDataSource(
        sourceLocator: prepared.sourceLocator,
        selectedPath: prepared.selectedDirectory.path,
        dataPath: prepared.dataDirectory.path,
        datasetId: prepared.package.datasetId,
        corporationId: identity.corporationId,
        userId: identity.userId,
        updatedAtMicros: DateTime.now().toUtc().microsecondsSinceEpoch,
      ),
    );
    if (keyToSave != null) {
      await _defaultKeyStore.write(keyToSave);
    }
    return WeComDataSourceActivationResult(
      status: status,
      datasetId: prepared.package.datasetId,
      identity: identity,
    );
  }

  Future<_WeComSourceLocation> _resolveLocation(
    Directory selectedDirectory,
  ) async {
    final selected = Directory(p.normalize(p.absolute(selectedDirectory.path)));
    if (!await selected.exists()) {
      throw const WeComDataSourceException(
        WeComDataSourceIssueCode.invalidSourceDirectory,
        'The selected directory does not exist',
      );
    }

    late Directory dataDirectory;
    late Directory accountDirectory;
    if (p.basename(selected.path).toLowerCase() == 'data') {
      dataDirectory = selected;
      accountDirectory = selected.parent;
    } else {
      final child = Directory(p.join(selected.path, 'Data'));
      if (!await child.exists()) {
        throw const WeComDataSourceException(
          WeComDataSourceIssueCode.invalidSourceDirectory,
          'Select an account root containing Data or the Data directory',
        );
      }
      accountDirectory = selected;
      dataDirectory = child;
    }
    final config = File(p.join(accountDirectory.path, 'Config.cfg'));
    return _WeComSourceLocation(
      selectedDirectory: selected,
      dataDirectory: dataDirectory,
      configFile: await config.exists() ? config : null,
    );
  }

  String? _normalizeKey(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    final normalized = value.trim().toLowerCase();
    if (!_rawKeyPattern.hasMatch(normalized)) {
      throw const WeComDataSourceException(
        WeComDataSourceIssueCode.invalidKeyFormat,
        'The raw key must contain exactly 32 hexadecimal characters',
      );
    }
    return normalized;
  }

  Future<WeComDatasetIdentity> _resolveSelectedIdentity(
    WeComPreparedDataSource prepared,
    int? selectedCorporationId,
  ) async {
    if (selectedCorporationId != null) {
      final resolution = await _datasetResolver.inspectIdentity(
        prepared.package.datasetId,
        configFile: prepared.configFile,
        selectedCorporationId: selectedCorporationId,
      );
      return resolution.selected!;
    }
    final selected = prepared.identityResolution.selected;
    if (selected != null) {
      return selected;
    }
    if (prepared.identityResolution.candidates.isEmpty) {
      throw const WeComDataSourceException(
        WeComDataSourceIssueCode.identityUnavailable,
        'No current corporation/user identity was found in the package',
      );
    }
    throw const WeComDataSourceException(
      WeComDataSourceIssueCode.corporationSelectionRequired,
      'Choose one corporation before activating this data source',
    );
  }

  Future<void> _activateDirect(
    _ActivationMetadata expectedActive,
    String targetDatasetId,
    WeComDatasetIdentity identity,
  ) {
    return _overlayDatabase.connection.transaction((transaction) async {
      final current = await _readLatestActivation(transaction);
      if (current == null ||
          current.activationId != expectedActive.activationId) {
        throw const WeComDataSourceException(
          WeComDataSourceIssueCode.activeDatasetChanged,
          'The active dataset changed during activation',
        );
      }
      await transaction.insert(
        WeComOverlaySchema.datasetActivationsTable,
        {
          'previous_dataset_id': current.datasetId,
          'dataset_id': targetDatasetId,
          'merge_id': null,
          'current_corp_id': identity.corporationId,
          'current_user_id': identity.userId,
          'created_at_micros': DateTime.now().toUtc().microsecondsSinceEpoch,
        },
      );
    });
  }

  Future<_ActivationMetadata?> _readLatestActivation(
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
    return rows.isEmpty ? null : _ActivationMetadata.fromRow(rows.single);
  }

  Future<List<_ActivationMetadata>> _readDatasetActivations(
    DatabaseExecutor executor,
    String datasetId,
  ) async {
    final rows = await executor.query(
      WeComOverlaySchema.datasetActivationsTable,
      columns: [
        'activation_id',
        'dataset_id',
        'current_corp_id',
        'current_user_id',
      ],
      where: 'dataset_id = ?',
      whereArgs: [datasetId],
      orderBy: 'activation_id DESC',
    );
    return rows.map(_ActivationMetadata.fromRow).toList(growable: false);
  }
}

class _WeComSourceLocation {
  const _WeComSourceLocation({
    required this.selectedDirectory,
    required this.dataDirectory,
    required this.configFile,
  });

  final Directory selectedDirectory;
  final Directory dataDirectory;
  final File? configFile;
}

class _ActivationMetadata {
  const _ActivationMetadata({
    required this.activationId,
    required this.datasetId,
    required this.corporationId,
    required this.userId,
  });

  factory _ActivationMetadata.fromRow(Map<String, Object?> row) {
    final activationId = row['activation_id'];
    final datasetId = row['dataset_id'];
    final corporationId = row['current_corp_id'];
    final userId = row['current_user_id'];
    if (activationId is! int ||
        datasetId is! String ||
        (corporationId != null && corporationId is! int) ||
        (userId != null && userId is! int) ||
        ((corporationId == null) != (userId == null))) {
      throw const WeComDataSourceException(
        WeComDataSourceIssueCode.activeIdentityUnavailable,
        'Persisted dataset activation metadata is malformed',
      );
    }
    return _ActivationMetadata(
      activationId: activationId,
      datasetId: datasetId,
      corporationId: corporationId as int?,
      userId: userId as int?,
    );
  }

  final int activationId;
  final String datasetId;
  final int? corporationId;
  final int? userId;

  bool get hasIdentity => corporationId != null && userId != null;

  bool matches(WeComDatasetIdentity identity) =>
      corporationId == identity.corporationId && userId == identity.userId;
}
