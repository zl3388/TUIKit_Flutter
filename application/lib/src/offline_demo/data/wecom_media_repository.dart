import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../domain/wecom_message_models.dart';
import 'wecom_protobuf_reader.dart';

enum WeComMediaLocationStatus {
  ok,
  missing,
  sizeMismatch,
  hashMismatch,
  noUniqueMapping,
  urlNotOffline,
  kindUnknown,
}

enum WeComMediaLocateMethod {
  canonicalPath,
  cacheMappingType2,
}

class WeComMediaLocation {
  const WeComMediaLocation({
    required this.status,
    required this.method,
    this.relativePath,
    this.file,
  });

  final WeComMediaLocationStatus status;
  final WeComMediaLocateMethod method;
  final String? relativePath;
  final File? file;

  bool get isAvailable => status == WeComMediaLocationStatus.ok;
}

class WeComMediaAttachment {
  const WeComMediaAttachment({
    required this.origin,
    required this.messageId,
    required this.fileIndex,
    required this.messageType,
    required this.name,
    required this.sizeBytes,
    required this.location,
  });

  final int origin;
  final int messageId;
  final int fileIndex;
  final int messageType;
  final String name;
  final int sizeBytes;
  final WeComMediaLocation location;

  String? get kind => WeComMediaRepository.kindForMessageType(messageType);
}

class WeComMediaFileRecord {
  const WeComMediaFileRecord({
    required this.origin,
    required this.messageId,
    required this.fileIndex,
    required this.messageType,
    required this.serverId,
    required this.name,
    required this.sizeBytes,
    required this.receiveTime,
    required this.md5Hex,
  });

  final int origin;
  final int messageId;
  final int fileIndex;
  final int messageType;
  final String serverId;
  final String name;
  final int sizeBytes;
  final int receiveTime;
  final String md5Hex;

  factory WeComMediaFileRecord.fromRow(Map<String, Object?> row) {
    return WeComMediaFileRecord(
      origin: row['origin']! as int,
      messageId: row['message_id']! as int,
      fileIndex: row['file_index']! as int,
      messageType: row['message_type']! as int,
      serverId: row['server_id']?.toString() ?? '',
      name: row['name']?.toString() ?? '',
      sizeBytes: row['size'] as int? ?? 0,
      receiveTime: row['receive_time'] as int? ?? 0,
      md5Hex: row['md5']?.toString() ?? '',
    );
  }
}

class WeComMediaRepository {
  const WeComMediaRepository({
    required Database fileDatabase,
    required Database cacheMappingDatabase,
    required Directory mediaRoot,
  })  : _fileDatabase = fileDatabase,
        _cacheMappingDatabase = cacheMappingDatabase,
        _mediaRoot = mediaRoot;

  final Database _fileDatabase;
  final Database _cacheMappingDatabase;
  final Directory _mediaRoot;

  static const _cacheOffset = Duration(hours: 8);

  static String? kindForMessageType(int messageType) => switch (messageType) {
        0 => 'file',
        1 => 'image',
        2 => 'voice',
        3 => 'video',
        _ => null,
      };

  static String? _cacheKindForMessageType(int messageType) =>
      switch (messageType) {
        0 => 'File',
        1 => 'Image',
        2 => 'Voice',
        3 => 'Video',
        _ => null,
      };

  Future<List<WeComMediaAttachment>> listMessageAttachments(
    WeComMessageRecord message,
  ) async {
    final records = await listReferencedFiles(messageId: message.messageId);
    final attachments = <WeComMediaAttachment>[];
    for (final record in records) {
      attachments.add(await locateFile(record, message: message));
    }
    return List.unmodifiable(attachments);
  }

  Future<List<WeComMediaFileRecord>> listReferencedFiles(
      {int? messageId}) async {
    final rows = await _fileDatabase.query(
      'file_table4',
      columns: [
        'origin',
        'message_id',
        'file_index',
        'message_type',
        'server_id',
        'name',
        'size',
        'receive_time',
        'md5',
      ],
      where: messageId == null ? 'origin = 0' : 'origin = 0 AND message_id = ?',
      whereArgs: messageId == null ? null : [messageId],
      orderBy: 'message_id ASC, file_index ASC',
    );
    return List.unmodifiable(rows.map(WeComMediaFileRecord.fromRow));
  }

