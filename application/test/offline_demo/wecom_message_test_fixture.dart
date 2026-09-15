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
    this.contentType = 2,
    this.flag = 0,
    this.clientId,
    this.inRetryQueue = false,
    this.readState,
  });

  final int messageId;
  final int serverId;
  final int sequence;
  final int senderId;
  final String conversationId;
  final int sendTime;
  final int contentType;
  final int flag;
  final List<int> content;
  final String? clientId;
  final bool inRetryQueue;
  final List<int>? readState;
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
  await messageDatabase.execute('''
CREATE TABLE message_client_id (
  message_id INTEGER PRIMARY KEY,
  client_id TEXT NOT NULL,
  send_failed_unnotified INTEGER NOT NULL
)
''');
  await messageDatabase.execute('''
CREATE TABLE retry_send_item_kv_table (
  key INTEGER PRIMARY KEY NOT NULL,
  value INTEGER NOT NULL
)
''');
  await messageDatabase.execute('''
CREATE TABLE message_read_state_table (
  message_id INTEGER PRIMARY KEY,
  read_state_pb NOT NULL
)
''');
  for (final message in messages) {
    await messageDatabase.insert('message_table', {
      'message_id': message.messageId,
      'server_id': message.serverId,
      'sequence': message.sequence,
      'sender_id': message.senderId,
      'conversation_id': message.conversationId,
      'content_type': message.contentType,
      'send_time': message.sendTime,
      'flag': message.flag,
      'content': Uint8List.fromList(message.content),
    });
    if (message.clientId != null) {
      await messageDatabase.insert('message_client_id', {
        'message_id': message.messageId,
        'client_id': message.clientId,
        'send_failed_unnotified': 0,
      });
    }
    if (message.inRetryQueue) {
      await messageDatabase.insert('retry_send_item_kv_table', {
        'key': message.messageId,
        'value': message.sendTime,
      });
    }
    if (message.readState != null) {
      await messageDatabase.insert('message_read_state_table', {
        'message_id': message.messageId,
        'read_state_pb': Uint8List.fromList(message.readState!),
      });
    }
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
          'message_client_id': [
            testColumn('message_id', 'INTEGER', primaryKeyPosition: 1),
            testColumn('client_id', 'TEXT', notNull: true),
            testColumn('send_failed_unnotified', 'INTEGER', notNull: true),
          ],
          'message_read_state_table': [
            testColumn('message_id', 'INTEGER', primaryKeyPosition: 1),
            testColumn('read_state_pb', '', notNull: true),
          ],
          'retry_send_item_kv_table': [
            testColumn(
              'key',
              'INTEGER',
              notNull: true,
              primaryKeyPosition: 1,
            ),
            testColumn('value', 'INTEGER', notNull: true),
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
