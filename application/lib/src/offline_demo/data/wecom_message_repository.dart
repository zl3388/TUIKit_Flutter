import 'package:sqflite/sqflite.dart';

import '../domain/wecom_message_models.dart';

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
  m.message_id,
  m.server_id,
  m.sequence,
  m.sender_id,
  m.conversation_id,
  m.content_type,
  m.send_time,
  m.content,
  CASE WHEN c.message_id IS NULL THEN 0 ELSE 1 END AS has_client_tracking,
  CASE WHEN r.key IS NULL THEN 0 ELSE 1 END AS is_in_retry_queue,
  s.read_state_pb
FROM message_table AS m
LEFT JOIN message_client_id AS c ON c.message_id = m.message_id
LEFT JOIN retry_send_item_kv_table AS r ON r.key = m.message_id
LEFT JOIN message_read_state_table AS s ON s.message_id = m.message_id
WHERE m.message_id IN ($placeholders)
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
