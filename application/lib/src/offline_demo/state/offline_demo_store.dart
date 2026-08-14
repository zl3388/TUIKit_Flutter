import 'package:flutter/foundation.dart';

import '../domain/models.dart';
import '../domain/repositories.dart';

class OfflineDemoStore extends ChangeNotifier {
  OfflineDemoStore(this.repositories);

  final OfflineRepositoryBundle repositories;

  OfflineProfile? profile;
  List<DirectoryContact> contacts = const [];
  List<OfflineConversation> conversations = const [];
  List<OfflineNotification> notifications = const [];
  List<OfflineAnnouncement> announcements = const [];
  List<OfflineCallRecord> callRecords = const [];
  bool isLoading = false;

  bool get identityAvailable => repositories.identity.isAvailable;
  bool get contactsAvailable => repositories.contacts.isAvailable;
  bool get conversationsAvailable => repositories.conversations.isAvailable;

  bool supportsConversationFeature(ConversationFeature feature) {
    return repositories.conversations.features.contains(feature);
  }

  int get unreadConversationCount => conversations.fold(
        0,
        (total, conversation) => total + conversation.unreadCount,
      );

  int get unreadNotificationCount =>
      notifications.where((notification) => !notification.isRead).length;

  Future<void> load() async {
    isLoading = true;
    notifyListeners();
    try {
      final identity = repositories.identity.isAvailable
          ? repositories.identity.currentProfile()
          : Future<OfflineProfile?>.value();
      final results = await Future.wait<Object?>([
        identity,
        repositories.contacts.listContacts(),
        repositories.conversations.listConversations(),
        repositories.activity.listNotifications(),
        repositories.activity.listAnnouncements(),
        repositories.activity.listCallRecords(),
      ]);
      profile = results[0] as OfflineProfile?;
      contacts = results[1] as List<DirectoryContact>;
      conversations = results[2] as List<OfflineConversation>;
      notifications = results[3] as List<OfflineNotification>;
      announcements = results[4] as List<OfflineAnnouncement>;
      callRecords = results[5] as List<OfflineCallRecord>;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> refreshContacts() async {
    contacts = await repositories.contacts.listContacts();
    notifyListeners();
  }

  Future<List<OfflineMessage>> messagesFor(String conversationId) {
    return repositories.conversations.listMessages(conversationId);
  }

  Future<List<OfflineConversationMember>> membersFor(String conversationId) {
    return repositories.conversations.listMembers(conversationId);
  }

  Future<OfflineMessage> sendTextMessage({
    required String conversationId,
    required String text,
  }) async {
    final currentProfile = profile;
    if (currentProfile == null) {
      throw StateError('The offline profile is not loaded.');
    }

    final message = await repositories.conversations.sendTextMessage(
      conversationId: conversationId,
      senderProfileId: currentProfile.id,
      text: text,
    );
    await refreshConversations();
    return message;
  }

  Future<void> refreshConversations() async {
    conversations = await repositories.conversations.listConversations();
    notifyListeners();
  }

  Future<void> setConversationPinned(
    String conversationId,
    bool isPinned,
  ) async {
    await repositories.conversations.setPinned(conversationId, isPinned);
    await refreshConversations();
  }

  Future<void> setConversationMuted(
    String conversationId,
    bool isMuted,
  ) async {
    await repositories.conversations.setMuted(conversationId, isMuted);
    await refreshConversations();
  }

  Future<void> markConversationRead(String conversationId) async {
    await repositories.conversations.markRead(conversationId);
    await refreshConversations();
  }

  Future<void> saveConversationDraft(
    String conversationId,
    String text,
  ) {
    return repositories.conversations.saveDraft(conversationId, text);
  }

  Future<void> deleteConversation(String conversationId) async {
    await repositories.conversations.deleteConversation(conversationId);
    await refreshConversations();
  }

  Future<void> markNotificationRead(String notificationId) async {
    await repositories.activity.markNotificationRead(notificationId);
    notifications = await repositories.activity.listNotifications();
    notifyListeners();
  }
}
