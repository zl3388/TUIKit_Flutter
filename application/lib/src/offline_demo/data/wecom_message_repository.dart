import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../domain/wecom_message_models.dart';
import 'wecom_protobuf_reader.dart';

class WeComMessageRepository {
  const WeComMessageRepository({
    required Database messageDatabase,
    required Database lookupDatabase,
  })  : _messageDatabase = messageDatabase,
        _lookupDatabase = lookupDatabase;

  static const maxPageSize = 50;
  static const _maxIdsPerQuery = 500;

  final Database _messageDatabase;
  final Database _lookupDatabase;

  Future<List<WeComMessageRecord>> listConversationMessages(
    int conversationNumericId, {
    int limit = maxPageSize,
  }) async {
    if (limit < 1 || limit > maxPageSize) {
      throw RangeError.range(limit, 1, maxPageSize, 'limit');
    }
    final indexRows = await _lookupDatabase.rawQuery(
      '''
SELECT message_id
FROM message_lookup_table
WHERE con_numeric_id = ?
ORDER BY sequence DESC, message_id DESC
LIMIT ?
''',
      [conversationNumericId, limit],
    );
    final messageIds = indexRows
        .map((row) => row['message_id']! as int)
        .toList(growable: false);
    final messagesById = await findMessagesById(messageIds);
    return messageIds.reversed
        .map((id) => messagesById[id])
        .whereType<WeComMessageRecord>()
        .toList(growable: false);
  }

  Future<Map<int, WeComMessageRecord>> findMessagesById(
    Iterable<int> messageIds,
  ) async {
    final uniqueIds = messageIds.where((id) => id > 0).toSet().toList();
    final messages = <int, WeComMessageRecord>{};
    for (var offset = 0; offset < uniqueIds.length; offset += _maxIdsPerQuery) {
      final end = (offset + _maxIdsPerQuery).clamp(0, uniqueIds.length);
      final page = uniqueIds.sublist(offset, end);
      final placeholders = List.filled(page.length, '?').join(',');
      final rows = await _messageDatabase.rawQuery(
        '''
SELECT
  message_id,
  sequence,
  sender_id,
  conversation_id,
  content_type,
  send_time,
  content
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
    return Map<int, WeComMessageRecord>.unmodifiable(messages);
  }
}

String decodeWeComTextMessage(Uint8List content) {
  final buffer = StringBuffer();
  for (final field in readWeComProtoFields(content)) {
    if (field.number != 1 || field.bytes == null) {
      continue;
    }
    final item = readWeComProtoFields(field.bytes!);
    final itemType = firstWeComProtoVarint(item, 1);
    if (itemType != 0 && itemType != 3) {
      continue;
    }
    final payload = firstWeComProtoBytes(item, 2);
    if (payload != null) {
      buffer.write(decodeWeComNestedText(payload));
    }
  }
  return buffer.toString();
}
