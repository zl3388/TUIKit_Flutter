import 'package:flutter/foundation.dart';

import '../domain/models.dart';
import '../domain/repositories.dart';

class OfflineDemoStore extends ChangeNotifier {
  OfflineDemoStore(this.repositories);

  final OfflineRepositoryBundle repositories;

  OfflineProfile? profile;
  List<OrgUnit> organizationUnits = const [];
  List<DirectoryContact> contacts = const [];
  List<OfflineConversation> conversations = const [];
  List<OfflineNotification> notifications = const [];
  List<OfflineAnnouncement> announcements = const [];
  List<OfflineCallRecord> callRecords = const [];
  bool isLoading = false;

  bool get identityAvailable => repositories.identity.isAvailable;
  bool get contactsAvailable => repositories.contacts.isAvailable;
  bool get conversationsAvailable => repositories.conversations.isAvailable;
  bool get notificationsAvailable => repositories.activity.features.contains(
        ActivityFeature.notifications,
      );
  bool get announcementsAvailable => repositories.activity.features.contains(
        ActivityFeature.announcements,
      );
  bool get callsAvailable => repositories.activity.features.contains(
        ActivityFeature.calls,
      );

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
        repositories.contacts.listOrganizationUnits(),
        repositories.contacts.listContacts(),
        repositories.conversations.listConversations(),
        notificationsAvailable
            ? repositories.activity.listNotifications()
            : Future.value(const <OfflineNotification>[]),
        announcementsAvailable
            ? repositories.activity.listAnnouncements()
            : Future.value(const <OfflineAnnouncement>[]),
        callsAvailable
            ? repositories.activity.listCallRecords()
            : Future.value(const <OfflineCallRecord>[]),
      ]);
      profile = results[0] as OfflineProfile?;
      organizationUnits = results[1] as List<OrgUnit>;
      contacts = results[2] as List<DirectoryContact>;
      conversations = results[3] as List<OfflineConversation>;
      notifications = results[4] as List<OfflineNotification>;
      announcements = results[5] as List<OfflineAnnouncement>;
      callRecords = results[6] as List<OfflineCallRecord>;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> refreshContacts() async {
    final results = await Future.wait<Object>([
      repositories.contacts.listOrganizationUnits(),
      repositories.contacts.listContacts(),
    ]);
    organizationUnits = results[0] as List<OrgUnit>;
    contacts = results[1] as List<DirectoryContact>;
    notifyListeners();
  }

  Future<List<DirectoryContact>> contactsForOrganizationUnit(String id) {
    return repositories.contacts.listContacts(organizationUnitId: id);
  }

  Future<List<OfflineMessage>> messagesFor(String conversationId) {
    return repositories.conversations.listMessages(conversationId);
  }

  Future<List<OfflineConversationMember>> membersFor(String conversationId) {
    return repositories.conversations.listMembers(conversationId);
  }

  Future<List<OfflineAttachment>> attachmentsFor(String messageId) {
    return repositories.conversations.listAttachments(messageId);
  }

  Future<void> openAttachment(OfflineAttachment attachment) {
    return repositories.attachmentOpener.open(attachment);
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

  Future<void> refreshAnnouncements() async {
    announcements = announcementsAvailable
        ? await repositories.activity.listAnnouncements()
        : const [];
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
