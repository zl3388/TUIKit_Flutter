import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../domain/models.dart';
import '../domain/repositories.dart';
import '../domain/wecom_conversation_models.dart';
import '../domain/wecom_message_models.dart';
import 'wecom_conversation_repository.dart';
import 'wecom_local_simulation_repository.dart';
import 'wecom_merged_conversation_repository.dart';
import 'wecom_media_repository.dart';
import 'wecom_message_content_decoder.dart';
import 'wecom_message_repository.dart';
import 'wecom_overlay_command_service.dart';
import 'wecom_read_state_codec.dart';

class WeComOfflineConversationRepository implements ConversationRepository {
  const WeComOfflineConversationRepository({
    required this.datasetId,
    required this.currentUserId,
    required WeComMergedConversationRepository conversations,
    required WeComMessageRepository messages,
    required ContactRepository contacts,
    required WeComOverlayCommandService commands,
    WeComMediaRepository? media,
    WeComLocalSimulationRepository? simulation,
  })  : _conversations = conversations,
        _messages = messages,
        _contacts = contacts,
        _commands = commands,
        _media = media,
        _simulation = simulation;

  static const _databaseName = 'session.db';
  static const _conversationTable = 'conversation_table';

  final String datasetId;
  final int currentUserId;
  final WeComMergedConversationRepository _conversations;
  final WeComMessageRepository _messages;
  final ContactRepository _contacts;
  final WeComOverlayCommandService _commands;
  final WeComMediaRepository? _media;
  final WeComLocalSimulationRepository? _simulation;

  @override
  bool get isAvailable => true;

