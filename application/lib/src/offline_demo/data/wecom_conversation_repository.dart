import 'dart:convert';
import 'dart:typed_data';

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

  Future<Map<String, String>> listConversationDraftTexts() async {
    final rows = await _database.rawQuery('''
SELECT conversation_id, content
FROM draft_table_1
WHERE content IS NOT NULL AND length(content) > 0
''');
    final drafts = <String, String>{};
    for (final row in rows) {
      final conversationId = row['conversation_id'];
      final content = row['content'];
      if (conversationId is! String || content is! Uint8List) {
        continue;
      }
      try {
        final text = _decodeDraftText(content);
        if (text.isNotEmpty) {
          drafts[conversationId] = text;
        }
      } on FormatException {
        // Unknown future draft parts must not make the conversation list fail.
      }
    }
    return Map<String, String>.unmodifiable(drafts);
  }
}

String _decodeDraftText(Uint8List content) {
  final buffer = StringBuffer();
  for (final field in _readProtoFields(content)) {
    if (field.number != 1 || field.bytes == null) {
      continue;
    }
    final part = _readProtoFields(field.bytes!);
    final partType = _firstVarint(part, 1);
    if (partType != 2) {
      continue;
    }
    final segmentContainer = _firstBytes(part, 5) ?? _firstBytes(part, 2);
    if (segmentContainer == null) {
      continue;
    }
    for (final segmentField in _readProtoFields(segmentContainer)) {
      if (segmentField.number != 1 || segmentField.bytes == null) {
        continue;
      }
      final segment = _readProtoFields(segmentField.bytes!);
      final segmentType = _firstVarint(segment, 1);
      if (segmentType != 0 && segmentType != 3) {
        continue;
      }
      final payload = _firstBytes(segment, 2);
      if (payload != null) {
        buffer.write(_decodeNestedText(payload));
      }
    }
  }
  return buffer.toString();
}

String _decodeNestedText(Uint8List bytes, [int depth = 0]) {
  if (depth < 4) {
    try {
      final fields = _readProtoFields(bytes);
      if (fields.length == 1 &&
          fields.single.number == 1 &&
          fields.single.bytes != null) {
        return _decodeNestedText(fields.single.bytes!, depth + 1);
      }
    } on FormatException {
      // The terminal UTF-8 payload is not itself a protobuf message.
    }
  }
  var end = bytes.length;
  while (end > 0 && bytes[end - 1] == 0) {
    end--;
  }
  return utf8.decode(bytes.sublist(0, end));
}

int? _firstVarint(List<_ProtoField> fields, int number) {
  for (final field in fields) {
    if (field.number == number && field.varint != null) {
      return field.varint;
    }
  }
  return null;
}

Uint8List? _firstBytes(List<_ProtoField> fields, int number) {
  for (final field in fields) {
    if (field.number == number && field.bytes != null) {
      return field.bytes;
    }
  }
  return null;
}

List<_ProtoField> _readProtoFields(Uint8List bytes) {
  final fields = <_ProtoField>[];
  var offset = 0;
  while (offset < bytes.length) {
    if (bytes[offset] == 0) {
      if (bytes.sublist(offset).any((byte) => byte != 0)) {
        throw const FormatException('Invalid protobuf zero tag');
      }
      break;
    }
    final tag = _readVarint(bytes, offset);
    offset = tag.nextOffset;
    final number = tag.value >> 3;
    final wireType = tag.value & 7;
    if (number < 1) {
      throw const FormatException('Invalid protobuf field number');
    }
    switch (wireType) {
      case 0:
        final value = _readVarint(bytes, offset);
        offset = value.nextOffset;
        fields.add(_ProtoField(number: number, varint: value.value));
      case 1:
        offset = _skipFixed(bytes, offset, 8);
        fields.add(_ProtoField(number: number));
      case 2:
        final length = _readVarint(bytes, offset);
        offset = length.nextOffset;
        final end = offset + length.value;
        if (length.value < 0 || end > bytes.length) {
          throw const FormatException('Protobuf length exceeds buffer');
        }
        fields.add(
          _ProtoField(
              number: number, bytes: Uint8List.sublistView(bytes, offset, end)),
        );
        offset = end;
      case 5:
        offset = _skipFixed(bytes, offset, 4);
        fields.add(_ProtoField(number: number));
      default:
        throw FormatException('Unsupported protobuf wire type $wireType');
    }
  }
  return fields;
}

_Varint _readVarint(Uint8List bytes, int offset) {
  var value = 0;
  var shift = 0;
  while (offset < bytes.length && shift <= 63) {
    final byte = bytes[offset++];
    value |= (byte & 0x7f) << shift;
    if (byte & 0x80 == 0) {
      return _Varint(value, offset);
    }
    shift += 7;
  }
  throw const FormatException('Invalid protobuf varint');
}

int _skipFixed(Uint8List bytes, int offset, int length) {
  final end = offset + length;
  if (end > bytes.length) {
    throw const FormatException('Protobuf fixed field exceeds buffer');
  }
  return end;
}

class _ProtoField {
  const _ProtoField({required this.number, this.varint, this.bytes});

  final int number;
  final int? varint;
  final Uint8List? bytes;
}

class _Varint {
  const _Varint(this.value, this.nextOffset);

  final int value;
  final int nextOffset;
}
