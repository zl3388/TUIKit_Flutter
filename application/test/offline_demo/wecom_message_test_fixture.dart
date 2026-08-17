import 'dart:io';
import 'dart:typed_data';

import 'package:application/src/offline_demo/data/wecom_database_package.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'wecom_identity_test_fixture.dart';

class TestWeComMessage {
  const TestWeComMessage({
    required this.messageId,
    required this.serverId,
    required this.sequence,
    required this.senderId,
    required this.conversationId,
    required this.sendTime,
    required this.content,
    this.flag = 0,
  });

  final int messageId;
  final int serverId;
  final int sequence;
  final int senderId;
  final String conversationId;
  final int sendTime;
  final int flag;
  final List<int> content;
}

Future<void> createMessageDatabases(
  Directory source, {
  required int conversationNumericId,
  required List<TestWeComMessage> messages,
}) async {
  final messageDatabase = await databaseFactoryFfi.openDatabase(
    p.join(source.path, 'message.db'),
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await messageDatabase.execute('''
CREATE TABLE message_table (
  message_id INTEGER PRIMARY KEY,
  server_id INTEGER NOT NULL,
  sequence INTEGER NOT NULL,
  sender_id INTEGER NOT NULL,
  conversation_id TEXT NOT NULL,
  content_type INTEGER NOT NULL,
  send_time INTEGER NOT NULL,
  flag INTEGER NOT NULL,
  content
)
''');
  for (final message in messages) {
    await messageDatabase.insert('message_table', {
      'message_id': message.messageId,
      'server_id': message.serverId,
      'sequence': message.sequence,
      'sender_id': message.senderId,
      'conversation_id': message.conversationId,
      'content_type': 2,
      'send_time': message.sendTime,
      'flag': message.flag,
      'content': Uint8List.fromList(message.content),
    });
  }
  await messageDatabase.close();

  final lookupDatabase = await databaseFactoryFfi.openDatabase(
    p.join(source.path, 'message_lookup.db'),
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await lookupDatabase.execute('''
CREATE TABLE message_lookup_table (
  message_id INTEGER PRIMARY KEY,
  server_id INTEGER NOT NULL,
  con_numeric_id INTEGER NOT NULL,
  send_time INTEGER NOT NULL,
  sequence INTEGER NOT NULL,
  parent_message_id INTEGER DEFAULT 0
)
''');
  for (final message in messages) {
    await lookupDatabase.insert('message_lookup_table', {
      'message_id': message.messageId,
      'server_id': message.serverId,
      'con_numeric_id': conversationNumericId,
      'send_time': message.sendTime,
      'sequence': message.sequence,
    });
  }
  await lookupDatabase.close();
}

List<WeComDatabaseContract> messageDatabaseContracts() => [
      WeComDatabaseContract(
        fileName: 'message.db',
        allowEmpty: false,
        tables: {
          'message_table': [
            testColumn('message_id', 'INTEGER', primaryKeyPosition: 1),
            testColumn('server_id', 'INTEGER', notNull: true),
            testColumn('sequence', 'INTEGER', notNull: true),
            testColumn('sender_id', 'INTEGER', notNull: true),
            testColumn('conversation_id', 'TEXT', notNull: true),
            testColumn('content_type', 'INTEGER', notNull: true),
            testColumn('send_time', 'INTEGER', notNull: true),
            testColumn('flag', 'INTEGER', notNull: true),
            testColumn('content', ''),
          ],
        },
        indexes: const {},
      ),
      WeComDatabaseContract(
        fileName: 'message_lookup.db',
        allowEmpty: false,
        tables: {
          'message_lookup_table': [
            testColumn('message_id', 'INTEGER', primaryKeyPosition: 1),
            testColumn('server_id', 'INTEGER', notNull: true),
            testColumn('con_numeric_id', 'INTEGER', notNull: true),
            testColumn('send_time', 'INTEGER', notNull: true),
            testColumn('sequence', 'INTEGER', notNull: true),
            testColumn('parent_message_id', 'INTEGER'),
          ],
        },
        indexes: const {},
      ),
    ];
