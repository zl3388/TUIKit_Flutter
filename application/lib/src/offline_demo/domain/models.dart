class OfflineProfile {
  const OfflineProfile({
    required this.id,
    required this.displayName,
    required this.title,
    required this.department,
    required this.status,
    this.avatarPath,
    this.phone,
    this.email,
  });

  final String id;
  final String displayName;
  final String title;
  final String department;
  final String status;
  final String? avatarPath;
  final String? phone;
  final String? email;

  factory OfflineProfile.fromRow(Map<String, Object?> row) => OfflineProfile(
        id: row['id']! as String,
        displayName: row['display_name']! as String,
        title: row['title']! as String,
        department: row['department']! as String,
        status: row['status']! as String,
        avatarPath: row['avatar_path'] as String?,
        phone: row['phone'] as String?,
        email: row['email'] as String?,
      );
}

class OrgUnit {
  const OrgUnit({
    required this.id,
    required this.name,
    required this.sortOrder,
    this.parentId,
  });

  final String id;
  final String name;
  final String? parentId;
  final int sortOrder;

  factory OrgUnit.fromRow(Map<String, Object?> row) => OrgUnit(
        id: row['id']! as String,
        name: row['name']! as String,
        parentId: row['parent_id'] as String?,
        sortOrder: row['sort_order']! as int,
      );
}

class OfflineContact {
  const OfflineContact({
    required this.id,
    required this.profile,
    required this.orgUnitName,
    required this.isFavorite,
    this.alias,
  });

  final String id;
  final OfflineProfile profile;
  final String orgUnitName;
  final bool isFavorite;
  final String? alias;

  factory OfflineContact.fromRow(Map<String, Object?> row) => OfflineContact(
        id: row['contact_id']! as String,
        profile: OfflineProfile.fromRow(row),
        orgUnitName: row['org_unit_name']! as String,
        isFavorite: row['is_favorite'] == 1,
        alias: row['alias'] as String?,
      );
}

class OfflineConversation {
  const OfflineConversation({
    required this.id,
    required this.type,
    required this.title,
    required this.lastMessagePreview,
    required this.lastMessageAt,
    required this.unreadCount,
    required this.isPinned,
    required this.isMuted,
    this.avatarPath,
  });

  final String id;
  final String type;
  final String title;
  final String? avatarPath;
  final String lastMessagePreview;
  final DateTime lastMessageAt;
  final int unreadCount;
  final bool isPinned;
  final bool isMuted;

  factory OfflineConversation.fromRow(Map<String, Object?> row) =>
      OfflineConversation(
        id: row['id']! as String,
        type: row['type']! as String,
        title: row['title']! as String,
        avatarPath: row['avatar_path'] as String?,
        lastMessagePreview: row['last_message_preview']! as String,
        lastMessageAt: DateTime.parse(row['last_message_at']! as String),
        unreadCount: row['unread_count']! as int,
        isPinned: row['is_pinned'] == 1,
        isMuted: row['is_muted'] == 1,
      );
}

class OfflineMessage {
  const OfflineMessage({
    required this.id,
    required this.conversationId,
    required this.senderProfileId,
    required this.senderName,
    required this.kind,
    required this.text,
    required this.sentAt,
    required this.status,
    required this.isRecalled,
    this.replyToMessageId,
  });

  final String id;
  final String conversationId;
  final String senderProfileId;
  final String senderName;
  final String kind;
  final String text;
  final DateTime sentAt;
  final String status;
  final bool isRecalled;
  final String? replyToMessageId;

  factory OfflineMessage.fromRow(Map<String, Object?> row) => OfflineMessage(
        id: row['id']! as String,
        conversationId: row['conversation_id']! as String,
        senderProfileId: row['sender_profile_id']! as String,
        senderName: row['sender_name']! as String,
        kind: row['kind']! as String,
        text: row['text']! as String,
        sentAt: DateTime.parse(row['sent_at']! as String),
        status: row['status']! as String,
        isRecalled: row['is_recalled'] == 1,
        replyToMessageId: row['reply_to_message_id'] as String?,
      );
}

class OfflineAttachment {
  const OfflineAttachment({
    required this.id,
    required this.messageId,
    required this.kind,
    required this.relativePath,
    required this.fileName,
    required this.sizeBytes,
    this.thumbnailRelativePath,
    this.mimeType,
    this.durationMs,
    this.width,
    this.height,
  });

  final String id;
  final String messageId;
  final String kind;
  final String relativePath;
  final String? thumbnailRelativePath;
  final String fileName;
  final String? mimeType;
  final int sizeBytes;
  final int? durationMs;
  final int? width;
  final int? height;

  factory OfflineAttachment.fromRow(Map<String, Object?> row) =>
      OfflineAttachment(
        id: row['id']! as String,
        messageId: row['message_id']! as String,
        kind: row['kind']! as String,
        relativePath: row['relative_path']! as String,
        thumbnailRelativePath: row['thumbnail_relative_path'] as String?,
        fileName: row['file_name']! as String,
        mimeType: row['mime_type'] as String?,
        sizeBytes: row['size_bytes']! as int,
        durationMs: row['duration_ms'] as int?,
        width: row['width'] as int?,
        height: row['height'] as int?,
      );
}

class OfflineNotification {
  const OfflineNotification({
    required this.id,
    required this.category,
    required this.title,
    required this.body,
    required this.occurredAt,
    required this.isRead,
    this.routeKey,
  });

  final String id;
  final String category;
  final String title;
  final String body;
  final DateTime occurredAt;
  final bool isRead;
  final String? routeKey;

  factory OfflineNotification.fromRow(Map<String, Object?> row) =>
      OfflineNotification(
        id: row['id']! as String,
        category: row['category']! as String,
        title: row['title']! as String,
        body: row['body']! as String,
        occurredAt: DateTime.parse(row['occurred_at']! as String),
        isRead: row['is_read'] == 1,
        routeKey: row['route_key'] as String?,
      );
}

class OfflineAnnouncement {
  const OfflineAnnouncement({
    required this.id,
    required this.title,
    required this.body,
    required this.authorName,
    required this.publishedAt,
    required this.isPinned,
    required this.status,
  });

  final String id;
  final String title;
  final String body;
  final String authorName;
  final DateTime publishedAt;
  final bool isPinned;
  final String status;

  factory OfflineAnnouncement.fromRow(Map<String, Object?> row) =>
      OfflineAnnouncement(
        id: row['id']! as String,
        title: row['title']! as String,
        body: row['body']! as String,
        authorName: row['author_name']! as String,
        publishedAt: DateTime.parse(row['published_at']! as String),
        isPinned: row['is_pinned'] == 1,
        status: row['status']! as String,
      );
}

class OfflineCallRecord {
  const OfflineCallRecord({
    required this.id,
    required this.peerName,
    required this.type,
    required this.direction,
    required this.startedAt,
    required this.durationSeconds,
    required this.status,
  });

  final String id;
  final String peerName;
  final String type;
  final String direction;
  final DateTime startedAt;
  final int durationSeconds;
  final String status;

  factory OfflineCallRecord.fromRow(Map<String, Object?> row) =>
      OfflineCallRecord(
        id: row['id']! as String,
        peerName: row['peer_name']! as String,
        type: row['type']! as String,
        direction: row['direction']! as String,
        startedAt: DateTime.parse(row['started_at']! as String),
        durationSeconds: row['duration_seconds']! as int,
        status: row['status']! as String,
      );
}
