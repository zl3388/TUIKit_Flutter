import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../domain/wecom_message_models.dart';
import 'wecom_media_repository.dart';

enum WeComMediaSnapshotIssueCode {
  invalidDatasetId,
  noMatchingAccount,
  ambiguousAccount,
  invalidCacheMapping,
  sourceChanged,
  copyMismatch,
  existingSnapshotCorrupt,
}

class WeComMediaSnapshotException implements Exception {
  const WeComMediaSnapshotException(this.code, this.message, {this.cause});

  final WeComMediaSnapshotIssueCode code;
  final String message;
  final Object? cause;

  @override
  String toString() => 'WeComMediaSnapshotException.${code.name}: $message';
}

class WeComMediaSnapshot {
  const WeComMediaSnapshot._({
    required this.datasetId,
    required this.directory,
    required this.mediaRoot,
    required this.cacheMappingFile,
    required this.referencedFileCount,
    required this.copiedFileCount,
    required this.reusedExisting,
  });

  final String datasetId;
  final Directory directory;
  final Directory mediaRoot;
  final File cacheMappingFile;
  final int referencedFileCount;
  final int copiedFileCount;
  final bool reusedExisting;

  Future<Database> openCacheMappingReadOnly(DatabaseFactory factory) {
    return factory.openDatabase(
      cacheMappingFile.path,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
  }
}

class WeComMediaSnapshotManager {
  const WeComMediaSnapshotManager({
    required Directory destinationRoot,
    required DatabaseFactory databaseFactory,
  })  : _destinationRoot = destinationRoot,
        _databaseFactory = databaseFactory;

  static const manifestFileName = 'media.json';
  static const _formatVersion = 1;
  static const _copyAttempts = 3;
  static final _datasetIdPattern = RegExp(r'^[0-9a-f]{64}$');
  static final _cacheMappingNamePattern = RegExp(r'^[0-9a-f]{32}\.db$');

  final Directory _destinationRoot;
  final DatabaseFactory _databaseFactory;

