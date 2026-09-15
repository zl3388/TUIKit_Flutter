import 'dart:convert';
import 'dart:io';

import 'package:application/src/offline_demo/data/wecom_media_snapshot.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  const datasetId =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  late Directory temporaryDirectory;
  late File fileDatabase;
  late File messageDatabase;
  final liveConnections = <Database>[];

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'tui_wecom_media_snapshot_',
    );
    fileDatabase = File(p.join(temporaryDirectory.path, 'file.db'));
    messageDatabase = File(p.join(temporaryDirectory.path, 'message.db'));
    await _createFileDatabase(fileDatabase);
    await _createMessageDatabase(messageDatabase);
  });

  tearDown(() async {
    for (final connection in liveConnections.reversed) {
      await connection.close();
    }
    liveConnections.clear();
    await temporaryDirectory.delete(recursive: true);
  });

  test('selects a matching live account and copies only referenced media',
      () async {
    final wxWorkRoot = Directory(p.join(temporaryDirectory.path, 'WXWork'));
    final selected = await _createAccount(
      wxWorkRoot,
      'selected_account',
      '11111111111111111111111111111111.db',
      mappingMd5: await _insertReferencedFiles(fileDatabase),
      includeInvalidSecondCandidate: true,
    );
    liveConnections.add(selected.connection);
    final other = await _createAccount(
      wxWorkRoot,
      'other_account',
      '22222222222222222222222222222222.db',
      mappingMd5: '00000000000000000000000000000000',
    );
    liveConnections.add(other.connection);
    await File(p.join(selected.cache.path, 'File', 'unreferenced.bin'))
        .create(recursive: true)
        .then((file) => file.writeAsBytes([99]));

    final manager = WeComMediaSnapshotManager(
      destinationRoot: Directory(p.join(temporaryDirectory.path, 'managed')),
      databaseFactory: databaseFactoryFfi,
    );
    final beforeSourceHashes = await _hashTrio(selected.databaseFile);

    final snapshot = await manager.importReferencedMedia(
      datasetId: datasetId,
      fileDatabase: fileDatabase,
      messageDatabase: messageDatabase,
      wxWorkRoot: wxWorkRoot,
    );

    expect(snapshot.reusedExisting, isFalse);
    expect(snapshot.referencedFileCount, 2);
    expect(snapshot.copiedFileCount, 2);
    expect(p.basename(snapshot.cacheMappingFile.path),
        '11111111111111111111111111111111.db');
    expect(
      File(p.join(snapshot.mediaRoot.path, 'File', '2025-06', 'note.txt'))
          .readAsString(),
      completion('referenced text'),
    );
    expect(
      File(p.join(snapshot.mediaRoot.path, 'Image', '2025-06', 'url.png'))
          .readAsBytes(),
      completion([1, 2, 3, 4]),
    );
    expect(
      File(p.join(snapshot.mediaRoot.path, 'File', 'unreferenced.bin'))
          .exists(),
      completion(isFalse),
    );
    expect(await _hashTrio(selected.databaseFile), beforeSourceHashes);

    final manifestText = await File(
      p.join(
          snapshot.directory.path, WeComMediaSnapshotManager.manifestFileName),
    ).readAsString();
    expect(manifestText, isNot(contains(wxWorkRoot.path)));
    expect(manifestText, isNot(contains('selected_account')));
    final manifest = jsonDecode(manifestText) as Map<String, Object?>;
    expect(manifest['datasetId'], datasetId);
    expect(manifest['files'], hasLength(2));
    expect(manifest['references'], hasLength(2));

    final reopened = await manager.openSnapshot(datasetId);
    expect(reopened, isNotNull);
    expect(reopened!.copiedFileCount, 2);
    final mappingConnection =
        await reopened.openCacheMappingReadOnly(databaseFactoryFfi);
    final mappingCount = await mappingConnection
        .rawQuery('SELECT COUNT(*) AS count FROM mapping');
    expect(mappingCount.single['count'], 2);
    await mappingConnection.close();
    expect(await manager.openSnapshot(datasetId), isNotNull);

    final reused = await manager.importReferencedMedia(
      datasetId: datasetId,
      fileDatabase: fileDatabase,
      messageDatabase: messageDatabase,
      wxWorkRoot: Directory(p.join(temporaryDirectory.path, 'gone')),
    );
    expect(reused.reusedExisting, isTrue);
  });

  test('rejects multiple matching account datasets', () async {
    final wxWorkRoot = Directory(p.join(temporaryDirectory.path, 'WXWork'));
    final mappingMd5 = await _insertReferencedFiles(fileDatabase);
    for (final item in [
      ('first', '11111111111111111111111111111111.db'),
      ('second', '22222222222222222222222222222222.db'),
    ]) {
      final account = await _createAccount(
        wxWorkRoot,
        item.$1,
        item.$2,
        mappingMd5: mappingMd5,
      );
      liveConnections.add(account.connection);
    }
    final manager = WeComMediaSnapshotManager(
      destinationRoot: Directory(p.join(temporaryDirectory.path, 'managed')),
      databaseFactory: databaseFactoryFfi,
    );

    await expectLater(
      manager.importReferencedMedia(
        datasetId: datasetId,
        fileDatabase: fileDatabase,
        messageDatabase: messageDatabase,
        wxWorkRoot: wxWorkRoot,
      ),
      throwsA(
        isA<WeComMediaSnapshotException>().having(
          (error) => error.code,
          'code',
          WeComMediaSnapshotIssueCode.ambiguousAccount,
        ),
      ),
    );
  });

  test('rejects a managed media file changed after import', () async {
    final wxWorkRoot = Directory(p.join(temporaryDirectory.path, 'WXWork'));
    final selected = await _createAccount(
      wxWorkRoot,
      'selected_account',
      '11111111111111111111111111111111.db',
      mappingMd5: await _insertReferencedFiles(fileDatabase),
    );
    liveConnections.add(selected.connection);
    final manager = WeComMediaSnapshotManager(
      destinationRoot: Directory(p.join(temporaryDirectory.path, 'managed')),
      databaseFactory: databaseFactoryFfi,
    );
    final snapshot = await manager.importReferencedMedia(
      datasetId: datasetId,
      fileDatabase: fileDatabase,
      messageDatabase: messageDatabase,
      wxWorkRoot: wxWorkRoot,
    );
    await File(
      p.join(snapshot.mediaRoot.path, 'File', '2025-06', 'note.txt'),
    ).writeAsString('changed');

    await expectLater(
      manager.openSnapshot(datasetId),
      throwsA(
        isA<WeComMediaSnapshotException>().having(
          (error) => error.code,
          'code',
          WeComMediaSnapshotIssueCode.existingSnapshotCorrupt,
        ),
      ),
    );
  });

  test('runtime open defers media hashes but full validation detects changes',
      () async {
    final wxWorkRoot = Directory(p.join(temporaryDirectory.path, 'WXWork'));
    final selected = await _createAccount(
      wxWorkRoot,
      'selected_account',
      '11111111111111111111111111111111.db',
      mappingMd5: await _insertReferencedFiles(fileDatabase),
    );
    liveConnections.add(selected.connection);
    final manager = WeComMediaSnapshotManager(
      destinationRoot: Directory(p.join(temporaryDirectory.path, 'managed')),
      databaseFactory: databaseFactoryFfi,
    );
    final snapshot = await manager.importReferencedMedia(
      datasetId: datasetId,
      fileDatabase: fileDatabase,
      messageDatabase: messageDatabase,
      wxWorkRoot: wxWorkRoot,
    );
    await File(
      p.join(snapshot.mediaRoot.path, 'File', '2025-06', 'note.txt'),
    ).writeAsString('different bytes');

    expect(
      await manager.openSnapshot(datasetId, verifyMediaHashes: false),
      isNotNull,
    );
    await expectLater(
      manager.openSnapshot(datasetId),
      throwsA(isA<WeComMediaSnapshotException>()),
    );
  });

  test('rejects media files not matched by an available reference', () async {
    final wxWorkRoot = Directory(p.join(temporaryDirectory.path, 'WXWork'));
    final selected = await _createAccount(
      wxWorkRoot,
      'selected_account',
      '11111111111111111111111111111111.db',
      mappingMd5: await _insertReferencedFiles(fileDatabase),
    );
    liveConnections.add(selected.connection);
    final manager = WeComMediaSnapshotManager(
      destinationRoot: Directory(p.join(temporaryDirectory.path, 'managed')),
      databaseFactory: databaseFactoryFfi,
    );
    final snapshot = await manager.importReferencedMedia(
      datasetId: datasetId,
      fileDatabase: fileDatabase,
      messageDatabase: messageDatabase,
      wxWorkRoot: wxWorkRoot,
    );
    final manifestFile = File(
      p.join(
        snapshot.directory.path,
        WeComMediaSnapshotManager.manifestFileName,
      ),
    );
    final manifest =
        jsonDecode(await manifestFile.readAsString()) as Map<String, Object?>;
    final references = manifest['references']! as List<Object?>;
    manifest['references'] = references.take(1).toList();
    await manifestFile.writeAsString(jsonEncode(manifest));

    await expectLater(
      manager.openSnapshot(datasetId, verifyMediaHashes: false),
      throwsA(isA<WeComMediaSnapshotException>()),
    );
  });
}

