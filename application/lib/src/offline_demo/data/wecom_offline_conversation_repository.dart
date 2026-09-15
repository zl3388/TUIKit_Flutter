import 'package:path/path.dart' as p;

import '../domain/models.dart';
import '../domain/repositories.dart';
import '../domain/wecom_conversation_models.dart';
import '../domain/wecom_message_models.dart';
import 'wecom_conversation_repository.dart';
import 'wecom_merged_conversation_repository.dart';
import 'wecom_media_repository.dart';
import 'wecom_message_content_decoder.dart';
import 'wecom_message_repository.dart';
import 'wecom_overlay_command_service.dart';

class WeComOfflineConversationRepository implements ConversationRepository {
  const WeComOfflineConversationRepository({
    required this.datasetId,
    required this.currentUserId,
    required WeComMergedConversationRepository conversations,
    required WeComMessageRepository messages,
    required ContactRepository contacts,
    required WeComOverlayCommandService commands,
    WeComMediaRepository? media,
  })  : _conversations = conversations,
        _messages = messages,
        _contacts = contacts,
        _commands = commands,
        _media = media;

  static const _databaseName = 'session.db';
  static const _conversationTable = 'conversation_table';

  final String datasetId;
  final int currentUserId;
  final WeComMergedConversationRepository _conversations;
  final WeComMessageRepository _messages;
  final ContactRepository _contacts;
  final WeComOverlayCommandService _commands;
  final WeComMediaRepository? _media;

  @override
  bool get isAvailable => true;

  @override
  Set<ConversationFeature> get features => {
        ConversationFeature.members,
        ConversationFeature.messages,
        if (_media != null) ConversationFeature.attachments,
        ConversationFeature.pin,
        ConversationFeature.mute,
      };

  @override
  Future<List<OfflineConversation>> listConversations() async {
    final summaries = await _listAllSummaries();
    final drafts = await _conversations.listConversationDraftTexts();
    final lastMessages = await _messages.findMessagesById(
      summaries.map((summary) => summary.lastMessageId).whereType<int>(),
    );
    final contacts = await _contacts.listContacts();
    final contactsById = <String, DirectoryContact>{
      for (final contact in contacts) contact.id: contact,
    };
    final mapped = summaries.map((summary) {
      final lastMessage = lastMessages[summary.lastMessageId];
      return OfflineConversation(
        id: summary.id,
        type: _conversationType(summary.id),
        title: _conversationTitle(summary, contactsById),
        avatarPath: null,
        lastMessagePreview: _messageContent(
          lastMessage?.conversationId == summary.id ? lastMessage : null,
        ).text,
        lastMessageAt: _unixSeconds(summary.lastMessageTime),
        draftText: drafts[summary.id] ?? '',
        unreadCount: summary.unreadState?.unreadCount ?? 0,
        isPinned: summary.pinnedFlag == 1,
        isMuted: summary.blockedFlag == 1,
      );
    }).toList(growable: false);

    return List<OfflineConversation>.unmodifiable([
      ...mapped.where((conversation) => conversation.isPinned),
      ...mapped.where((conversation) => !conversation.isPinned),
    ]);
  }

  @override
  Future<List<OfflineConversationMember>> listMembers(
    String conversationId,
  ) async {
    await _findSummary(conversationId);
    final members = await _conversations.listConversationMembers(
      conversationId,
    );
    final contacts = await _contacts.listContacts();
    final contactsById = <String, DirectoryContact>{
      for (final contact in contacts) contact.id: contact,
    };
    return members.map((member) {
      final userId = member.userId.toString();
      final nickname = _nonEmpty(member.nickname);
      return OfflineConversationMember(
        conversationId: member.conversationId,
        userId: userId,
        displayName: nickname ?? contactsById[userId]?.displayName ?? userId,
        nickname: nickname,
        isAdmin: member.adminFlag == 1,
        gagType: member.gagType,
        joinedAt: _unixSeconds(member.joinTime),
      );
    }).toList(growable: false);
  }

  @override
  Future<void> setPinned(String conversationId, bool isPinned) async {
    final summary = await _findSummary(conversationId);
    if ((summary.pinnedFlag == 1) == isPinned) {
      return;
    }
    await _commands.upsert(
      datasetId: datasetId,
      databaseName: _databaseName,
      tableName: _conversationTable,
      rowKey: {'con_numeric_id': summary.numericId},
      values: {'is_sticked': isPinned ? 1 : 0},
    );
  }

  @override
  Future<void> setMuted(String conversationId, bool isMuted) async {
    final summary = await _findSummary(conversationId);
    if ((summary.blockedFlag == 1) == isMuted) {
      return;
    }
    await _commands.upsert(
      datasetId: datasetId,
      databaseName: _databaseName,
      tableName: _conversationTable,
      rowKey: {'con_numeric_id': summary.numericId},
      values: {'is_blocked': isMuted ? 1 : 0},
    );
  }

