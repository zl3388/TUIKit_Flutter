import 'dart:io';

import 'package:application/src/offline_demo/data/wecom_announcement_editor.dart';
import 'package:application/src/offline_demo/data/wecom_announcement_repository.dart';
import 'package:application/src/offline_demo/data/wecom_database_package.dart';
import 'package:application/src/offline_demo/data/wecom_identity_repository.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_command_service.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'wecom_identity_test_fixture.dart';

void main() {
  const datasetId =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const identity = WeComIdentityScope(corporationId: 100, userId: 1);
  late Directory temporaryDirectory;
  late Database baseDatabase;
  late WeComOverlayDatabase overlayDatabase;
  late WeComPackageContract contract;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory =
        await Directory.systemTemp.createTemp('tui_wecom_announce_');
    baseDatabase = await databaseFactoryFfi.openDatabase(
      p.join(temporaryDirectory.path, 'forever_store.db'),
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (database, version) async {
          await database.execute('''
CREATE TABLE announce_table(
  id INTEGER PRIMARY KEY NOT NULL,
  time INTEGER NOT NULL,
  subject TEXT NOT NULL,
  summary TEXT NOT NULL,
  is_secret INTEGER NOT NULL,
  attachment_count INTEGER NOT NULL,
  sender_name TEXT NOT NULL,
  sender_id INTEGER NOT NULL,
  is_read INTEGER NOT NULL,
  store_data_id INTEGER NOT NULL,
  image_url TEXT NOT NULL,
  url TEXT NOT NULL,
  store_id INTEGER NOT NULL,
  status INTEGER NOT NULL,
  flags INTEGER NOT NULL
)
''');
          await database.insert('announce_table', {
            'id': 10,
            'time': 200,
            'subject': '较新公告',
            'summary': '较新摘要',
            'is_secret': 2,
            'attachment_count': 2,
            'sender_name': '研发部',
            'sender_id': 2,
            'is_read': 1,
            'store_data_id': 1,
            'image_url': '',
            'url': 'https://example.com/new',
            'store_id': 1,
            'status': 3,
            'flags': 1,
          });
          await database.insert('announce_table', {
            'id': 9,
            'time': 100,
            'subject': '较早公告',
            'summary': '较早摘要',
            'is_secret': 2,
            'attachment_count': 0,
            'sender_name': '行政部',
            'sender_id': 3,
            'is_read': 1,
            'store_data_id': 2,
            'image_url': '',
            'url': 'https://example.com/old',
            'store_id': 2,
            'status': 1,
            'flags': 0,
          });
        },
      ),
    );
    overlayDatabase = await WeComOverlayDatabase.open(
      factory: databaseFactoryFfi,
      databasePath: p.join(temporaryDirectory.path, 'overlay.db'),
    );
    contract = WeComPackageContract(
      formatVersion: 1,
      scope: 'announcement test',
      databases: [
        WeComDatabaseContract(
          fileName: 'forever_store.db',
          allowEmpty: false,
          tables: {
            'announce_table': [
              testColumn(
                'id',
                'INTEGER',
                notNull: true,
                primaryKeyPosition: 1,
              ),
              testColumn('subject', 'TEXT', notNull: true),
              testColumn('summary', 'TEXT', notNull: true),
              testColumn('status', 'INTEGER', notNull: true),
            ],
          },
          indexes: const {},
        ),
      ],
    );
  });

  tearDown(() async {
    await overlayDatabase.close();
    await baseDatabase.close();
    await temporaryDirectory.delete(recursive: true);
  });

  WeComAnnouncementRepository repositoryFor(WeComIdentityScope scope) {
    return WeComAnnouncementRepository(
      datasetId: datasetId,
      identityScope: scope,
      baseDatabase: baseDatabase,
      overlayDatabase: overlayDatabase,
    );
  }

  test('projects verified announcement fields without naming unknown enums',
      () async {
    final repository = repositoryFor(identity);

    final announcements = await repository.listAnnouncements();

    expect(announcements.map((item) => item.id), ['10', '9']);
    expect(announcements.first.title, '较新公告');
    expect(announcements.first.summary, '较新摘要');
    expect(announcements.first.authorName, '研发部');
    expect(announcements.first.attachmentCount, 2);
    expect(announcements.first.isRead, isTrue);
    expect(
      announcements.first.publishedAt,
      DateTime.fromMillisecondsSinceEpoch(200000, isUtc: true),
    );
  });

  test('edits subject and summary in an identity-scoped overlay and undoes',
      () async {
    final repository = repositoryFor(identity);
    final commands = WeComOverlayCommandService(
      overlayDatabase: overlayDatabase,
      contract: contract,
      identityScope: identity,
    );
    final editor = WeComAnnouncementEditor(
      datasetId: datasetId,
      announcements: repository,
      commands: commands,
    );

    final edit = await editor.updateContent(
      announcementId: '10',
      title: '本地标题',
      summary: '本地摘要',
    );

    var announcement = (await repository.listAnnouncements()).first;
    expect(announcement.title, '本地标题');
    expect(announcement.summary, '本地摘要');
    final base = await baseDatabase.query(
      'announce_table',
      where: 'id = ?',
      whereArgs: [10],
    );
    expect(base.single['subject'], '较新公告');
    expect(base.single['summary'], '较新摘要');
    final otherIdentity = repositoryFor(
      const WeComIdentityScope(corporationId: 200, userId: 2),
    );
    expect((await otherIdentity.listAnnouncements()).first.title, '较新公告');

    await editor.undo(edit);

    announcement = (await repository.listAnnouncements()).first;
    expect(announcement.title, '较新公告');
    expect(announcement.summary, '较新摘要');
    await expectLater(editor.undo(edit), throwsStateError);
  });

  test('rejects no-op, missing rows, and unsupported overlay fields', () async {
    final repository = repositoryFor(identity);
    final commands = WeComOverlayCommandService(
      overlayDatabase: overlayDatabase,
      contract: contract,
      identityScope: identity,
    );
    final editor = WeComAnnouncementEditor(
      datasetId: datasetId,
      announcements: repository,
      commands: commands,
    );

    await expectLater(
      editor.updateContent(
        announcementId: '10',
        title: '较新公告',
        summary: '较新摘要',
      ),
      throwsA(isA<WeComAnnouncementNoChangesException>()),
    );
    await expectLater(
      editor.updateContent(
        announcementId: '404',
        title: '标题',
        summary: '摘要',
      ),
      throwsStateError,
    );
    await commands.upsert(
      datasetId: datasetId,
      databaseName: WeComAnnouncementRepository.databaseName,
      tableName: WeComAnnouncementRepository.tableName,
      rowKey: const {'id': 10},
      values: const {'status': 1},
    );
    await expectLater(
      repository.listAnnouncements(),
      throwsUnsupportedError,
    );
  });
}