  Future<WeComMediaSnapshot> importReferencedMedia({
    required String datasetId,
    required File fileDatabase,
    required File messageDatabase,
    required Directory wxWorkRoot,
  }) async {
    _requireDatasetId(datasetId);
    final existing = await openSnapshot(datasetId);
    if (existing != null) {
      return WeComMediaSnapshot._(
        datasetId: existing.datasetId,
        directory: existing.directory,
        mediaRoot: existing.mediaRoot,
        cacheMappingFile: existing.cacheMappingFile,
        referencedFileCount: existing.referencedFileCount,
        copiedFileCount: existing.copiedFileCount,
        reusedExisting: true,
      );
    }
    if (!await fileDatabase.exists() || !await messageDatabase.exists()) {
      throw const WeComMediaSnapshotException(
        WeComMediaSnapshotIssueCode.noMatchingAccount,
        'The imported file.db or message.db is missing',
      );
    }

    final mediaRoot = Directory(p.join(_destinationRoot.path, 'media'));
    await mediaRoot.create(recursive: true);
    final staging = Directory(
      p.join(
        mediaRoot.path,
        '.import-${DateTime.now().toUtc().microsecondsSinceEpoch}-'
        '${Random.secure().nextInt(1 << 32)}',
      ),
    );
    await staging.create();

    Database? fileConnection;
    Database? messageConnection;
    Database? cacheMappingConnection;
    try {
      fileConnection = await _openReadOnly(fileDatabase);
      final selected = await _selectAccount(
        wxWorkRoot: wxWorkRoot,
        fileDatabase: fileConnection,
        staging: staging,
      );
      final mappingDirectory = Directory(p.join(staging.path, 'CacheMapping'));
      final copiedMapping = await _copyStableTrio(
        selected.cacheMappingFile,
        mappingDirectory,
      );
      await _validateCacheMapping(copiedMapping);
      cacheMappingConnection = await _openReadOnly(copiedMapping);
      messageConnection = await _openReadOnly(messageDatabase);

      final locator = WeComMediaRepository(
        fileDatabase: fileConnection,
        cacheMappingDatabase: cacheMappingConnection,
        mediaRoot: selected.cacheRoot,
      );
      final records = await locator.listReferencedFiles();
      final messages = await _loadFallbackMessages(
        messageConnection,
        records
            .where(
              (record) => record.name.isEmpty && !_isHttpUrl(record.serverId),
            )
            .map((record) => record.messageId),
      );
      final copiedFiles = <String, _ManifestFile>{};
      final references = <Map<String, Object?>>[];
      final snapshotCache = Directory(p.join(staging.path, 'Cache'));
      await snapshotCache.create();

      for (final record in records) {
        final attachment = await locator.locateFile(
          record,
          message: messages[record.messageId],
        );
        final relativePath = attachment.location.relativePath;
        references.add({
          'origin': record.origin,
          'messageId': record.messageId,
          'fileIndex': record.fileIndex,
          'status': attachment.location.status.name,
          'relativePath': relativePath,
        });
        final source = attachment.location.file;
        if (!attachment.location.isAvailable ||
            source == null ||
            relativePath == null) {
          continue;
        }
        final safeRelative = _requireSafeRelativePath(relativePath);
        final sourceHash = await _hashFile(source);
        final existingFile = copiedFiles[safeRelative];
        if (existingFile != null) {
          if (existingFile.sha256 != sourceHash ||
              existingFile.sizeBytes != await source.length()) {
            throw WeComMediaSnapshotException(
              WeComMediaSnapshotIssueCode.copyMismatch,
              'Two referenced files resolve to different bytes at '
              '$safeRelative',
            );
          }
          continue;
        }
        final destination = File(
          p.join(snapshotCache.path, safeRelative.replaceAll('/', p.separator)),
        );
        await destination.parent.create(recursive: true);
        final sourceSize = await source.length();
        await source.copy(destination.path);
        final destinationHash = await _hashFile(destination);
        if (destinationHash != sourceHash ||
            await destination.length() != sourceSize ||
            await _hashFile(source) != sourceHash) {
          throw WeComMediaSnapshotException(
            WeComMediaSnapshotIssueCode.copyMismatch,
            'Referenced media changed or copied incorrectly: $safeRelative',
          );
        }
        copiedFiles[safeRelative] = _ManifestFile(
          relativePath: safeRelative,
          sha256: sourceHash,
          sizeBytes: sourceSize,
        );
      }

      await cacheMappingConnection.close();
      cacheMappingConnection = null;
      final mappingFiles = await _manifestForTrio(copiedMapping);
      await _writeManifest(
        staging,
        datasetId: datasetId,
        cacheMappingFileName: p.basename(copiedMapping.path),
        cacheMappingFiles: mappingFiles,
        files: copiedFiles.values.toList(growable: false),
        references: references,
      );

      final finalDirectory = _snapshotDirectory(datasetId);
      try {
        await staging.rename(finalDirectory.path);
      } on FileSystemException {
        final raced = await openSnapshot(datasetId);
        if (raced == null) {
          rethrow;
        }
        await _deleteIfExists(staging);
        return WeComMediaSnapshot._(
          datasetId: raced.datasetId,
          directory: raced.directory,
          mediaRoot: raced.mediaRoot,
          cacheMappingFile: raced.cacheMappingFile,
          referencedFileCount: raced.referencedFileCount,
          copiedFileCount: raced.copiedFileCount,
          reusedExisting: true,
        );
      }
      return (await openSnapshot(datasetId))!;
    } catch (_) {
      await _deleteIfExists(staging);
      rethrow;
    } finally {
      await cacheMappingConnection?.close();
      await messageConnection?.close();
      await fileConnection?.close();
    }
  }