  Future<WeComMediaAttachment> locateFile(
    WeComMediaFileRecord record, {
    WeComMessageRecord? message,
  }) async {
    return WeComMediaAttachment(
      origin: record.origin,
      messageId: record.messageId,
      fileIndex: record.fileIndex,
      messageType: record.messageType,
      name: record.name,
      sizeBytes: record.sizeBytes,
      location: await _locate(record, message),
    );
  }

  Future<WeComMediaLocation> _locate(
    WeComMediaFileRecord fileRecord,
    WeComMessageRecord? message,
  ) async {
    final name = fileRecord.name;
    final messageType = fileRecord.messageType;
    final kind = _cacheKindForMessageType(messageType);
    if (name.isNotEmpty) {
      if (kind == null) {
        return const WeComMediaLocation(
          status: WeComMediaLocationStatus.kindUnknown,
          method: WeComMediaLocateMethod.canonicalPath,
        );
      }
      final receiveTime = fileRecord.receiveTime;
      if (receiveTime <= 0) {
        return const WeComMediaLocation(
          status: WeComMediaLocationStatus.missing,
          method: WeComMediaLocateMethod.canonicalPath,
        );
      }
      final relative = '$kind/${_monthFolder(receiveTime)}/$name';
      return _verify(
        relative,
        fileRecord,
        WeComMediaLocateMethod.canonicalPath,
      );
    }

    if (message != null && message.contentType != 7) {
      return const WeComMediaLocation(
        status: WeComMediaLocationStatus.missing,
        method: WeComMediaLocateMethod.canonicalPath,
      );
    }

    final urls = _type7Urls(fileRecord, message);
    if (urls.isEmpty) {
      return const WeComMediaLocation(
        status: WeComMediaLocationStatus.noUniqueMapping,
        method: WeComMediaLocateMethod.cacheMappingType2,
      );
    }
    final originalUrls = urls.where(_isOriginalUrl).toList(growable: false);
    final lookupUrls = originalUrls.isEmpty ? urls : originalUrls;
    final placeholders = List.filled(lookupUrls.length, '?').join(',');
    final mappings = await _cacheMappingDatabase.rawQuery(
      '''
SELECT type, key, file_name
FROM mapping
WHERE type = 2 AND key IN ($placeholders)
''',
      lookupUrls,
    );
    final uniqueMappings = <String, Map<String, Object?>>{};
    for (final mapping in mappings) {
      final key =
          '${mapping['type']}\u0000${mapping['key']}\u0000${mapping['file_name']}';
      uniqueMappings[key] = mapping;
    }
    if (uniqueMappings.length != 1) {
      return const WeComMediaLocation(
        status: WeComMediaLocationStatus.noUniqueMapping,
        method: WeComMediaLocateMethod.cacheMappingType2,
      );
    }
    final relative = relocateMappingPath(
      uniqueMappings.values.single['file_name'] as String?,
      2,
    );
    if (relative == null) {
      return const WeComMediaLocation(
        status: WeComMediaLocationStatus.urlNotOffline,
        method: WeComMediaLocateMethod.cacheMappingType2,
      );
    }
    return _verify(
      relative,
      fileRecord,
      WeComMediaLocateMethod.cacheMappingType2,
    );
  }

