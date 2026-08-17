import 'dart:io';
import 'dart:typed_data';

import 'package:application/src/offline_demo/data/wecom_message_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'wecom_message_test_fixture.dart';

void main() {
  late Directory temporaryDirectory;
  late Database messageDatabase;
  late Database lookupDatabase;
  late WeComMessageRepository repository;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'tui_wecom_messages_',
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
          sendTime: 10,
          content: _bytes('0A09080012050A03E5868D'),
        ),
        TestWeComMessage(
          messageId: 2,
          serverId: 102,
          sequence: 20,
          senderId: 1,
          conversationId: 'S:1_2',
          sendTime: 20,
          flag: 131074,
          content: _bytes('0A0C080012080A06E5A5BDE79A84'),
        ),
      ],
    );
    messageDatabase = await databaseFactoryFfi.openDatabase(
      p.join(temporaryDirectory.path, 'message.db'),
      options: OpenDatabaseOptions(singleInstance: false, readOnly: true),
    );
    lookupDatabase = await databaseFactoryFfi.openDatabase(
      p.join(temporaryDirectory.path, 'message_lookup.db'),
      options: OpenDatabaseOptions(singleInstance: false),
    );
    repository = WeComMessageRepository(
      messageDatabase: messageDatabase,
      lookupDatabase: lookupDatabase,
    );
  });

  tearDown(() async {
    await lookupDatabase.close();
    await messageDatabase.close();
    await temporaryDirectory.delete(recursive: true);
  });

  test('reads indexed messages in ascending sequence order', () async {
    final messages = await repository.listConversationMessages(7);

    expect(messages.map((message) => message.messageId), [1, 2]);
    expect(messages.map((message) => message.sequence), [10, 20]);
    expect(
      decodeWeComTextMessage(messages.first.content!),
      '再',
    );
    expect(
      decodeWeComTextMessage(messages.last.content!),
      '好的',
    );
  });

  test('ignores lookup rows whose message row no longer exists', () async {
    await lookupDatabase.insert('message_lookup_table', {
      'message_id': 999,
      'server_id': 999,
      'con_numeric_id': 7,
      'send_time': 30,
      'sequence': 30,
    });

    final messages = await repository.listConversationMessages(7);

    expect(messages.map((message) => message.messageId), [1, 2]);
  });

  test('decodes all confirmed text and emoji items only', () {
    final content = Uint8List.fromList([
      0x0a,
      0x09,
      0x08,
      0x00,
      0x12,
      0x05,
      0x0a,
      0x03,
      0xe5,
      0x86,
      0x8d,
      0x0a,
      0x0e,
      0x08,
      0x03,
      0x12,
      0x0a,
      0x0a,
      0x08,
      0x5b,
      0xe5,
      0xbe,
      0xae,
      0xe7,
      0xac,
      0x91,
      0x5d,
      0x0a,
      0x05,
      0x08,
      0x05,
      0x12,
      0x01,
      0x78,
    ]);

    expect(decodeWeComTextMessage(content), '再[微笑]');
  });
}

Uint8List _bytes(String hex) {
  return Uint8List.fromList([
    for (var index = 0; index < hex.length; index += 2)
      int.parse(hex.substring(index, index + 2), radix: 16),
  ]);
}