  Future<WeComMediaSnapshot?> openSnapshot(
    String datasetId, {
    bool verifyMediaHashes = true,
  }) async {
    _requireDatasetId(datasetId);
    final directory = _snapshotDirectory(datasetId);
    if (!await directory.exists()) {
      return null;
    }
    try {
      final raw = jsonDecode(
        await File(p.join(directory.path, manifestFileName)).readAsString(),
      );
      if (raw is! Map) {
        throw const FormatException('Manifest must be an object');
      }
      final document = Map<String, Object?>.from(raw);
      final cacheMapping = document['cacheMapping'];
      final files = document['files'];
      final references = document['references'];
      if (document['formatVersion'] != _formatVersion ||
          document['datasetId'] != datasetId ||
          cacheMapping is! Map ||
          files is! List ||
          references is! List) {
        throw const FormatException('Manifest identity is invalid');
      }
      final mapping = Map<String, Object?>.from(cacheMapping);
      final mappingName = mapping['fileName'];
      final mappingFiles = mapping['files'];
      if (mappingName is! String ||
          !_cacheMappingNamePattern.hasMatch(mappingName) ||
          mappingFiles is! List ||
          mappingFiles.length != 3) {
        throw const FormatException('CacheMapping manifest is invalid');
      }
      final expectedMappingNames = {
        mappingName,
        '$mappingName-wal',
        '$mappingName-shm',
      };
      final actualMappingNames = <String>{};
      for (final rawFile in mappingFiles) {
        final entry = _ManifestFile.fromJson(rawFile);
        if (!expectedMappingNames.contains(entry.relativePath) ||
            !actualMappingNames.add(entry.relativePath)) {
          throw const FormatException('CacheMapping file set is invalid');
        }
        await _requireManifestFile(
          File(p.join(directory.path, 'CacheMapping', entry.relativePath)),
          entry,
        );
      }
      if (actualMappingNames.length != expectedMappingNames.length) {
        throw const FormatException('CacheMapping sidecars are incomplete');
      }

      final mediaPaths = <String>{};
      for (final rawFile in files) {
        final entry = _ManifestFile.fromJson(rawFile);
        final relative = _requireSafeRelativePath(entry.relativePath);
        if (!mediaPaths.add(relative)) {
          throw const FormatException('Media manifest has duplicate paths');
        }
        await _requireManifestFile(
          File(
            p.join(
              directory.path,
              'Cache',
              relative.replaceAll('/', p.separator),
            ),
          ),
          entry,
          verifyHash: verifyMediaHashes,
        );
      }
      final referenceKeys = <String>{};
      final availablePaths = <String>{};
      for (final rawReference in references) {
        if (rawReference is! Map) {
          throw const FormatException('Media reference is invalid');
        }
        final reference = Map<String, Object?>.from(rawReference);
        if (reference['origin'] is! int ||
            reference['messageId'] is! int ||
            reference['fileIndex'] is! int ||
            reference['status'] is! String ||
            !WeComMediaLocationStatus.values.any(
              (status) => status.name == reference['status'],
            ) ||
            (reference['relativePath'] != null &&
                reference['relativePath'] is! String)) {
          throw const FormatException('Media reference fields are invalid');
        }
        final referenceKey = '${reference['origin']}:${reference['messageId']}:'
            '${reference['fileIndex']}';
        if (!referenceKeys.add(referenceKey)) {
          throw const FormatException('Media reference is duplicated');
        }
        final relativePath = reference['relativePath'] as String?;
        final isAvailable =
            reference['status'] == WeComMediaLocationStatus.ok.name;
        if (isAvailable && relativePath == null) {
          throw const FormatException(
            'Available media reference has no relative path',
          );
        }
        if (relativePath != null) {
          final relative = _requireSafeRelativePath(relativePath);
          if (isAvailable) {
            availablePaths.add(relative);
          }
        }
      }
      if (availablePaths.length != mediaPaths.length ||
          !availablePaths.containsAll(mediaPaths)) {
        throw const FormatException(
          'Available media references do not match the file manifest',
        );
      }
      return WeComMediaSnapshot._(
        datasetId: datasetId,
        directory: directory,
        mediaRoot: Directory(p.join(directory.path, 'Cache')),
        cacheMappingFile: File(
          p.join(directory.path, 'CacheMapping', mappingName),
        ),
        referencedFileCount: references.length,
        copiedFileCount: files.length,
        reusedExisting: false,
      );
    } catch (error) {
      if (error is WeComMediaSnapshotException) {
        rethrow;
      }
      throw WeComMediaSnapshotException(
        WeComMediaSnapshotIssueCode.existingSnapshotCorrupt,
        'Existing media snapshot is invalid',
        cause: error,
      );
    }
  }

