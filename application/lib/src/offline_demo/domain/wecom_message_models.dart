import 'dart:typed_data';

class WeComMessageRecord {
  const WeComMessageRecord({
    required this.messageId,
    required this.sequence,
    required this.senderId,
    required this.conversationId,
    required this.contentType,
    required this.sendTime,
    required this.content,
  });

  final int messageId;
  final int sequence;
  final int senderId;
  final String conversationId;
  final int contentType;
  final int sendTime;
  final Uint8List? content;

  factory WeComMessageRecord.fromRow(Map<String, Object?> row) {
    return WeComMessageRecord(
      messageId: row['message_id']! as int,
      sequence: row['sequence']! as int,
      senderId: row['sender_id']! as int,
      conversationId: row['conversation_id']! as String,
      contentType: row['content_type']! as int,
      sendTime: row['send_time']! as int,
      content: row['content'] as Uint8List?,
    );
  }
}
