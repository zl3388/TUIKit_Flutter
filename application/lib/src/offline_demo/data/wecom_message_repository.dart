import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../domain/wecom_message_models.dart';
import 'wecom_advanced_message_codec.dart';

class WeComMessageRepository {
  const WeComMessageRepository({
    required Database messageDatabase,
    required Database lookupDatabase,
  })  : _messageDatabase = messageDatabase,
        _lookupDatabase = lookupDatabase;

  static const maxPageSize = 50;
  static const _maxIdsPerQuery = 500;
  static const _messageSelect = '''
SELECT
  m.message_id,
  m.server_id,
  m.sequence,
  m.sender_id,
  m.conversation_id,
  m.content_type,
  m.send_time,
  m.flag,
  m.content,
  m.extra_content,
  COALESCE(NULLIF(m.client_id, ''), c.client_id) AS client_id,
  CASE WHEN c.message_id IS NULL THEN 0 ELSE 1 END AS has_client_tracking,
  CASE WHEN r.key IS NULL THEN 0 ELSE 1 END AS is_in_retry_queue,
  s.read_state_pb
FROM message_table AS m
LEFT JOIN message_client_id AS c ON c.message_id = m.message_id
LEFT JOIN retry_send_item_kv_table AS r ON r.key = m.message_id
LEFT JOIN message_read_state_table AS s ON s.message_id = m.message_id
''';

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
        '$_messageSelect WHERE m.message_id IN ($placeholders)',
        page,
      );
      for (final row in rows) {
        final message = WeComMessageRecord.fromRow(row);
        messages[message.messageId] = message;
      }
    }
    final enriched = await _enrichMessageRelations(messages);
    return Map<int, WeComMessageRecord>.unmodifiable(enriched);
  }

  Future<List<WeComMessageRecord>> listCallMessages() async {
    final rows = await _messageDatabase.rawQuery(
      '''
$_messageSelect
WHERE m.content_type IN (40, 503, 1018)
ORDER BY m.send_time DESC, m.message_id DESC
''',
    );
    return rows.map(WeComMessageRecord.fromRow).toList(growable: false);
  }

  Future<Map<int, WeComMessageRecord>> _enrichMessageRelations(
    Map<int, WeComMessageRecord> messages,
  ) async {
    if (messages.isEmpty) {
      return messages;
    }
    final numericIds = await _conversationNumericIds(messages.keys);
    final revokes = await _revokeRecords(numericIds.values.toSet());
    final enriched = <int, WeComMessageRecord>{};
    for (final entry in messages.entries) {
      final numericId = numericIds[entry.key];
      enriched[entry.key] = _applyRevoke(entry.value, numericId, revokes);
    }
    for (final entry in enriched.entries.toList(growable: false)) {
      final message = entry.value;
      if (message.contentType != 2 || message.flag & 512 == 0) {
        continue;
      }
      WeComQuoteReference? reference;
      try {
        reference = decodeWeComQuoteReference(message.extraContent);
      } on FormatException {
        enriched[entry.key] = message.copyWith(hasMissingQuotedMessage: true);
        continue;
      }
      if (reference == null) {
        enriched[entry.key] = message.copyWith(hasMissingQuotedMessage: true);
        continue;
      }
      final rows = await _messageDatabase.rawQuery(
        '''
$_messageSelect
WHERE m.conversation_id = ?
  AND m.send_time = ?
  AND (m.client_id = ? OR c.client_id = ?)
LIMIT 2
''',
        [
          message.conversationId,
          reference.parentSendTime,
          reference.parentAppInfo,
          reference.parentAppInfo,
        ],
      );
      if (rows.length != 1) {
        enriched[entry.key] = message.copyWith(hasMissingQuotedMessage: true);
        continue;
      }
      final parent = _applyRevoke(
        WeComMessageRecord.fromRow(rows.single),
        numericIds[entry.key],
        revokes,
      );
      enriched[entry.key] = message.copyWith(
        quotedMessage: WeComQuotedMessage(
          messageId: parent.messageId,
          contentType: parent.contentType,
          content: parent.content,
          isRecalled: parent.isRecalled,
        ),
      );
    }
    return enriched;
  }

  Future<Map<int, int>> _conversationNumericIds(
    Iterable<int> messageIds,
  ) async {
    final ids = messageIds.toList(growable: false);
    final result = <int, int>{};
    for (var offset = 0; offset < ids.length; offset += _maxIdsPerQuery) {
      final end = (offset + _maxIdsPerQuery).clamp(0, ids.length);
      final page = ids.sublist(offset, end);
      final placeholders = List.filled(page.length, '?').join(',');
      final rows = await _lookupDatabase.rawQuery(
        '''
SELECT message_id, con_numeric_id
FROM message_lookup_table
WHERE message_id IN ($placeholders)
''',
        page,
      );
      for (final row in rows) {
        result[row['message_id']! as int] = row['con_numeric_id']! as int;
      }
    }
    return result;
  }

  Future<Map<String, _RevokeRecord>> _revokeRecords(
    Set<int> conversationNumericIds,
  ) async {
    if (conversationNumericIds.isEmpty) {
      return const {};
    }
    final ids = conversationNumericIds.toList(growable: false);
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await _messageDatabase.rawQuery(
      '''
SELECT con_nid, appinfo, sendtime, msgdata_pb
FROM message_revoke_record_table_v2
WHERE con_nid IN ($placeholders)
''',
      ids,
    );
    return {
      for (final row in rows)
        _revokeKey(
          row['con_nid']! as int,
          row['appinfo']! as String,
          row['sendtime']! as int,
        ): _RevokeRecord(
          payload: row['msgdata_pb'] as List<int>?,
        ),
    };
  }

  WeComMessageRecord _applyRevoke(
    WeComMessageRecord message,
    int? conversationNumericId,
    Map<String, _RevokeRecord> revokes,
  ) {
    final clientId = message.clientId;
    if (conversationNumericId == null || clientId == null) {
      return message;
    }
    final revoke =
        revokes[_revokeKey(conversationNumericId, clientId, message.sendTime)];
    if (revoke == null) {
      return message;
    }
    String? snippet;
    try {
      snippet = decodeWeComRevokeContent(
        revoke.payload == null ? null : Uint8List.fromList(revoke.payload!),
      ).snippet;
    } on FormatException {
      snippet = null;
    }
    return message.copyWith(
      isRecalled: true,
      recalledText: snippet == null || snippet.isEmpty ? '该消息已被撤回' : snippet,
    );
  }
}

String _revokeKey(int conversationNumericId, String appInfo, int sendTime) =>
    '$conversationNumericId\u0000$appInfo\u0000$sendTime';

class _RevokeRecord {
  const _RevokeRecord({required this.payload});

  final List<int>? payload;
}