  Future<_SelectedAccount> _selectAccount({
    required Directory wxWorkRoot,
    required Database fileDatabase,
    required Directory staging,
  }) async {
    final winners = <_SelectedAccount>[];
    if (!await wxWorkRoot.exists()) {
      throw const WeComMediaSnapshotException(
        WeComMediaSnapshotIssueCode.noMatchingAccount,
        'The selected WXWork directory does not exist',
      );
    }
    final fileMd5s = await _fileMd5Set(fileDatabase);
    await for (final child in wxWorkRoot.list(followLinks: false)) {
      if (child is! Directory || !await _isAccountDirectory(child)) {
        continue;
      }
      final candidates = await _cacheMappingCandidates(child);
      for (var index = 0; index < candidates.length; index++) {
        final selectionDirectory = Directory(
          p.join(
            staging.path,
            '.candidate-${p.basename(child.path)}-$index',
          ),
        );
        try {
          final copied = await _copyStableTrio(
            candidates[index],
            selectionDirectory,
          );
          await _validateCacheMapping(copied);
          final score = await _scoreCandidate(
            copied,
            Directory(p.join(child.path, 'Cache')),
            fileMd5s,
          );
          if (score.md5Intersection > 0 && score.onDisk > 0) {
            winners.add(
              _SelectedAccount(
                cacheRoot: Directory(p.join(child.path, 'Cache')),
                cacheMappingFile: candidates[index],
              ),
            );
          }
        } on WeComMediaSnapshotException {
          // Invalid candidates do not become account matches.
        } finally {
          await _deleteIfExists(selectionDirectory);
        }
      }
    }
    if (winners.isEmpty) {
      throw const WeComMediaSnapshotException(
        WeComMediaSnapshotIssueCode.noMatchingAccount,
        'No account uniquely joins CacheMapping, Cache, and file.db',
      );
    }
    if (winners.length != 1) {
      throw const WeComMediaSnapshotException(
        WeComMediaSnapshotIssueCode.ambiguousAccount,
        'Multiple accounts join the imported file.db',
      );
    }
    return winners.single;
  }

  Future<_CandidateScore> _scoreCandidate(
    File cacheMappingFile,
    Directory cacheRoot,
    Set<String> fileMd5s,
  ) async {
    final database = await _openReadOnly(cacheMappingFile);
    try {
      final rows = await database.query(
        'mapping',
        columns: ['type', 'file_name', 'file_md5'],
      );
      final mappingMd5s = <String>{};
      var onDisk = 0;
      for (final row in rows) {
        final type = row['type'] as int? ?? 0;
        final fileName = row['file_name'] as String? ?? '';
        final fileMd5 = row['file_md5']?.toString().trim().toLowerCase() ?? '';
        if (fileMd5.isNotEmpty && fileMd5 != '0') {
          mappingMd5s.add(fileMd5);
        }
        final relative = WeComMediaRepository.relocateMappingPath(
          fileName,
          type,
        );
        if (relative != null &&
            await File(
              p.join(
                cacheRoot.path,
                relative.replaceAll('/', p.separator),
              ),
            ).exists()) {
          onDisk += 1;
        }
      }
      return _CandidateScore(
        md5Intersection: mappingMd5s.intersection(fileMd5s).length,
        onDisk: onDisk,
      );
    } finally {
      await database.close();
    }
  }

  Future<File> _copyStableTrio(File sourceDatabase, Directory target) async {
    for (var attempt = 0; attempt < _copyAttempts; attempt++) {
      await _deleteIfExists(target);
      await target.create(recursive: true);
      final sources = _snapshotTrio(sourceDatabase);
      if (!await Future.wait(sources.map((file) => file.exists())).then(
        (values) => values.every((exists) => exists),
      )) {
        throw const WeComMediaSnapshotException(
          WeComMediaSnapshotIssueCode.invalidCacheMapping,
          'The live CacheMapping database must include db, wal, and shm',
        );
      }
      final before = await Future.wait(sources.map(_fingerprint));
      for (final source in sources) {
        await source.copy(p.join(target.path, p.basename(source.path)));
      }
      final after = await Future.wait(sources.map(_fingerprint));
      if (_sameFingerprints(before, after)) {
        final destinations = sources
            .map((source) => File(p.join(target.path, p.basename(source.path))))
            .toList(growable: false);
        final copied = await Future.wait(destinations.map(_fingerprint));
        if (_sameFingerprints(before, copied)) {
          return destinations.first;
        }
      }
    }
    throw const WeComMediaSnapshotException(
      WeComMediaSnapshotIssueCode.sourceChanged,
      'CacheMapping changed while its WAL snapshot was copied',
    );
  }