  @override
  Set<ConversationFeature> get features => {
        ConversationFeature.members,
        ConversationFeature.messages,
        if (_media != null) ConversationFeature.attachments,
        ConversationFeature.pin,
        ConversationFeature.mute,
        if (_simulation != null) ConversationFeature.sendText,
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
    final now = _simulation?.now;
    final simulatedExchanges =
        await _simulation?.listExchanges() ?? const <WeComSimulatedExchange>[];
    final mapped = summaries.map((summary) {
      final lastMessage = lastMessages[summary.lastMessageId];
      final simulatedPreview = now == null
          ? null
          : _latestSimulatedPreview(
              simulatedExchanges.where(
                (exchange) => exchange.conversationId == summary.id,
              ),
              now,
            );
      final baseLastMessageAt = _unixSeconds(summary.lastMessageTime);
      final useSimulatedPreview = simulatedPreview != null &&
          (baseLastMessageAt == null ||
              simulatedPreview.sentAt.isAfter(baseLastMessageAt));
      return OfflineConversation(
        id: summary.id,
        type: _conversationType(summary.id),
        title: _conversationTitle(summary, contactsById),
        avatarPath: null,
        lastMessagePreview: useSimulatedPreview
            ? simulatedPreview.text
            : _messageContent(
                lastMessage?.conversationId == summary.id ? lastMessage : null,
              ).text,
        lastMessageAt:
            useSimulatedPreview ? simulatedPreview.sentAt : baseLastMessageAt,
        draftText: drafts[summary.id] ?? '',
        unreadCount: summary.unreadState?.unreadCount ?? 0,
        isPinned: summary.pinnedFlag == 1,
        isMuted: summary.blockedFlag == 1,
      );
    }).toList(growable: true)
      ..sort(_compareConversations);

    return List<OfflineConversation>.unmodifiable(mapped);
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
    final mapped = messages
        .where((message) => message.conversationId == conversationId)
        .map((message) {
      final senderId = message.senderId.toString();
      final quotedMessage = message.quotedMessage;
      var content = _messageContent(message);
      if ((quotedMessage != null || message.hasMissingQuotedMessage) &&
          message.contentType == 2 &&
          message.content != null) {
        final parts = decodeWeComTextMessageParts(message.content!);
        if (parts.length > 1) {
          content = WeComDecodedMessageContent(kind: 'text', text: parts.last);
        }
      }
      final replyPreview = message.hasMissingQuotedMessage
          ? '原消息不可用'
          : quotedMessage == null
              ? null
              : quotedMessage.isRecalled
                  ? '该消息已被撤回'
                  : _decodedContent(
                      quotedMessage.contentType,
                      quotedMessage.content,
                    ).text;
      final progress = _messageProgress(message);
      return OfflineMessage(
        id: message.messageId.toString(),
        conversationId: message.conversationId,
        senderProfileId: senderId,
        senderName: contactsById[senderId]?.displayName ?? senderId,
        kind: content.kind,
        text: message.isRecalled
            ? message.recalledText ?? '该消息已被撤回'
            : content.text,
        sentAt: DateTime.fromMillisecondsSinceEpoch(
          message.sendTime * 1000,
          isUtc: true,
        ),
        status: '',
        isRecalled: message.isRecalled,
        replyToMessageId: quotedMessage?.messageId.toString(),
        replyPreview: replyPreview,
        progress: progress.progress,
        progressSource: progress.progress == OfflineMessageProgress.none
            ? OfflineMessageProgressSource.none
            : OfflineMessageProgressSource.weComObservation,
        peerReaderCount: progress.peerReaderCount,
      );
    }).toList(growable: true);
    final simulation = _simulation;
    if (simulation != null) {
      final now = simulation.now;
      for (final exchange
          in await simulation.listExchanges(conversationId: conversationId)) {
        mapped.add(_simulatedOutgoingMessage(exchange, contactsById, now));
        if (exchange.peerProfileId != null &&
            !now.isBefore(exchange.automaticReplyAt)) {
          mapped.add(_simulatedAutomaticReply(exchange, contactsById));
        }
      }
    }
    mapped.sort((left, right) {
      final time = left.sentAt.compareTo(right.sentAt);
      return time != 0 ? time : left.id.compareTo(right.id);
    });
    return List<OfflineMessage>.unmodifiable(mapped);
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
  }) async {
    final simulation = _simulation;
    if (simulation == null) {
      return _notMapped('Text message sending');
    }
    await _findSummary(conversationId);
    final senderId = int.tryParse(senderProfileId);
    if (senderId != currentUserId) {
      throw ArgumentError.value(
        senderProfileId,
        'senderProfileId',
        'Must identify the active WeCom user.',
      );
    }
    final exchange = await simulation.enqueueTextExchange(
      conversationId: conversationId,
      senderProfileId: senderProfileId,
      peerProfileId: _singlePeerId(conversationId),
      text: text,
    );
    final contacts = await _contacts.listContacts();
    return _simulatedOutgoingMessage(
      exchange,
      {for (final contact in contacts) contact.id: contact},
      simulation.now,
    );
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

  int _compareConversations(
    OfflineConversation left,
    OfflineConversation right,
  ) {
    if (left.isPinned != right.isPinned) {
      return left.isPinned ? -1 : 1;
    }
    final leftTime = left.lastMessageAt;
    final rightTime = right.lastMessageAt;
    if (leftTime == null || rightTime == null) {
      if (leftTime == rightTime) {
        return left.id.compareTo(right.id);
      }
      return leftTime == null ? 1 : -1;
    }
    final time = rightTime.compareTo(leftTime);
    return time != 0 ? time : left.id.compareTo(right.id);
  }

  ({String text, DateTime sentAt})? _latestSimulatedPreview(
    Iterable<WeComSimulatedExchange> exchanges,
    DateTime now,
  ) {
    ({String text, DateTime sentAt})? latest;
    for (final exchange in exchanges) {
      final candidate = exchange.peerProfileId != null &&
              !now.isBefore(exchange.automaticReplyAt)
          ? (
              text: exchange.automaticReplyText,
              sentAt: exchange.automaticReplyAt,
            )
          : (text: exchange.text, sentAt: exchange.createdAt);
      if (latest == null || candidate.sentAt.isAfter(latest.sentAt)) {
        latest = candidate;
      }
    }
    return latest;
  }

  OfflineMessage _simulatedOutgoingMessage(
    WeComSimulatedExchange exchange,
    Map<String, DirectoryContact> contactsById,
    DateTime now,
  ) {
    final hasPeer = exchange.peerProfileId != null;
    final progress = now.isBefore(exchange.serverAcknowledgedAt)
        ? OfflineMessageProgress.waitingForServer
        : hasPeer && !now.isBefore(exchange.peerReadAt)
            ? OfflineMessageProgress.peerRead
            : OfflineMessageProgress.serverAcknowledged;
    return OfflineMessage(
      id: 'local:${exchange.eventKey}',
      conversationId: exchange.conversationId,
      senderProfileId: exchange.senderProfileId,
      senderName: contactsById[exchange.senderProfileId]?.displayName ??
          exchange.senderProfileId,
      kind: 'text',
      text: exchange.text,
      sentAt: exchange.createdAt,
      status: '',
      isRecalled: false,
      progress: progress,
      progressSource: OfflineMessageProgressSource.localSimulation,
      peerReaderCount: progress == OfflineMessageProgress.peerRead ? 1 : 0,
      nextProgressAt: exchange.nextTransitionAfter(now),
    );
  }

  OfflineMessage _simulatedAutomaticReply(
    WeComSimulatedExchange exchange,
    Map<String, DirectoryContact> contactsById,
  ) {
    final peerProfileId = exchange.peerProfileId!;
    return OfflineMessage(
      id: 'local-reply:${exchange.eventKey}',
      conversationId: exchange.conversationId,
      senderProfileId: peerProfileId,
      senderName: contactsById[peerProfileId]?.displayName ?? peerProfileId,
      kind: 'text',
      text: exchange.automaticReplyText,
      sentAt: exchange.automaticReplyAt,
      status: '',
      isRecalled: false,
      progressSource: OfflineMessageProgressSource.localSimulation,
    );
  }

  WeComDecodedMessageContent _messageContent(WeComMessageRecord? message) {
    if (message == null) {
      return const WeComDecodedMessageContent(kind: 'unsupported', text: '');
    }
    try {
      return _decodedContent(message.contentType, message.content);
    } on FormatException {
      return const WeComDecodedMessageContent(
        kind: 'unsupported',
        text: '[无法解析的消息]',
      );
    }
  }

  WeComDecodedMessageContent _decodedContent(
    int contentType,
    Uint8List? content,
  ) {
    return decodeWeComMessageContent(contentType, content);
  }

  ({OfflineMessageProgress progress, int peerReaderCount}) _messageProgress(
    WeComMessageRecord message,
  ) {
    if (message.senderId != currentUserId) {
      return (
        progress: OfflineMessageProgress.none,
        peerReaderCount: 0,
      );
    }
    final readStateContent = message.readStateContent;
    if (readStateContent != null) {
      try {
        final readState = decodeWeComReadState(readStateContent);
        if (readState.readerIds.isNotEmpty) {
          return (
            progress: OfflineMessageProgress.peerRead,
            peerReaderCount: readState.readerIds.length,
          );
        }
        if (readState.field2Ids.isNotEmpty) {
          return (
            progress: OfflineMessageProgress.serverAcknowledged,
            peerReaderCount: 0,
          );
        }
      } on FormatException {
        // An unknown read-state payload must not become a guessed status.
      }
    }
    if (message.serverId == 0 &&
        message.hasClientTracking &&
        message.isInRetryQueue) {
      return (
        progress: OfflineMessageProgress.waitingForServer,
        peerReaderCount: 0,
      );
    }
    return (
      progress: OfflineMessageProgress.none,
      peerReaderCount: 0,
    );
  }

  Future<T> _notMapped<T>(String feature) {
    return Future<T>.error(
      UnsupportedError(
        '$feature is not mapped to the active WeCom schema yet.',
      ),
    );
  }
}
