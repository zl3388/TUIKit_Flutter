import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:application/src/offline_demo/data/wecom_media_repository.dart';
import 'package:application/src/offline_demo/domain/wecom_message_models.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory temporaryDirectory;
  late Directory mediaRoot;
  late Database fileDatabase;
  late Database cacheMappingDatabase;
  late WeComMediaRepository repository;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'tui_wecom_media_',
    );
    mediaRoot = Directory(p.join(temporaryDirectory.path, 'Cache'));
    await mediaRoot.create();
    fileDatabase = await databaseFactoryFfi.openDatabase(
      p.join(temporaryDirectory.path, 'file.db'),
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await fileDatabase.execute('''
CREATE TABLE file_table4 (
  origin INTEGER NOT NULL DEFAULT 0,
  message_id INTEGER NOT NULL DEFAULT 0,
  file_index INTEGER NOT NULL DEFAULT 0,
  message_type INTEGER NOT NULL DEFAULT 0,
  server_id TEXT NOT NULL DEFAULT '',
  name TEXT NOT NULL DEFAULT '',
  size INTEGER NOT NULL DEFAULT 0,
  receive_time INTEGER NOT NULL DEFAULT 0,
  md5 TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (origin, message_id, file_index)
)
''');
    cacheMappingDatabase = await databaseFactoryFfi.openDatabase(
      p.join(temporaryDirectory.path, 'cache_mapping.db'),
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await cacheMappingDatabase.execute('''
CREATE TABLE mapping (
  type INTEGER NOT NULL,
  key TEXT NOT NULL,
  file_name TEXT,
  PRIMARY KEY (type, key)
)
''');
    repository = WeComMediaRepository(
      fileDatabase: fileDatabase,
      cacheMappingDatabase: cacheMappingDatabase,
      mediaRoot: mediaRoot,
    );
  });

  tearDown(() async {
    await cacheMappingDatabase.close();
    await fileDatabase.close();
    await temporaryDirectory.delete(recursive: true);
  });

  test('locates canonical paths in file_index order using UTC+8 month',
      () async {
    final first = await _writeMedia(
      mediaRoot,
      'Image/2025-06/first.png',
      const [1, 2, 3],
    );
    final second = await _writeMedia(
      mediaRoot,
      'Image/2025-06/second.png',
      const [4, 5],
    );
    await _insertFileRow(
      fileDatabase,
      messageId: 101,
      fileIndex: 1,
      messageType: 1,
      name: 'second.png',
      size: await second.length(),
      receiveTime: 1748707200,
      md5Hex: await _md5(second),
    );
    await _insertFileRow(
      fileDatabase,
      messageId: 101,
      fileIndex: 0,
      messageType: 1,
      name: 'first.png',
      size: await first.length(),
      receiveTime: 1748707200,
      md5Hex: await _md5(first),
    );

    final attachments = await repository.listMessageAttachments(
      _message(messageId: 101, contentType: 4),
    );

    expect(attachments.map((item) => item.fileIndex), [0, 1]);
    expect(attachments.map((item) => item.kind), ['image', 'image']);
    expect(
      attachments.map((item) => item.location.relativePath),
      ['Image/2025-06/first.png', 'Image/2025-06/second.png'],
    );
    expect(
      attachments.map((item) => item.location.status),
      everyElement(WeComMediaLocationStatus.ok),
    );
    expect(
      attachments.map((item) => item.location.method),
      everyElement(WeComMediaLocateMethod.canonicalPath),
    );
    expect(attachments.every((item) => item.location.file != null), isTrue);
  });

  test('uses only a unique type 7 CacheMapping original URL', () async {
    final original = await _writeMedia(
      mediaRoot,
      'Image/2020-11/original.png',
      const [9, 8, 7],
    );
    await _insertFileRow(
      fileDatabase,
      messageId: 201,
      fileIndex: 0,
      messageType: 1,
      serverId: 'https://example.com/image/0',
      size: await original.length(),
    );
    await cacheMappingDatabase.insert('mapping', {
      'type': 2,
      'key': 'https://example.com/image/0',
      'file_name': r'2020-11\original.png',
    });
    await cacheMappingDatabase.insert('mapping', {
      'type': 2,
      'key': 'https://example.com/image/640',
      'file_name': r'2020-11\preview.png',
    });

    final attachments = await repository.listMessageAttachments(
      _message(
        messageId: 201,
        contentType: 7,
        content: _stringField(3, 'https://example.com/image/640'),
      ),
    );

    expect(attachments, hasLength(1));
    expect(attachments.single.location.status, WeComMediaLocationStatus.ok);
    expect(
      attachments.single.location.method,
      WeComMediaLocateMethod.cacheMappingType2,
    );
    expect(
      attachments.single.location.relativePath,
      'Image/2020-11/original.png',
    );
  });

  test('reports canonical missing, size, hash, kind, and traversal failures',
      () async {
    final wrongSize = await _writeMedia(
      mediaRoot,
      'File/2025-06/wrong-size.txt',
      const [1, 2],
    );
    final wrongHash = await _writeMedia(
      mediaRoot,
      'File/2025-06/wrong-hash.txt',
      const [3, 4],
    );
    await _insertFileRow(
      fileDatabase,
      messageId: 301,
      fileIndex: 0,
      messageType: 0,
      name: 'missing.txt',
      size: 2,
      receiveTime: 1748707200,
    );
    await _insertFileRow(
      fileDatabase,
      messageId: 301,
      fileIndex: 1,
      messageType: 0,
      name: p.basename(wrongSize.path),
      size: 3,
      receiveTime: 1748707200,
    );
    await _insertFileRow(
      fileDatabase,
      messageId: 301,
      fileIndex: 2,
      messageType: 0,
      name: p.basename(wrongHash.path),
      size: await wrongHash.length(),
      receiveTime: 1748707200,
      md5Hex: md5.convert(const [0]).toString(),
    );
    await _insertFileRow(
      fileDatabase,
      messageId: 301,
      fileIndex: 3,
      messageType: 9,
      name: 'unknown.bin',
      size: 1,
      receiveTime: 1748707200,
    );
    await _insertFileRow(
      fileDatabase,
      messageId: 301,
      fileIndex: 4,
      messageType: 0,
      name: '../escape.txt',
      size: 1,
      receiveTime: 1748707200,
    );

    final attachments = await repository.listMessageAttachments(
      _message(messageId: 301, contentType: 15),
    );

    expect(
      attachments.map((item) => item.location.status),
      [
        WeComMediaLocationStatus.missing,
        WeComMediaLocationStatus.sizeMismatch,
        WeComMediaLocationStatus.hashMismatch,
        WeComMediaLocationStatus.kindUnknown,
        WeComMediaLocationStatus.missing,
      ],
    );
    expect(attachments[4].location.relativePath, isNull);
    expect(attachments.every((item) => item.location.file == null), isTrue);
  });

  test('rejects ambiguous and URL-valued CacheMapping rows', () async {
    await _insertFileRow(
      fileDatabase,
      messageId: 401,
      fileIndex: 0,
      messageType: 1,
      serverId: 'https://example.com/a',
    );
    await cacheMappingDatabase.insert('mapping', {
      'type': 2,
      'key': 'https://example.com/a',
      'file_name': r'2025-01\a.png',
    });
    await cacheMappingDatabase.insert('mapping', {
      'type': 2,
      'key': 'https://example.com/b',
      'file_name': r'2025-01\b.png',
    });
    final ambiguous = await repository.listMessageAttachments(
      _message(
        messageId: 401,
        contentType: 7,
        content: _stringField(3, 'https://example.com/b'),
      ),
    );

    await _insertFileRow(
      fileDatabase,
      messageId: 402,
      fileIndex: 0,
      messageType: 1,
      serverId: 'https://example.com/not-offline',
    );
    await cacheMappingDatabase.insert('mapping', {
      'type': 2,
      'key': 'https://example.com/not-offline',
      'file_name': 'https://example.com/remote.png',
    });
    final remote = await repository.listMessageAttachments(
      _message(messageId: 402, contentType: 7),
    );

    expect(
      ambiguous.single.location.status,
      WeComMediaLocationStatus.noUniqueMapping,
    );
    expect(
      remote.single.location.status,
      WeComMediaLocationStatus.urlNotOffline,
    );
  });

  test('ignores unsupported nonzero origin rows', () async {
    await _insertFileRow(
      fileDatabase,
      origin: 1,
      messageId: 501,
      fileIndex: 0,
      messageType: 0,
      name: 'not-authorized.txt',
      receiveTime: 1748707200,
    );

    final attachments = await repository.listMessageAttachments(
      _message(messageId: 501, contentType: 15),
    );

    expect(attachments, isEmpty);
  });

  final specRoot = Directory(
    p.join(
      Directory.current.parent.path,
      '.local',
      'offline-demo',
      'db_spec',
    ),
  );
  test(
    'matches every positive attachment in the packaged media contract',
    () async {
      final sampleRoot = Directory(p.join(specRoot.path, 'media_samples'));
      final fileDb = await databaseFactoryFfi.openDatabase(
        p.join(sampleRoot.path, 'databases', 'file.db'),
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      final mappingDb = await databaseFactoryFfi.openDatabase(
        p.join(sampleRoot.path, 'databases', 'cache_mapping.db'),
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      final messageDb = await databaseFactoryFfi.openDatabase(
        p.join(sampleRoot.path, 'databases', 'message.db'),
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      addTearDown(() async {
        await messageDb.close();
        await mappingDb.close();
        await fileDb.close();
      });
      final locator = WeComMediaRepository(
        fileDatabase: fileDb,
        cacheMappingDatabase: mappingDb,
        mediaRoot: Directory(p.join(sampleRoot.path, 'files', 'cache')),
      );
      final document = Map<String, Object?>.from(
        jsonDecode(
          await File(p.join(sampleRoot.path, 'mapping.json')).readAsString(),
        ) as Map,
      );
      final samples = (document['samples']! as List)
          .map((item) => Map<String, Object?>.from(item as Map))
          .where((item) => item['role'] == 'positive')
          .toList(growable: false);
      final byMessage = <int, List<Map<String, Object?>>>{};
      for (final sample in samples) {
        byMessage
            .putIfAbsent(sample['message_id']! as int, () => [])
            .add(sample);
      }

      for (final entry in byMessage.entries) {
        final rows = await messageDb.query(
          'message_table',
          columns: [
            'message_id',
            'sequence',
            'sender_id',
            'conversation_id',
            'content_type',
            'send_time',
            'content',
          ],
          where: 'message_id = ?',
          whereArgs: [entry.key],
        );
        final attachments = await locator.listMessageAttachments(
          WeComMessageRecord.fromRow(rows.single),
        );
        entry.value.sort(
          (left, right) => (left['file_index']! as int)
              .compareTo(right['file_index']! as int),
        );
        expect(attachments, hasLength(entry.value.length));
        for (var index = 0; index < attachments.length; index++) {
          final expected = entry.value[index];
          final actual = attachments[index];
          expect(actual.fileIndex, expected['file_index']);
          expect(actual.location.status, WeComMediaLocationStatus.ok);
          expect(
              actual.location.relativePath, expected['source_relative_path']);
          expect(actual.location.file, isNotNull);
        }
      }
    },
    skip: File(p.join(specRoot.path, 'media_samples', 'mapping.json'))
            .existsSync()
        ? false
        : 'Requires .local/offline-demo/db_spec/media_samples',
  );
}

WeComMessageRecord _message({
  required int messageId,
  required int contentType,
  Uint8List? content,
}) {
  return WeComMessageRecord(
    messageId: messageId,
    sequence: messageId,
    senderId: 1,
    conversationId: 'R:test',
    contentType: contentType,
    sendTime: 0,
    content: content,
  );
}

Future<void> _insertFileRow(
  Database database, {
  int origin = 0,
  required int messageId,
  required int fileIndex,
  required int messageType,
  String serverId = '',
  String name = '',
  int size = 0,
  int receiveTime = 0,
  String md5Hex = '',
}) {
  return database.insert('file_table4', {
    'origin': origin,
    'message_id': messageId,
    'file_index': fileIndex,
    'message_type': messageType,
    'server_id': serverId,
    'name': name,
    'size': size,
    'receive_time': receiveTime,
    'md5': md5Hex,
  });
}

Future<File> _writeMedia(
  Directory root,
  String relative,
  List<int> bytes,
) async {
  final file = File(
    p.joinAll([root.path, ...relative.split('/')]),
  );
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes);
  return file;
}

Future<String> _md5(File file) async =>
    (await md5.bind(file.openRead()).first).toString();

Uint8List _stringField(int number, String value) {
  final bytes = utf8.encode(value);
  return Uint8List.fromList([
    ..._varint((number << 3) | 2),
    ..._varint(bytes.length),
    ...bytes,
  ]);
}

List<int> _varint(int value) {
  final bytes = <int>[];
  do {
    var byte = value & 0x7f;
    value >>= 7;
    if (value != 0) {
      byte |= 0x80;
    }
    bytes.add(byte);
  } while (value != 0);
  return bytes;
}