  Future<WeComMediaLocation> _verify(
    String relative,
    WeComMediaFileRecord fileRecord,
    WeComMediaLocateMethod method,
  ) async {
    final candidate = _safeCandidate(relative);
    if (candidate == null || !await candidate.exists()) {
      return WeComMediaLocation(
        status: WeComMediaLocationStatus.missing,
        method: method,
        relativePath: candidate == null ? null : relative,
      );
    }
    final rootPath = await _mediaRoot.resolveSymbolicLinks();
    final filePath = await candidate.resolveSymbolicLinks();
    if (!p.equals(rootPath, filePath) && !p.isWithin(rootPath, filePath)) {
      return WeComMediaLocation(
        status: WeComMediaLocationStatus.missing,
        method: method,
      );
    }
    final expectedSize = fileRecord.sizeBytes;
    if (expectedSize > 0 && await candidate.length() != expectedSize) {
      return WeComMediaLocation(
        status: WeComMediaLocationStatus.sizeMismatch,
        method: method,
        relativePath: relative,
      );
    }
    final expectedMd5 = fileRecord.md5Hex.trim().toLowerCase();
    if (expectedMd5.isNotEmpty) {
      final actualMd5 = await md5.bind(candidate.openRead()).first;
      if (actualMd5.toString() != expectedMd5) {
        return WeComMediaLocation(
          status: WeComMediaLocationStatus.hashMismatch,
          method: method,
          relativePath: relative,
        );
      }
    }
    return WeComMediaLocation(
      status: WeComMediaLocationStatus.ok,
      method: method,
      relativePath: relative,
      file: candidate,
    );
  }

  File? _safeCandidate(String relative) {
    final normalized = relative.replaceAll('\\', '/');
    final segments = normalized.split('/');
    if (normalized.isEmpty ||
        p.posix.isAbsolute(normalized) ||
        p.windows.isAbsolute(relative) ||
        normalized.contains('://') ||
        segments.contains('..')) {
      return null;
    }
    final root = p.normalize(p.absolute(_mediaRoot.path));
    final candidate = p.normalize(p.joinAll([root, ...segments]));
    if (p.equals(root, candidate) || !p.isWithin(root, candidate)) {
      return null;
    }
    return File(candidate);
  }

  List<String> _type7Urls(
    WeComMediaFileRecord fileRecord,
    WeComMessageRecord? message,
  ) {
    final urls = <String>{};
    final serverId = fileRecord.serverId;
    if (_isHttpUrl(serverId)) {
      urls.add(serverId);
    }
    final content = message?.content;
    if (content != null) {
      try {
        final urlBytes = firstWeComProtoBytes(
          readWeComProtoFields(content),
          3,
        );
        if (urlBytes != null) {
          final url = utf8.decode(urlBytes);
          if (_isHttpUrl(url)) {
            urls.add(url);
          }
        }
      } on FormatException {
        // A malformed side-channel URL cannot establish a unique mapping.
      }
    }
    return urls.toList(growable: false);
  }

  static bool _isHttpUrl(String value) {
    final lower = value.toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://');
  }

  static bool _isOriginalUrl(String value) {
    final path = Uri.tryParse(value)?.path;
    return path != null && path.endsWith('/0');
  }

  static String _monthFolder(int receiveTime) {
    final local = DateTime.fromMillisecondsSinceEpoch(
      receiveTime * 1000,
      isUtc: true,
    ).add(_cacheOffset);
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}';
  }

  static String? relocateMappingPath(String? fileName, int mappingType) {
    if (fileName == null || fileName.isEmpty || _isHttpUrl(fileName)) {
      return null;
    }
    final normalized = fileName.replaceAll('/', '\\');
    final markerIndex = normalized.toLowerCase().indexOf('\\cache\\');
    if (markerIndex >= 0) {
      final relative = normalized
          .substring(markerIndex + '\\cache\\'.length)
          .replaceAll('\\', '/');
      return relative.isEmpty || relative.split('/').contains('..')
          ? null
          : relative;
    }
    final kind = switch (mappingType) {
      2 => 'Image',
      3 => 'Voice',
      4 => 'Video',
      _ => null,
    };
    final relative = normalized.replaceAll('\\', '/');
    if (kind == null ||
        relative.isEmpty ||
        p.posix.isAbsolute(relative) ||
        p.windows.isAbsolute(fileName) ||
        relative.split('/').contains('..')) {
      return null;
    }
    return '$kind/$relative';
  }
}
