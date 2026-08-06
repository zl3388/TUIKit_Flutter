import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class WeComColumnContract {
  const WeComColumnContract({
    required this.name,
    required this.type,
    required this.notNull,
    required this.primaryKeyPosition,
  });

  factory WeComColumnContract.fromJson(Map<String, Object?> json) {
    return WeComColumnContract(
      name: json['name']! as String,
      type: (json['type']! as String).trim().toUpperCase(),
      notNull: json['notNull']! as bool,
      primaryKeyPosition: json['primaryKeyPosition']! as int,
    );
  }

  final String name;
  final String type;
  final bool notNull;
  final int primaryKeyPosition;

  bool matches(Map<String, Object?> row) {
    return row['name'] == name &&
        (row['type'] as String? ?? '').trim().toUpperCase() == type &&
        (row['notnull'] as int? ?? 0) == (notNull ? 1 : 0) &&
        (row['pk'] as int? ?? 0) == primaryKeyPosition;
  }
}

class WeComDatabaseContract {
  WeComDatabaseContract({
    required this.fileName,
    required this.allowEmpty,
    required Map<String, List<WeComColumnContract>> tables,
    required Set<String> indexes,
    Set<String> skipColumnValidation = const {},
    Map<String, String> expectedFtsTokenizers = const {},
  })  : tables = Map.unmodifiable(
          tables.map(
            (name, columns) =>
                MapEntry(name, List<WeComColumnContract>.unmodifiable(columns)),
          ),
        ),
        indexes = Set<String>.unmodifiable(indexes),
        skipColumnValidation = Set<String>.unmodifiable(skipColumnValidation),
        expectedFtsTokenizers = Map.unmodifiable(
          expectedFtsTokenizers.map(
            (name, tokenizer) => MapEntry(name, tokenizer.toLowerCase()),
          ),
        ) {
    if (fileName.isEmpty ||
        p.basename(fileName) != fileName ||
        p.extension(fileName).toLowerCase() != '.db') {
      throw FormatException('Invalid database file name: $fileName');
    }
    if (!this.tables.keys.toSet().containsAll(this.skipColumnValidation)) {
      throw FormatException(
        'Column validation exclusions must reference known tables in $fileName',
      );
    }
    if (!this.tables.keys.toSet().containsAll(expectedFtsTokenizers.keys) ||
        expectedFtsTokenizers.values.any((tokenizer) => tokenizer.isEmpty)) {
      throw FormatException(
        'FTS tokenizer rules must reference known tables in $fileName',
      );
    }
  }

  factory WeComDatabaseContract.fromJson(Map<String, Object?> json) {
    final rawTables = json['tables'];
    final rawIndexes = json['indexes'];
    final rawSkips = json['skipColumnValidation'];
    final rawFtsTokenizers = json['expectedFtsTokenizers'] ?? const {};
    if (rawTables is! Map ||
        rawIndexes is! List ||
        rawSkips is! List ||
        rawFtsTokenizers is! Map) {
      throw const FormatException('Invalid database contract');
    }

    final tables = <String, List<WeComColumnContract>>{};
    for (final entry in rawTables.entries) {
      final rawColumns = entry.value;
      if (rawColumns is! List) {
        throw FormatException('Invalid columns for ${entry.key}');
      }
      tables[entry.key.toString()] = rawColumns
          .map(
            (column) => WeComColumnContract.fromJson(
              Map<String, Object?>.from(column as Map),
            ),
          )
          .toList(growable: false);
    }

    final expectedFtsTokenizers = <String, String>{};
    for (final entry in rawFtsTokenizers.entries) {
      if (entry.value is! String || (entry.value as String).isEmpty) {
        throw FormatException('Invalid FTS tokenizer for ${entry.key}');
      }
      expectedFtsTokenizers[entry.key.toString()] = entry.value as String;
    }

    return WeComDatabaseContract(
      fileName: json['fileName']! as String,
      allowEmpty: json['allowEmpty']! as bool,
      tables: tables,
      indexes: rawIndexes.map((value) => value.toString()).toSet(),
      skipColumnValidation: rawSkips.map((value) => value.toString()).toSet(),
      expectedFtsTokenizers: expectedFtsTokenizers,
    );
  }