  Future<void> _validateCacheMapping(File file) async {
    if (!await _hasSqliteHeader(file)) {
      throw const WeComMediaSnapshotException(
        WeComMediaSnapshotIssueCode.invalidCacheMapping,
        'CacheMapping is not plaintext SQLite',
      );
    }
    Database? database;
    try {
      database = await _openReadOnly(file);
      final integrity = await database.rawQuery('PRAGMA integrity_check');
      final journal = await database.rawQuery('PRAGMA journal_mode');
      final columns = await database.rawQuery('PRAGMA table_info(mapping)');
      final indexes = await database.rawQuery('PRAGMA index_list(mapping)');
      final columnNames = columns.map((row) => row['name']).toSet();
      final indexNames = indexes.map((row) => row['name']).toSet();
      if (integrity.single.values.single != 'ok' ||
          journal.single.values.single.toString().toLowerCase() != 'wal' ||
          !columnNames.containsAll({
            'type',
            'key',
            'file_name',
            'last_modify_time',
            'file_md5',
          }) ||
          !indexNames.contains('file_md5_index_') ||
          !indexNames.contains('file_name_index_')) {
        throw const FormatException('CacheMapping schema mismatch');
      }
    } catch (error) {
      throw WeComMediaSnapshotException(
        WeComMediaSnapshotIssueCode.invalidCacheMapping,
        'CacheMapping failed schema or integrity validation',
        cause: error,
      );
    } finally {
      await database?.close();
    }
  }

  Future<Map<int, WeComMessageRecord>> _loadFallbackMessages(
    Database database,
    Iterable<int> messageIds,
  ) async {
    final ids = messageIds.toSet().toList(growable: false);
    final messages = <int, WeComMessageRecord>{};
    for (var offset = 0; offset < ids.length; offset += 500) {
      final page = ids.sublist(offset, min(offset + 500, ids.length));
      final placeholders = List.filled(page.length, '?').join(',');
      final rows = await database.rawQuery(
        '''
SELECT message_id, sequence, sender_id, conversation_id,
       content_type, send_time, content
FROM message_table
WHERE message_id IN ($placeholders)
''',
        page,
      );
      for (final row in rows) {
        final message = WeComMessageRecord.fromRow(row);
        messages[message.messageId] = message;
      }
    }
    return messages;
  }

  Future<void> _writeManifest(
    Directory directory, {
    required String datasetId,
    required String cacheMappingFileName,
    required List<_ManifestFile> cacheMappingFiles,
    required List<_ManifestFile> files,
    required List<Map<String, Object?>> references,
  }) async {
    files
        .sort((left, right) => left.relativePath.compareTo(right.relativePath));
    references.sort((left, right) {
      final byMessage =
          (left['messageId']! as int).compareTo(right['messageId']! as int);
      return byMessage != 0
          ? byMessage
          : (left['fileIndex']! as int).compareTo(right['fileIndex']! as int);
    });
    final json = const JsonEncoder.withIndent('  ').convert({
      'formatVersion': _formatVersion,
      'datasetId': datasetId,
      'createdAtUtc': DateTime.now().toUtc().toIso8601String(),
      'cacheMapping': {
        'fileName': cacheMappingFileName,
        'files': cacheMappingFiles.map((file) => file.toJson()).toList(),
      },
      'files': files.map((file) => file.toJson()).toList(),
      'references': references,
    });
    await File(p.join(directory.path, manifestFileName))
        .writeAsString('$json\n', flush: true);
  }

  Future<List<_ManifestFile>> _manifestForTrio(File database) async {
    final entries = <_ManifestFile>[];
    for (final file in _snapshotTrio(database)) {
      if (!await file.exists()) {
        throw const WeComMediaSnapshotException(
          WeComMediaSnapshotIssueCode.copyMismatch,
          'Copied CacheMapping sidecars are incomplete',
        );
      }
      entries.add(
        _ManifestFile(
          relativePath: p.basename(file.path),
          sha256: await _hashFile(file),
          sizeBytes: await file.length(),
        ),
      );
    }
    return entries;
  }

  Future<void> _requireManifestFile(
    File file,
    _ManifestFile entry, {
    bool verifyHash = true,
  }) async {
    if (!await file.exists() ||
        await file.length() != entry.sizeBytes ||
        (verifyHash && await _hashFile(file) != entry.sha256)) {
      throw const FormatException('Manifest file does not match its metadata');
    }
  }

  Future<Set<String>> _fileMd5Set(Database database) async {
    final rows = await database.query('file_table4', columns: ['md5']);
    return rows
        .map((row) => row['md5']?.toString().trim().toLowerCase() ?? '')
        .where((value) => value.isNotEmpty)
        .toSet();
  }

