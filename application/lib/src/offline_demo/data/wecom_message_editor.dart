import '../domain/models.dart';
import '../domain/repositories.dart';
import 'wecom_message_overlay_repository.dart';
import 'wecom_message_repository.dart';

class WeComMessageSender {
  const WeComMessageSender({required this.id, required this.displayName});

  final String id;
  final String displayName;
}

class WeComMessageEditor {
  const WeComMessageEditor({
    required ConversationRepository conversations,
    required ContactRepository contacts,
    required WeComMessageRepository messages,
    required WeComMessageOverlayRepository overlay,
    required bool Function() canEdit,
  })  : _conversations = conversations,
        _contacts = contacts,
        _messages = messages,
        _overlay = overlay,
        _canEdit = canEdit;

  final ConversationRepository _conversations;
  final ContactRepository _contacts;
  final WeComMessageRepository _messages;
  final WeComMessageOverlayRepository _overlay;
  final bool Function() _canEdit;

  Future<List<WeComMessageSender>> sendersFor(String conversationId) async {
    _requireAdmin();
    final allowed = <String>{};
    if (conversationId.startsWith('S:')) {
      final parts = conversationId.substring(2).split('_');
      if (parts.length == 2) {
        allowed.addAll(parts.where(_isValidUserId));
      }
    } else if (conversationId.startsWith('R:')) {
      allowed.addAll((await _conversations.listMembers(conversationId))
          .map((member) => member.userId)
          .where(_isValidUserId));
    } else {
      throw UnsupportedError('Only single and group chats can be edited.');
    }
    final currentMessages = await _conversations.listMessages(conversationId);
    allowed.addAll(currentMessages
        .map((message) => message.senderProfileId)
        .where(_isValidUserId));
    final names = <String, String>{
      for (final contact in await _contacts.listContacts())
        contact.id: contact.displayName,
      for (final message in currentMessages)
        message.senderProfileId: message.senderName,
    };
    if (conversationId.startsWith('R:')) {
      for (final member in await _conversations.listMembers(conversationId)) {
        names[member.userId] = member.displayName;
      }
    }
    return (allowed.toList()..sort())
        .map((id) => WeComMessageSender(
              id: id,
              displayName: names[id] ?? id,
            ))
        .toList(growable: false);
  }

  Future<WeComMessageOverlayEdit> add({
    required String conversationId,
    required String senderId,
    required String text,
  }) async {
    await _requireSender(conversationId, senderId);
    final body = _body(text);
    _requireAdmin();
    return _overlay.append(
      conversationId: conversationId,
      targetKey: _overlay.newMessageId(),
      action: 'add',
      state: WeComMessageOverlayState.text(
        senderId: senderId,
        text: body,
        sentAt: DateTime.now().toUtc(),
      ),
    );
  }

  Future<WeComMessageOverlayEdit> replace({
    required String conversationId,
    required String messageId,
    required String senderId,
    required String text,
  }) async {
    await _requireSender(conversationId, senderId);
    final body = _body(text);
    final message = await _visibleMessage(conversationId, messageId);
    if (message.text == body &&
        message.senderProfileId == senderId &&
        message.kind == 'text') {
      throw StateError('Message has no changes.');
    }
    final targetKey = await _targetKey(message);
    _requireAdmin();
    return _overlay.append(
      conversationId: conversationId,
      targetKey: targetKey,
      action: 'replace',
      state: WeComMessageOverlayState.text(
        senderId: senderId,
        text: body,
        sentAt: message.id.startsWith('overlay:') ? message.sentAt : null,
      ),
    );
  }

  Future<WeComMessageOverlayEdit> hide({
    required String conversationId,
    required String messageId,
  }) async {
    _requireAdmin();
    final message = await _visibleMessage(conversationId, messageId);
    final targetKey = await _targetKey(message);
    _requireAdmin();
    return _overlay.append(
      conversationId: conversationId,
      targetKey: targetKey,
      action: 'hide',
      state: const WeComMessageOverlayState.hidden(),
    );
  }

  Future<void> undo(WeComMessageOverlayEdit edit) async {
    _requireAdmin();
    await _overlay.undo(edit);
  }

  Future<void> _requireSender(String conversationId, String senderId) async {
    _requireAdmin();
    final allowed = await sendersFor(conversationId);
    if (!allowed.any((sender) => sender.id == senderId)) {
      throw ArgumentError.value(
        senderId,
        'senderId',
        'Sender is not identified in this conversation.',
      );
    }
  }

  Future<OfflineMessage> _visibleMessage(
    String conversationId,
    String messageId,
  ) async {
    final messages = await _conversations.listMessages(conversationId);
    for (final message in messages) {
      if (message.id == messageId) return message;
    }
    throw StateError('Message is not visible in this conversation.');
  }

  Future<String> _targetKey(OfflineMessage message) async {
    if (message.id.startsWith('overlay:') ||
        message.id.startsWith('local:') ||
        message.id.startsWith('local-reply:')) {
      return _overlay.targetKeyForProjected(message.id);
    }
    final numericId = int.tryParse(message.id);
    if (numericId == null) {
      throw UnsupportedError('This message has no stable source identity.');
    }
    final source = (await _messages.findMessagesById([numericId]))[numericId];
    if (source == null || source.conversationId != message.conversationId) {
      throw StateError('Original message is no longer available.');
    }
    return _overlay.targetKeyForBase(source);
  }

  String _body(String text) {
    final body = text.trim();
    if (body.isEmpty) {
      throw ArgumentError.value(text, 'text', 'Message text cannot be empty.');
    }
    return body;
  }

  bool _isValidUserId(String id) =>
      int.tryParse(id) != null && int.parse(id) > 0;

  void _requireAdmin() {
    if (!_canEdit()) {
      throw StateError('Management mode is required.');
    }
  }
}