Future<String> _insertReferencedFiles(File databaseFile) async {
  final text = utf8.encode('referenced text');
  final image = [1, 2, 3, 4];
  final textMd5 = md5.convert(text).toString();
  final imageMd5 = md5.convert(image).toString();
  final database = await databaseFactoryFfi.openDatabase(
    databaseFile.path,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  try {
    await database.insert('file_table4', {
      'origin': 0,
      'message_id': 101,
      'file_index': 0,
      'message_type': 0,
      'server_id': '',
      'name': 'note.txt',
      'size': text.length,
      'receive_time': 1748707200,
      'md5': textMd5,
    });
    await database.insert('file_table4', {
      'origin': 0,
      'message_id': 102,
      'file_index': 0,
      'message_type': 1,
      'server_id': 'https://example.com/original',
      'name': '',
      'size': image.length,
      'receive_time': 1748707200,
      'md5': imageMd5,
    });
    await database.insert('file_table4', {
      'origin': 1,
      'message_id': 103,
      'file_index': 0,
      'message_type': 0,
      'server_id': '',
      'name': 'not-authorized.txt',
      'size': 1,
      'receive_time': 1748707200,
      'md5': md5.convert([5]).toString(),
    });
  } finally {
    await database.close();
  }
  return imageMd5;
}

Future<void> _createFileDatabase(File file) async {
  final database = await databaseFactoryFfi.openDatabase(
    file.path,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  try {
    await database.execute('''
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
  } finally {
    await database.close();
  }
}

Future<void> _createMessageDatabase(File file) async {
  final database = await databaseFactoryFfi.openDatabase(
    file.path,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  try {
    await database.execute('''
CREATE TABLE message_table (
  message_id INTEGER PRIMARY KEY,
  sequence INTEGER NOT NULL DEFAULT 0,
  sender_id INTEGER NOT NULL DEFAULT 0,
  conversation_id TEXT NOT NULL DEFAULT '',
  content_type INTEGER NOT NULL DEFAULT 0,
  send_time INTEGER NOT NULL DEFAULT 0,
  content BLOB
)
''');
  } finally {
    await database.close();
  }
}

Future<_AccountFixture> _createAccount(
  Directory wxWorkRoot,
  String accountName,
  String databaseName, {
  required String mappingMd5,
  bool includeInvalidSecondCandidate = false,
}) async {
  final account = Directory(p.join(wxWorkRoot.path, accountName));
  final cache = Directory(p.join(account.path, 'Cache'));
  final cacheMapping = Directory(p.join(account.path, 'CacheMapping'));
  await cache.create(recursive: true);
  await cacheMapping.create();
  await Directory(p.join(account.path, 'Data')).create();

  final textFile = File(p.join(cache.path, 'File', '2025-06', 'note.txt'));
  await textFile.create(recursive: true);
  await textFile.writeAsString('referenced text');
  final imageFile = File(p.join(cache.path, 'Image', '2025-06', 'url.png'));
  await imageFile.create(recursive: true);
  await imageFile.writeAsBytes([1, 2, 3, 4]);

  final databaseFile = File(p.join(cacheMapping.path, databaseName));
  final database = await databaseFactoryFfi.openDatabase(
    databaseFile.path,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await database.rawQuery('PRAGMA journal_mode=WAL');
  await database.rawQuery('PRAGMA wal_autocheckpoint=0');
  await database.execute('''
CREATE TABLE mapping (
  type integer default 0 not null,
  key text default '' not null,
  file_name text default '',
  last_modify_time integer default 0 not null,
  file_md5 integer default 0 not null,
  primary key (type,key)
)
''');
  await database.execute(
    'CREATE INDEX file_md5_index_ on mapping (file_md5)',
  );
  await database.execute(
    'CREATE INDEX file_name_index_ on mapping (file_name)',
  );
  await database.insert('mapping', {
    'type': 2,
    'key': 'https://example.com/original',
    'file_name': r'2025-06\url.png',
    'last_modify_time': 1,
    'file_md5': mappingMd5,
  });
  await database.insert('mapping', {
    'type': 1,
    'key': 'unreferenced',
    'file_name': '${account.path}\\Cache\\File\\2025-06\\note.txt',
    'last_modify_time': 2,
    'file_md5': mappingMd5,
  });

  if (includeInvalidSecondCandidate) {
    await File(
      p.join(cacheMapping.path, '33333333333333333333333333333333.db'),
    ).writeAsString('not sqlite');
  }
  expect(File('${databaseFile.path}-wal').existsSync(), isTrue);
  expect(File('${databaseFile.path}-shm').existsSync(), isTrue);
  return _AccountFixture(
    cache: cache,
    databaseFile: databaseFile,
    connection: database,
  );
}

Future<Map<String, String>> _hashTrio(File database) async {
  final hashes = <String, String>{};
  for (final file in [
    database,
    File('${database.path}-wal'),
    File('${database.path}-shm'),
  ]) {
    hashes[p.basename(file.path)] =
        (await sha256.bind(file.openRead()).first).toString();
  }
  return hashes;
}

class _AccountFixture {
  const _AccountFixture({
    required this.cache,
    required this.databaseFile,
    required this.connection,
  });

  final Directory cache;
  final File databaseFile;
  final Database connection;
}
