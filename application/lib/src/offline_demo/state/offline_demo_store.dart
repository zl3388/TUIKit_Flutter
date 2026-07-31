import 'package:flutter/foundation.dart';

import '../domain/models.dart';
import '../domain/repositories.dart';

class OfflineDemoStore extends ChangeNotifier {
  OfflineDemoStore(this.repositories);

  final OfflineRepositoryBundle repositories;

  OfflineProfile? profile;
  List<OfflineContact> contacts = const [];
  List<OfflineConversation> conversations = const [];
  List<OfflineNotification> notifications = const [];
  List<OfflineAnnouncement> announcements = const [];
  List<OfflineCallRecord> callRecords = const [];
  String scenarioName = '';
  bool isLoading = false;

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
      final results = await Future.wait<Object?>([
        repositories.identity.currentProfile(),
        repositories.contacts.listContacts(),
        repositories.conversations.listConversations(),
        repositories.activity.listNotifications(),
        repositories.activity.listAnnouncements(),
        repositories.activity.listCallRecords(),
        repositories.settings.read('scenario_name'),
      ]);
      profile = results[0] as OfflineProfile;
      contacts = results[1] as List<OfflineContact>;
      conversations = results[2] as List<OfflineConversation>;
      notifications = results[3] as List<OfflineNotification>;
      announcements = results[4] as List<OfflineAnnouncement>;
      callRecords = results[5] as List<OfflineCallRecord>;
      scenarioName = (results[6] as String?) ?? '';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<List<OfflineMessage>> messagesFor(String conversationId) {
    return repositories.conversations.listMessages(conversationId);
  }

  Future<void> markNotificationRead(String notificationId) async {
    await repositories.activity.markNotificationRead(notificationId);
    notifications = await repositories.activity.listNotifications();
    notifyListeners();
  }
}
