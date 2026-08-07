import 'package:sqflite/sqflite.dart';

import '../domain/wecom_conversation_models.dart';

class WeComConversationRepository {
  const WeComConversationRepository(this._database);

  static const maxPageSize = 50;

  final Database _database;

  Future<List<WeComConversationSummary>> listConversations({
    int limit = maxPageSize,
    int offset = 0,
  }) async {
    if (limit < 1 || limit > maxPageSize) {
      throw RangeError.range(limit, 1, maxPageSize, 'limit');
    }
    if (offset < 0) {
      throw RangeError.value(offset, 'offset', 'Must not be negative');
    }

    final rows = await _database.rawQuery(
      '''
SELECT
  conversation.con_numeric_id,
  conversation.id,
  COALESCE(
    NULLIF(conversation.roomname_remark, ''),
    NULLIF(conversation.name, ''),
    ''
  ) AS display_name,
  conversation.name,
  conversation.roomname_remark,
  conversation.last_message_time,
  conversation.last_message_id,
  conversation.is_sticked,
  conversation.is_blocked,
  conversation.status,
  conversation.fold_status,
  unread.conversation_id AS unread_conversation_id,
  unread.begin_cursor AS unread_begin_cursor,
  unread.current_cursor AS unread_current_cursor,
  unread.unread_count
FROM conversation_table AS conversation
LEFT JOIN unread_conversation_table AS unread
  ON unread.conversation_id = conversation.id
ORDER BY conversation.last_message_time DESC, conversation.con_numeric_id DESC
LIMIT ? OFFSET ?
''',
      [limit, offset],
    );
    return rows.map(WeComConversationSummary.fromRow).toList(growable: false);
  }

  Future<List<WeComConversationMember>> listConversationMembers(
    String conversationId,
  ) async {
    final rows = await _database.rawQuery(
      '''
SELECT
  conversation_id,
  user_id,
  join_time,
  gag_type,
  nick_name,
  is_admin
FROM conversation_user_table
WHERE conversation_id = ?
ORDER BY user_id
''',
      [conversationId],
    );
    return rows.map(WeComConversationMember.fromRow).toList(growable: false);
  }
}