  final String fileName;
  final bool allowEmpty;
  final Map<String, List<WeComColumnContract>> tables;
  final Set<String> indexes;
  final Set<String> skipColumnValidation;
  final Map<String, String> expectedFtsTokenizers;
}

class WeComPackageContract {
  WeComPackageContract({
    required this.formatVersion,
    required this.scope,
    required List<WeComDatabaseContract> databases,
  }) : databases = List.unmodifiable(databases) {
    if (formatVersion != 1) {
      throw FormatException(
        'Unsupported WeCom package contract version: $formatVersion',
      );
    }
    final names = databases.map((database) => database.fileName).toSet();
    if (names.length != databases.length) {
      throw const FormatException('Duplicate database file names');
    }
  }

  factory WeComPackageContract.fromJsonString(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('Package contract must be a JSON object');
    }
    final json = Map<String, Object?>.from(decoded);
    final rawDatabases = json['databases'];
    if (rawDatabases is! List) {
      throw const FormatException('Package contract databases are missing');
    }
    return WeComPackageContract(
      formatVersion: json['formatVersion']! as int,
      scope: json['scope']! as String,
      databases: rawDatabases
          .map(
            (database) => WeComDatabaseContract.fromJson(
              Map<String, Object?>.from(database as Map),
            ),
          )
          .toList(growable: false),
    );
  }

  final int formatVersion;
  final String scope;
  final List<WeComDatabaseContract> databases;

  int get expectedTableCount => databases.fold(
        0,
        (total, database) => total + database.tables.length,
      );

  int get expectedIndexCount => databases.fold(
        0,
        (total, database) => total + database.indexes.length,
      );
}

enum WeComPackageIssueCode {
  sourceDirectoryMissing,
  overlappingPaths,
  requiredFileMissing,
  emptyDatabaseNotAllowed,
  encryptedOrUnsupportedInput,
  sourceChanged,
  copyMismatch,
  sqliteOpenFailed,
  integrityCheckFailed,
  schemaMismatch,
  existingPackageCorrupt,
  importCommitFailed,
}

class WeComPackageException implements Exception {
  const WeComPackageException(
    this.code,
    this.message, {
    this.fileName,
    this.cause,
  });

  final WeComPackageIssueCode code;
  final String message;
  final String? fileName;
  final Object? cause;

  @override
  String toString() {
    final file = fileName == null ? '' : ' [$fileName]';
    return 'WeComPackageException.${code.name}$file: $message';
  }
}

class WeComPackageFile {
  const WeComPackageFile({
    required this.fileName,
    required this.sha256,
    required this.sizeBytes,
    required this.tableCount,
    required this.indexCount,
    required this.isEmptyPlaceholder,
  });

  final String fileName;
  final String sha256;
  final int sizeBytes;
  final int tableCount;
  final int indexCount;
  final bool isEmptyPlaceholder;

  Map<String, Object> toJson() => {
        'fileName': fileName,
        'sha256': sha256,
        'sizeBytes': sizeBytes,
        'tableCount': tableCount,
        'indexCount': indexCount,
        'isEmptyPlaceholder': isEmptyPlaceholder,
      };
}

class WeComImportedPackage {
  const WeComImportedPackage._({
    required this.datasetId,
    required this.directory,
    required this.files,
    required this.reusedExisting,
  });

  final String datasetId;
  final Directory directory;
  final Map<String, WeComPackageFile> files;
  final bool reusedExisting;

  File databaseFile(String fileName) {
    if (!files.containsKey(fileName)) {
      throw ArgumentError.value(fileName, 'fileName', 'Unknown database');
    }
    return File(p.join(directory.path, fileName));
  }

  Future<Database> openReadOnly(
    String fileName, {
    required DatabaseFactory factory,
  }) {
    return factory.openDatabase(
      databaseFile(fileName).path,
      options: OpenDatabaseOptions(
        readOnly: true,
        singleInstance: false,
      ),
    );
  }
}