  Future<bool> _isAccountDirectory(Directory directory) async {
    return await Directory(p.join(directory.path, 'Cache')).exists() &&
        await Directory(p.join(directory.path, 'CacheMapping')).exists() &&
        await Directory(p.join(directory.path, 'Data')).exists();
  }

  Future<List<File>> _cacheMappingCandidates(Directory account) async {
    final directory = Directory(p.join(account.path, 'CacheMapping'));
    final files = <File>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File &&
          _cacheMappingNamePattern.hasMatch(p.basename(entity.path))) {
        files.add(entity);
      }
    }
    files.sort((left, right) => left.path.compareTo(right.path));
    return files;
  }

  Future<Database> _openReadOnly(File file) {
    return _databaseFactory.openDatabase(
      file.path,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
  }

  Directory _snapshotDirectory(String datasetId) =>
      Directory(p.join(_destinationRoot.path, 'media', datasetId));

  static List<File> _snapshotTrio(File database) => [
        database,
        File('${database.path}-wal'),
        File('${database.path}-shm'),
      ];

  static Future<_FileFingerprint> _fingerprint(File file) async {
    return _FileFingerprint(
      sizeBytes: await file.length(),
      sha256: await _hashFile(file),
    );
  }

  static bool _sameFingerprints(
    List<_FileFingerprint> left,
    List<_FileFingerprint> right,
  ) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) {
        return false;
      }
    }
    return true;
  }

  static Future<bool> _hasSqliteHeader(File file) async {
    const expected = 'SQLite format 3\u0000';
    final bytes = await file.openRead(0, expected.length).fold<List<int>>(
      <int>[],
      (buffer, chunk) => buffer..addAll(chunk),
    );
    return bytes.length == expected.length && latin1.decode(bytes) == expected;
  }

  static String _requireSafeRelativePath(String value) {
    final normalized = value.replaceAll('\\', '/');
    if (normalized.isEmpty ||
        p.posix.isAbsolute(normalized) ||
        p.windows.isAbsolute(value) ||
        normalized.contains('://') ||
        normalized.split('/').contains('..')) {
      throw const FormatException('Unsafe media relative path');
    }
    return normalized;
  }

  static bool _isHttpUrl(String value) {
    final lower = value.toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://');
  }

  static Future<String> _hashFile(File file) async {
    return (await sha256.bind(file.openRead()).first).toString();
  }

  static Future<void> _deleteIfExists(Directory directory) async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  void _requireDatasetId(String datasetId) {
    if (!_datasetIdPattern.hasMatch(datasetId)) {
      throw const WeComMediaSnapshotException(
        WeComMediaSnapshotIssueCode.invalidDatasetId,
        'Dataset ID must be 64 lowercase hexadecimal characters',
      );
    }
  }
}

class _SelectedAccount {
  const _SelectedAccount({
    required this.cacheRoot,
    required this.cacheMappingFile,
  });

  final Directory cacheRoot;
  final File cacheMappingFile;
}

class _CandidateScore {
  const _CandidateScore({
    required this.md5Intersection,
    required this.onDisk,
  });

  final int md5Intersection;
  final int onDisk;
}

class _ManifestFile {
  const _ManifestFile({
    required this.relativePath,
    required this.sha256,
    required this.sizeBytes,
  });

  final String relativePath;
  final String sha256;
  final int sizeBytes;

  factory _ManifestFile.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Manifest file entry must be an object');
    }
    final entry = Map<String, Object?>.from(raw);
    final relativePath = entry['relativePath'];
    final sha = entry['sha256'];
    final size = entry['sizeBytes'];
    if (relativePath is! String ||
        sha is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha) ||
        size is! int ||
        size < 0) {
      throw const FormatException('Manifest file fields are invalid');
    }
    return _ManifestFile(
      relativePath: relativePath,
      sha256: sha,
      sizeBytes: size,
    );
  }

  Map<String, Object> toJson() => {
        'relativePath': relativePath,
        'sha256': sha256,
        'sizeBytes': sizeBytes,
      };
}

class _FileFingerprint {
  const _FileFingerprint({required this.sizeBytes, required this.sha256});

  final int sizeBytes;
  final String sha256;

  @override
  bool operator ==(Object other) =>
      other is _FileFingerprint &&
      other.sizeBytes == sizeBytes &&
      other.sha256 == sha256;

  @override
  int get hashCode => Object.hash(sizeBytes, sha256);
}
