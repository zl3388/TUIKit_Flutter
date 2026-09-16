import 'dart:io';

import 'package:application/src/offline_demo/data/wecom_activity_repository.dart';
import 'package:application/src/offline_demo/data/wecom_message_repository.dart';
import 'package:application/src/offline_demo/domain/models.dart';
import 'package:application/src/offline_demo/domain/repositories.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'wecom_message_test_fixture.dart';

void main() {
  late Directory temporaryDirectory;
  late Database messageDatabase;
  late Database lookupDatabase;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'tui_wecom_calls_',
    );
    await createMessageDatabases(
      temporaryDirectory,
      conversationNumericId: 7,
      messages: [
        TestWeComMessage(
          messageId: 1,
          serverId: 101,
          sequence: 10,
          senderId: 2,
          conversationId: 'S:1_2',
          contentType: 40,
          sendTime: 100,
          content: testProtoMessage([
            testVarintField(1, 2),
            testVarintField(2, 3),
            testStringField(3, '对方已取消'),
            testVarintField(21, 1),
            testVarintField(21, 2),
          ]),
        ),
        TestWeComMessage(
          messageId: 2,
          serverId: 102,
          sequence: 20,
          senderId: 10024,
          conversationId: 'Y:10024',
          contentType: 503,
          sendTime: 100,
          content: testProtoMessage([
            testBytesField(
              2,
              testProtoMessage([
                testStringField(1, '来自对方的未接语音通话'),
                testVarintField(4, 2),
              ]),
            ),
            testVarintField(3, 100),
          ]),
        ),
        TestWeComMessage(
          messageId: 3,
          serverId: 103,
          sequence: 30,
          senderId: 1,
          conversationId: 'S:1_2',
          contentType: 40,
          sendTime: 200,
          content: testProtoMessage([
            testVarintField(1, 2),
            testVarintField(2, 5),
            testStringField(3, '通话时长01:05'),
            testVarintField(20, 65),
          ]),
        ),
        TestWeComMessage(
          messageId: 4,
          serverId: 104,
          sequence: 40,
          senderId: 2,
          conversationId: 'S:1_2',
          contentType: 40,
          sendTime: 300,
          content: testProtoMessage([
            testVarintField(1, 2),
            testVarintField(2, 2),
            testStringField(3, '已拒绝'),
          ]),
        ),
        TestWeComMessage(
          messageId: 5,
          serverId: 105,
          sequence: 50,
          senderId: 3,
          conversationId: 'R:room',
          contentType: 1018,
          sendTime: 400,
          content: testProtoMessage([
            testVarintField(2, 3),
            testStringField(3, '语音通话未接听'),
          ]),
        ),
        TestWeComMessage(
          messageId: 6,
          serverId: 106,
          sequence: 60,
          senderId: 10024,
          conversationId: 'Y:10024',
          contentType: 503,
          sendTime: 500,
          content: testProtoMessage([
            testBytesField(
              2,
              testProtoMessage([testStringField(1, '普通推送')]),
            ),
          ]),
        ),
      ],
    );
    messageDatabase = await databaseFactoryFfi.openDatabase(
      p.join(temporaryDirectory.path, 'message.db'),
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    lookupDatabase = await databaseFactoryFfi.openDatabase(
      p.join(temporaryDirectory.path, 'message_lookup.db'),
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
  });

  tearDown(() async {
    await lookupDatabase.close();
    await messageDatabase.close();
    await temporaryDirectory.delete(recursive: true);
  });

  test('projects confirmed call states and merges missed notices', () async {
    final repository = WeComActivityRepository(
      currentUserId: 1,
      messages: WeComMessageRepository(
        messageDatabase: messageDatabase,
        lookupDatabase: lookupDatabase,
      ),
      contacts: const _Contacts(),
    );

    final calls = await repository.listCallRecords();

    expect(repository.features, {ActivityFeature.calls});
    expect(calls.map((call) => call.id), ['5', '4', '3', '1']);
    expect(calls[0].direction, 'group');
    expect(calls[0].status, 'missed');
    expect(calls[1].status, 'rejected');
    expect(calls[2].direction, 'outgoing');
    expect(calls[2].status, 'connected');
    expect(calls[2].durationSeconds, 65);
    expect(calls[3].peerName, '对方');
    expect(calls[3].direction, 'incoming');
    expect(calls[3].status, 'missed');
  });

  test('does not expose unrelated activity write capabilities', () async {
    final repository = WeComActivityRepository(
      currentUserId: 1,
      messages: WeComMessageRepository(
        messageDatabase: messageDatabase,
        lookupDatabase: lookupDatabase,
      ),
      contacts: const _Contacts(),
    );

    expect(await repository.listNotifications(), isEmpty);
    expect(await repository.listAnnouncements(), isEmpty);
    await expectLater(
      repository.markNotificationRead('1'),
      throwsUnsupportedError,
    );
  });
}

class _Contacts implements ContactRepository {
  const _Contacts();

  @override
  bool get isAvailable => true;

  @override
  Future<List<OrgUnit>> listOrganizationUnits() async => const [];

  @override
  Future<List<DirectoryContact>> listContacts({
    String? organizationUnitId,
  }) async =>
      const [
        DirectoryContact(id: '1', displayName: '本人'),
        DirectoryContact(id: '2', displayName: '对方'),
      ];
}