class WeComDatabasePackageImporter {
  WeComDatabasePackageImporter({
    required this.contract,
    required this.databaseFactory,
  });

  static const manifestFileName = 'dataset.json';
  static const _sqliteHeader = <int>[
    0x53,
    0x51,
    0x4c,
    0x69,
    0x74,
    0x65,
    0x20,
    0x66,
    0x6f,
    0x72,
    0x6d,
    0x61,
    0x74,
    0x20,
    0x33,
    0x00,
  ];

  final WeComPackageContract contract;
  final DatabaseFactory databaseFactory;

  Future<WeComImportedPackage> importPackage({
    required Directory sourceDirectory,
    required Directory destinationRoot,
  }) async {
    if (!await sourceDirectory.exists()) {
      throw const WeComPackageException(
        WeComPackageIssueCode.sourceDirectoryMissing,
        'Source directory does not exist',
      );
    }

    final sourcePath = p.normalize(p.absolute(sourceDirectory.path));
    final destinationPath = p.normalize(p.absolute(destinationRoot.path));
    if (p.equals(sourcePath, destinationPath) ||
        p.isWithin(sourcePath, destinationPath) ||
        p.isWithin(destinationPath, sourcePath)) {
      throw const WeComPackageException(
        WeComPackageIssueCode.overlappingPaths,
        'Source and destination directories must not overlap',
      );
    }

    final prepared = <_PreparedInput>[];
    for (final database in contract.databases) {
      final sourceFile = File(p.join(sourcePath, database.fileName));
      if (!await sourceFile.exists()) {
        throw WeComPackageException(
          WeComPackageIssueCode.requiredFileMissing,
          'Required database file is missing',
          fileName: database.fileName,
        );
      }
      final size = await sourceFile.length();
      if (size == 0 && !database.allowEmpty) {
        throw WeComPackageException(
          WeComPackageIssueCode.emptyDatabaseNotAllowed,
          'Database file is empty',
          fileName: database.fileName,
        );
      }
      if (size > 0 && !await _hasSqliteHeader(sourceFile)) {
        throw WeComPackageException(
          WeComPackageIssueCode.encryptedOrUnsupportedInput,
          'Input is not a decrypted SQLite database',
          fileName: database.fileName,
        );
      }
      prepared.add(
        _PreparedInput(
          contract: database,
          sourceFile: sourceFile,
          sizeBytes: size,
          sha256: await _hashFile(sourceFile),
        ),
      );
    }

    final datasetId = _datasetId(prepared);
    final datasetsRoot = Directory(p.join(destinationPath, 'datasets'));
    await datasetsRoot.create(recursive: true);
    final finalDirectory = Directory(p.join(datasetsRoot.path, datasetId));
    if (await finalDirectory.exists()) {
      return _reuseExisting(finalDirectory, datasetId, prepared);
    }

    final stagingDirectory = Directory(
      p.join(
        datasetsRoot.path,
        '.import-${DateTime.now().toUtc().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}',
      ),
    );
    await stagingDirectory.create();

    try {
      final manifestFiles = <String, WeComPackageFile>{};
      for (final input in prepared) {
        final copiedFile = await input.sourceFile.copy(
          p.join(stagingDirectory.path, input.contract.fileName),
        );
        final copiedHash = await _hashFile(copiedFile);
        if (copiedHash != input.sha256 ||
            await copiedFile.length() != input.sizeBytes) {
          throw WeComPackageException(
            WeComPackageIssueCode.copyMismatch,
            'Copied database does not match its source',
            fileName: input.contract.fileName,
          );
        }

        if (input.sizeBytes > 0) {
          await _validateDatabase(copiedFile, input.contract);
        } else if (input.contract.tables.isNotEmpty ||
            input.contract.indexes.isNotEmpty) {
          throw WeComPackageException(
            WeComPackageIssueCode.schemaMismatch,
            'Empty placeholder has a non-empty schema contract',
            fileName: input.contract.fileName,
          );
        }

        manifestFiles[input.contract.fileName] = WeComPackageFile(
          fileName: input.contract.fileName,
          sha256: input.sha256,
          sizeBytes: input.sizeBytes,
          tableCount: input.contract.tables.length,
          indexCount: input.contract.indexes.length,
          isEmptyPlaceholder: input.sizeBytes == 0,
        );
      }

      for (final input in prepared) {
        if (await _hashFile(input.sourceFile) != input.sha256 ||
            await input.sourceFile.length() != input.sizeBytes) {
          throw WeComPackageException(
            WeComPackageIssueCode.sourceChanged,
            'Source changed during import',
            fileName: input.contract.fileName,
          );
        }
      }

      await _writeManifest(
        stagingDirectory,
        datasetId,
        manifestFiles.values.toList(growable: false),
      );

      try {
        await stagingDirectory.rename(finalDirectory.path);
      } on FileSystemException catch (error) {
        if (await finalDirectory.exists()) {
          await _deleteIfExists(stagingDirectory);
          return _reuseExisting(finalDirectory, datasetId, prepared);
        }
        throw WeComPackageException(
          WeComPackageIssueCode.importCommitFailed,
          'Could not commit the validated package',
          cause: error,
        );
      }

      return WeComImportedPackage._(
        datasetId: datasetId,
        directory: finalDirectory,
        files: Map.unmodifiable(manifestFiles),
        reusedExisting: false,
      );
    } catch (_) {
      await _deleteIfExists(stagingDirectory);
      rethrow;
    }
  }