  @override
  Future<List<OfflineMessage>> listMessages(String conversationId) async {
    final summary = await _findSummary(conversationId);
    final messages = await _messages.listConversationMessages(
      summary.numericId,
    );
    final contacts = await _contacts.listContacts();
    final contactsById = <String, DirectoryContact>{
      for (final contact in contacts) contact.id: contact,
    };
    return messages
        .where((message) => message.conversationId == conversationId)
        .map((message) {
      final senderId = message.senderId.toString();
      final content = _messageContent(message);
      return OfflineMessage(
        id: message.messageId.toString(),
        conversationId: message.conversationId,
        senderProfileId: senderId,
        senderName: contactsById[senderId]?.displayName ?? senderId,
        kind: content.kind,
        text: content.text,
        sentAt: DateTime.fromMillisecondsSinceEpoch(
          message.sendTime * 1000,
          isUtc: true,
        ),
        status: '',
        isRecalled: false,
      );
    }).toList(growable: false);
  }

  @override
  Future<List<OfflineAttachment>> listAttachments(String messageId) async {
    final media = _media;
    if (media == null) {
      return _notMapped('Message attachments');
    }
    final numericId = int.tryParse(messageId);
    if (numericId == null) {
      throw ArgumentError.value(messageId, 'messageId', 'Must be an integer');
    }
    final message = (await _messages.findMessagesById([numericId]))[numericId];
    if (message == null) {
      return const [];
    }
    final attachments = await media.listMessageAttachments(message);
    return attachments.map((attachment) {
      final relativePath = attachment.location.relativePath ?? '';
      final fileName = attachment.name.isNotEmpty
          ? attachment.name
          : (relativePath.isEmpty
              ? 'attachment-${attachment.fileIndex + 1}'
              : p.basename(relativePath));
      return OfflineAttachment(
        id: '${attachment.origin}:${attachment.messageId}:'
            '${attachment.fileIndex}',
        messageId: attachment.messageId.toString(),
        kind: attachment.kind ?? 'file',
        relativePath: relativePath,
        fileName: fileName,
        sizeBytes: attachment.sizeBytes,
        localPath: attachment.location.file?.path,
        unavailableReason: attachment.location.isAvailable
            ? null
            : attachment.location.status.name,
      );
    }).toList(growable: false);
  }

  @override
  Future<OfflineMessage> sendTextMessage({
    required String conversationId,
    required String senderProfileId,
    required String text,
    DateTime? sentAt,
  }) {
    return _notMapped('Text message sending');
  }

  @override
  Future<void> markRead(String conversationId) {
    return _notMapped('Unread cursor write-back');
  }

  @override
  Future<void> saveDraft(String conversationId, String text) {
    return _notMapped('Draft protobuf write-back');
  }

  @override
  Future<void> deleteConversation(String conversationId) {
    return _notMapped('Conversation cascade deletion');
  }

  Future<List<WeComConversationSummary>> _listAllSummaries() async {
    final summaries = <WeComConversationSummary>[];
    var offset = 0;
    while (true) {
      final page = await _conversations.listConversations(offset: offset);
      summaries.addAll(page);
      if (page.length < WeComConversationRepository.maxPageSize) {
        return summaries;
      }
      offset += page.length;
    }
  }

  Future<WeComConversationSummary> _findSummary(String conversationId) async {
    for (final summary in await _listAllSummaries()) {
      if (summary.id == conversationId) {
        return summary;
      }
    }
    throw StateError('Conversation $conversationId does not exist.');
  }

  String _conversationTitle(
    WeComConversationSummary summary,
    Map<String, DirectoryContact> contactsById,
  ) {
    if (summary.displayName.isNotEmpty) {
      return summary.displayName;
    }
    final peerId = _singlePeerId(summary.id);
    return contactsById[peerId]?.displayName ?? summary.id;
  }

  String? _singlePeerId(String conversationId) {
    if (!conversationId.startsWith('S:')) {
      return null;
    }
    final parts = conversationId.substring(2).split('_');
    if (parts.length != 2) {
      return null;
    }
    final current = currentUserId.toString();
    if (parts[0] == current && parts[1] != current) {
      return parts[1];
    }
    if (parts[1] == current && parts[0] != current) {
      return parts[0];
    }
    return null;
  }

  String _conversationType(String id) {
    if (id.startsWith('R:')) {
      return 'group';
    }
    if (id.startsWith('S:')) {
      return 'single';
    }
    if (id.startsWith('M:')) {
      return 'wechat_contact';
    }
    if (id.startsWith('O:')) {
      return 'app';
    }
    if (id.startsWith('Y:')) {
      return 'system';
    }
    return switch (id) {
      'FILEASSIST' => 'file_assist',
      'ANNOUNCE' => 'announce',
      'MAIL' => 'mail',
      'APPROVAL' => 'approval',
      'CLOUD_DISK_ASSIST' => 'cloud_disk_assist',
      _ => 'other',
    };
  }

  DateTime? _unixSeconds(int? value) {
    if (value == null || value == 0) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(value * 1000, isUtc: true);
  }

  String? _nonEmpty(String? value) {
    return value == null || value.isEmpty ? null : value;
  }

  WeComDecodedMessageContent _messageContent(WeComMessageRecord? message) {
    if (message == null) {
      return const WeComDecodedMessageContent(kind: 'unsupported', text: '');
    }
    try {
      return decodeWeComMessageContent(message.contentType, message.content);
    } on FormatException {
      return const WeComDecodedMessageContent(
        kind: 'unsupported',
        text: '[无法解析的消息]',
      );
    }
  }

  Future<T> _notMapped<T>(String feature) {
    return Future<T>.error(
      UnsupportedError(
        '$feature is not mapped to the active WeCom schema yet.',
      ),
    );
  }
}
