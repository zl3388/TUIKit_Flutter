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
    this.flag = 0,
    this.extraContent,
    this.clientId,
    this.serverId = 0,
    this.hasClientTracking = false,
    this.isInRetryQueue = false,
    this.readStateContent,
    this.isRecalled = false,
    this.recalledText,
    this.quotedMessage,
    this.hasMissingQuotedMessage = false,
  });

  final int messageId;
  final int sequence;
  final int senderId;
  final String conversationId;
  final int contentType;
  final int sendTime;
  final Uint8List? content;
  final int flag;
  final Uint8List? extraContent;
  final String? clientId;
  final int serverId;
  final bool hasClientTracking;
  final bool isInRetryQueue;
  final Uint8List? readStateContent;
  final bool isRecalled;
  final String? recalledText;
  final WeComQuotedMessage? quotedMessage;
  final bool hasMissingQuotedMessage;

  factory WeComMessageRecord.fromRow(Map<String, Object?> row) {
    return WeComMessageRecord(
      messageId: row['message_id']! as int,
      sequence: row['sequence']! as int,
      senderId: row['sender_id']! as int,
      conversationId: row['conversation_id']! as String,
      contentType: row['content_type']! as int,
      sendTime: row['send_time']! as int,
      content: row['content'] as Uint8List?,
      flag: row['flag'] as int? ?? 0,
      extraContent: row['extra_content'] as Uint8List?,
      clientId: row['client_id'] as String?,
      serverId: row['server_id'] as int? ?? 0,
      hasClientTracking: row['has_client_tracking'] == 1,
      isInRetryQueue: row['is_in_retry_queue'] == 1,
      readStateContent: row['read_state_pb'] as Uint8List?,
    );
  }

  WeComMessageRecord copyWith({
    bool? isRecalled,
    String? recalledText,
    WeComQuotedMessage? quotedMessage,
    bool? hasMissingQuotedMessage,
  }) {
    return WeComMessageRecord(
      messageId: messageId,
      sequence: sequence,
      senderId: senderId,
      conversationId: conversationId,
      contentType: contentType,
      sendTime: sendTime,
      content: content,
      flag: flag,
      extraContent: extraContent,
      clientId: clientId,
      serverId: serverId,
      hasClientTracking: hasClientTracking,
      isInRetryQueue: isInRetryQueue,
      readStateContent: readStateContent,
      isRecalled: isRecalled ?? this.isRecalled,
      recalledText: recalledText ?? this.recalledText,
      quotedMessage: quotedMessage ?? this.quotedMessage,
      hasMissingQuotedMessage:
          hasMissingQuotedMessage ?? this.hasMissingQuotedMessage,
    );
  }
}

class WeComQuotedMessage {
  const WeComQuotedMessage({
    required this.messageId,
    required this.contentType,
    required this.content,
    required this.isRecalled,
  });

  final int messageId;
  final int contentType;
  final Uint8List? content;
  final bool isRecalled;
}