  Future<void> _validateDatabase(
    File file,
    WeComDatabaseContract databaseContract,
  ) async {
    Database? database;
    try {
      database = await databaseFactory.openDatabase(
        file.path,
        options: OpenDatabaseOptions(
          readOnly: true,
          singleInstance: false,
        ),
      );

      final integrityRows = await database.rawQuery('PRAGMA integrity_check');
      final integrityMessages = integrityRows
          .expand((row) => row.values)
          .where((value) => value != null)
          .map((value) => value.toString().toLowerCase())
          .toList(growable: false);
      if (integrityMessages.length != 1 || integrityMessages.single != 'ok') {
        throw WeComPackageException(
          WeComPackageIssueCode.integrityCheckFailed,
          'SQLite integrity_check failed: $integrityMessages',
          fileName: databaseContract.fileName,
        );
      }

      final foreignKeyRows =
          await database.rawQuery('PRAGMA foreign_key_check');
      if (foreignKeyRows.isNotEmpty) {
        throw WeComPackageException(
          WeComPackageIssueCode.integrityCheckFailed,
          'SQLite foreign_key_check reported ${foreignKeyRows.length} rows',
          fileName: databaseContract.fileName,
        );
      }

      final tableRows = await database.rawQuery(
        "SELECT name, sql FROM sqlite_master "
        "WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
      );
      final actualTables =
          tableRows.map((row) => row['name']! as String).toSet();
      final tableSql = {
        for (final row in tableRows)
          row['name']! as String: row['sql'] as String?,
      };
      _requireEqualNames(
        kind: 'tables',
        expected: databaseContract.tables.keys.toSet(),
        actual: actualTables,
        fileName: databaseContract.fileName,
      );
      _validateFtsTokenizers(databaseContract, tableSql);

      final indexRows = await database.rawQuery(
        "SELECT name FROM sqlite_master "
        "WHERE type = 'index' AND sql IS NOT NULL",
      );
      final actualIndexes =
          indexRows.map((row) => row['name']! as String).toSet();
      _requireEqualNames(
        kind: 'indexes',
        expected: databaseContract.indexes,
        actual: actualIndexes,
        fileName: databaseContract.fileName,
      );

      for (final entry in databaseContract.tables.entries) {
        if (databaseContract.skipColumnValidation.contains(entry.key)) {
          continue;
        }
        final escapedName = entry.key.replaceAll('"', '""');
        final columnRows =
            await database.rawQuery('PRAGMA table_info("$escapedName")');
        if (columnRows.length != entry.value.length) {
          throw WeComPackageException(
            WeComPackageIssueCode.schemaMismatch,
            'Column count differs for ${entry.key}: '
            'expected ${entry.value.length}, got ${columnRows.length}',
            fileName: databaseContract.fileName,
          );
        }
        for (var index = 0; index < entry.value.length; index++) {
          if (!entry.value[index].matches(columnRows[index])) {
            throw WeComPackageException(
              WeComPackageIssueCode.schemaMismatch,
              'Column ${index + 1} differs for ${entry.key}',
              fileName: databaseContract.fileName,
            );
          }
        }
      }
    } on WeComPackageException {
      rethrow;
    } catch (error) {
      throw WeComPackageException(
        WeComPackageIssueCode.sqliteOpenFailed,
        'Could not inspect the copied SQLite database',
        fileName: databaseContract.fileName,
        cause: error,
      );
    } finally {
      await database?.close();
    }
  }

  void _validateFtsTokenizers(
    WeComDatabaseContract databaseContract,
    Map<String, String?> tableSql,
  ) {
    final tokenizerPattern = RegExp(
      r'''tokenize\s*=\s*['"]?([a-zA-Z0-9_]+)''',
      caseSensitive: false,
    );
    for (final entry in databaseContract.expectedFtsTokenizers.entries) {
      final sql = tableSql[entry.key]?.toLowerCase();
      if (sql == null || !sql.contains('using fts5')) {
        throw WeComPackageException(
          WeComPackageIssueCode.schemaMismatch,
          'Expected an FTS5 virtual table for ${entry.key}',
          fileName: databaseContract.fileName,
        );
      }
      final match = tokenizerPattern.firstMatch(sql);
      final tokenizer = match?.group(1)?.toLowerCase() ?? 'unicode61';
      if (entry.value != tokenizer) {
        throw WeComPackageException(
          WeComPackageIssueCode.schemaMismatch,
          'Unsupported FTS tokenizer $tokenizer for ${entry.key}',
          fileName: databaseContract.fileName,
        );
      }
    }
  }

  void _requireEqualNames({
    required String kind,
    required Set<String> expected,
    required Set<String> actual,
    required String fileName,
  }) {
    if (expected.length == actual.length && expected.containsAll(actual)) {
      return;
    }
    final missing = expected.difference(actual).toList()..sort();
    final unexpected = actual.difference(expected).toList()..sort();
    throw WeComPackageException(
      WeComPackageIssueCode.schemaMismatch,
      'Schema $kind differ; missing=$missing, unexpected=$unexpected',
      fileName: fileName,
    );
  }

  Future<WeComImportedPackage> _reuseExisting(
    Directory directory,
    String datasetId,
    List<_PreparedInput> prepared,
  ) async {
    final manifest = File(p.join(directory.path, manifestFileName));
    if (!await manifest.exists()) {
      throw const WeComPackageException(
        WeComPackageIssueCode.existingPackageCorrupt,
        'Existing package manifest is missing',
      );
    }

    late Map<String, Map<String, Object?>> manifestFiles;
    try {
      final decoded = jsonDecode(await manifest.readAsString());
      if (decoded is! Map) {
        throw const FormatException('Manifest must be a JSON object');
      }
      final document = Map<String, Object?>.from(decoded);
      final rawFiles = document['files'];
      if (document['formatVersion'] != 1 ||
          document['datasetId'] != datasetId ||
          rawFiles is! List) {
        throw const FormatException('Manifest identity is invalid');
      }
      manifestFiles = <String, Map<String, Object?>>{};
      for (final rawFile in rawFiles) {
        if (rawFile is! Map) {
          throw const FormatException('Manifest file entry is invalid');
        }
        final entry = Map<String, Object?>.from(rawFile);
        final fileName = entry['fileName'];
        if (fileName is! String || manifestFiles.containsKey(fileName)) {
          throw const FormatException('Manifest contains duplicate files');
        }
        manifestFiles[fileName] = entry;
      }
    } catch (error) {
      throw WeComPackageException(
        WeComPackageIssueCode.existingPackageCorrupt,
        'Existing package manifest is invalid',
        cause: error,
      );
    }

    if (manifestFiles.length != prepared.length) {
      throw const WeComPackageException(
        WeComPackageIssueCode.existingPackageCorrupt,
        'Existing package manifest has an unexpected file set',
      );
    }

    final files = <String, WeComPackageFile>{};
    for (final input in prepared) {
      final manifestEntry = manifestFiles[input.contract.fileName];
      if (manifestEntry == null ||
          manifestEntry['sha256'] != input.sha256 ||
          manifestEntry['sizeBytes'] != input.sizeBytes) {
        throw WeComPackageException(
          WeComPackageIssueCode.existingPackageCorrupt,
          'Existing package manifest does not match its dataset ID',
          fileName: input.contract.fileName,
        );
      }

      final file = File(p.join(directory.path, input.contract.fileName));
      if (!await file.exists() ||
          await file.length() != input.sizeBytes ||
          await _hashFile(file) != input.sha256) {
        throw WeComPackageException(
          WeComPackageIssueCode.existingPackageCorrupt,
          'Existing package file does not match its dataset ID',
          fileName: input.contract.fileName,
        );
      }
      if (input.sizeBytes > 0) {
        await _validateDatabase(file, input.contract);
      } else if (input.contract.tables.isNotEmpty ||
          input.contract.indexes.isNotEmpty) {
        throw WeComPackageException(
          WeComPackageIssueCode.schemaMismatch,
          'Empty placeholder has a non-empty schema contract',
          fileName: input.contract.fileName,
        );
      }

      files[input.contract.fileName] = WeComPackageFile(
        fileName: input.contract.fileName,
        sha256: input.sha256,
        sizeBytes: input.sizeBytes,
        tableCount: input.contract.tables.length,
        indexCount: input.contract.indexes.length,
        isEmptyPlaceholder: input.sizeBytes == 0,
      );
    }

    return WeComImportedPackage._(
      datasetId: datasetId,
      directory: directory,
      files: Map.unmodifiable(files),
      reusedExisting: true,
    );
  }

  Future<void> _writeManifest(
    Directory directory,
    String datasetId,
    List<WeComPackageFile> files,
  ) async {
    files.sort((left, right) => left.fileName.compareTo(right.fileName));
    final json = const JsonEncoder.withIndent('  ').convert({
      'formatVersion': 1,
      'datasetId': datasetId,
      'createdAtUtc': DateTime.now().toUtc().toIso8601String(),
      'contractScope': contract.scope,
      'files': files.map((file) => file.toJson()).toList(growable: false),
    });
    await File(p.join(directory.path, manifestFileName))
        .writeAsString('$json\n', flush: true);
  }

  Future<bool> _hasSqliteHeader(File file) async {
    final bytes = await file.openRead(0, _sqliteHeader.length).fold<List<int>>(
      <int>[],
      (buffer, chunk) => buffer..addAll(chunk),
    );
    if (bytes.length != _sqliteHeader.length) {
      return false;
    }
    for (var index = 0; index < _sqliteHeader.length; index++) {
      if (bytes[index] != _sqliteHeader[index]) {
        return false;
      }
    }
    return true;
  }

  Future<String> _hashFile(File file) async {
    return (await sha256.bind(file.openRead()).first).toString();
  }

  String _datasetId(List<_PreparedInput> inputs) {
    final sorted = inputs.toList()
      ..sort(
        (left, right) =>
            left.contract.fileName.compareTo(right.contract.fileName),
      );
    final material = StringBuffer('wecom-package-v1\n');
    for (final input in sorted) {
      material
        ..write(input.contract.fileName)
        ..write('\u0000')
        ..write(input.sizeBytes)
        ..write('\u0000')
        ..write(input.sha256)
        ..write('\n');
    }
    return sha256.convert(utf8.encode(material.toString())).toString();
  }

  Future<void> _deleteIfExists(Directory directory) async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}

class _PreparedInput {
  const _PreparedInput({
    required this.contract,
    required this.sourceFile,
    required this.sizeBytes,
    required this.sha256,
  });

  final WeComDatabaseContract contract;
  final File sourceFile;
  final int sizeBytes;
  final String sha256;
}
