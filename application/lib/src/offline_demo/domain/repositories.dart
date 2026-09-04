import 'package:sqflite/sqflite.dart';

import '../data/offline_database.dart';
import 'models.dart';

abstract interface class IdentityRepository {
  bool get isAvailable;

  Future<OfflineProfile> currentProfile();
}

abstract interface class ContactRepository {
  bool get isAvailable;

  Future<List<OrgUnit>> listOrganizationUnits();

  Future<List<DirectoryContact>> listContacts({String? organizationUnitId});
}

enum ConversationFeature {
  members,
  messages,
  attachments,
  sendText,
  pin,
  mute,
  markRead,
  draft,
  delete,
}

abstract interface class ConversationRepository {
  bool get isAvailable;

  Set<ConversationFeature> get features;

  Future<List<OfflineConversation>> listConversations();

  Future<List<OfflineConversationMember>> listMembers(String conversationId);

  Future<List<OfflineMessage>> listMessages(String conversationId);

  Future<List<OfflineAttachment>> listAttachments(String messageId);

  Future<OfflineMessage> sendTextMessage({
    required String conversationId,
    required String senderProfileId,
    required String text,
    DateTime? sentAt,
  });

  Future<void> setPinned(String conversationId, bool isPinned);

  Future<void> setMuted(String conversationId, bool isMuted);

  Future<void> markRead(String conversationId);

  Future<void> saveDraft(String conversationId, String text);

  Future<void> deleteConversation(String conversationId);
}

abstract interface class ActivityRepository {
  bool get isAvailable;

  Future<List<OfflineNotification>> listNotifications();

  Future<List<OfflineAnnouncement>> listAnnouncements();

  Future<List<OfflineCallRecord>> listCallRecords();

  Future<void> markNotificationRead(String notificationId);
}

class OfflineRepositoryBundle {
  OfflineRepositoryBundle({
    IdentityRepository? identityRepository,
    ContactRepository? contactRepository,
    ConversationRepository? conversationRepository,
    ActivityRepository? activityRepository,
  })  : identity = identityRepository ?? const UnavailableIdentityRepository(),
        contacts = contactRepository ?? const UnavailableContactRepository(),
        conversations =
            conversationRepository ?? const UnavailableConversationRepository(),
        activity = activityRepository ?? const UnavailableActivityRepository();

  factory OfflineRepositoryBundle.fromLegacyDatabase(
    OfflineDatabase database, {
    IdentityRepository? identityRepository,
    ContactRepository? contactRepository,
    ConversationRepository? conversationRepository,
    ActivityRepository? activityRepository,
  }) {
    return OfflineRepositoryBundle(
      identityRepository:
          identityRepository ?? SqliteIdentityRepository(database.connection),
      contactRepository:
          contactRepository ?? SqliteContactRepository(database.connection),
      conversationRepository: conversationRepository ??
          SqliteConversationRepository(database.connection),
      activityRepository:
          activityRepository ?? SqliteActivityRepository(database.connection),
    );
  }

  final IdentityRepository identity;
  final ContactRepository contacts;
  final ConversationRepository conversations;
  final ActivityRepository activity;
}

class SqliteIdentityRepository implements IdentityRepository {
  const SqliteIdentityRepository(this._db);

  final Database _db;

  @override
  bool get isAvailable => true;

  @override
  Future<OfflineProfile> currentProfile() async {
    final rows = await _db.rawQuery('''
SELECT p.*
FROM profiles p
JOIN settings s ON s.value = p.id
WHERE s.key = 'current_profile_id'
LIMIT 1
''');
    if (rows.isEmpty) {
      throw StateError('The offline scenario has no current profile.');
    }
    return OfflineProfile.fromRow(rows.single);
  }
}

class UnavailableIdentityRepository implements IdentityRepository {
  const UnavailableIdentityRepository();

  @override
  bool get isAvailable => false;

  @override
  Future<OfflineProfile> currentProfile() {
    throw StateError('No active WeCom identity has been selected.');
  }
}

class SqliteContactRepository implements ContactRepository {
  const SqliteContactRepository(this._db);

  final Database _db;

  @override
  bool get isAvailable => true;

  @override
  Future<List<OrgUnit>> listOrganizationUnits() async {
    final rows = await _db.query(
      'org_units',
      orderBy: 'sort_order ASC, id ASC',
    );
    return rows.map(OrgUnit.fromRow).toList(growable: false);
  }

  @override
  Future<List<DirectoryContact>> listContacts({
    String? organizationUnitId,
  }) async {
    final rows = await _db.rawQuery('''
SELECT
  c.id AS contact_id,
  p.display_name,
  NULL AS account,
  ou.name AS organization_name,
  p.title AS job_title
FROM contacts c
JOIN profiles p ON p.id = c.profile_id
JOIN org_units ou ON ou.id = c.org_unit_id
WHERE p.id != (
  SELECT value FROM settings WHERE key = 'current_profile_id' LIMIT 1
)
${organizationUnitId == null ? '' : 'AND ou.id = ?'}
ORDER BY ou.sort_order ASC, p.display_name COLLATE NOCASE ASC
''', organizationUnitId == null ? null : [organizationUnitId]);
    return rows.map(DirectoryContact.fromRow).toList(growable: false);
  }
}

class UnavailableContactRepository implements ContactRepository {
  const UnavailableContactRepository();

  @override
  bool get isAvailable => false;

  @override
  Future<List<OrgUnit>> listOrganizationUnits() async => const [];

  @override
  Future<List<DirectoryContact>> listContacts({
    String? organizationUnitId,
  }) async =>
      const [];
}

class SqliteConversationRepository implements ConversationRepository {
  SqliteConversationRepository(this._db);

  final Database _db;
  var _messageSequence = 0;

  @override
  bool get isAvailable => true;

  @override
  Set<ConversationFeature> get features => const {
        ConversationFeature.members,
        ConversationFeature.messages,
        ConversationFeature.attachments,
        ConversationFeature.sendText,
        ConversationFeature.pin,
        ConversationFeature.mute,
        ConversationFeature.markRead,
        ConversationFeature.draft,
        ConversationFeature.delete,
      };

  @override
  Future<List<OfflineConversation>> listConversations() async {
    final rows = await _db.query(
      'conversations',
      orderBy: 'is_pinned DESC, last_message_at DESC',
    );
    return rows.map(OfflineConversation.fromRow).toList(growable: false);
  }

  @override
  Future<List<OfflineConversationMember>> listMembers(
    String conversationId,
  ) async {
    final rows = await _db.rawQuery(
      '''
SELECT cm.conversation_id, cm.profile_id, cm.role, cm.joined_at,
       p.display_name
FROM conversation_members cm
JOIN profiles p ON p.id = cm.profile_id
WHERE cm.conversation_id = ?
ORDER BY cm.profile_id
''',
      [conversationId],
    );
    return rows
        .map(
          (row) => OfflineConversationMember(
            conversationId: row['conversation_id']! as String,
            userId: row['profile_id']! as String,
            displayName: row['display_name']! as String,
            nickname: null,
            isAdmin: row['role'] == 'admin',
            gagType: 0,
            joinedAt: DateTime.parse(row['joined_at']! as String),
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<List<OfflineMessage>> listMessages(String conversationId) async {
    final rows = await _db.rawQuery(
      '''
SELECT m.*, p.display_name AS sender_name
FROM messages m
JOIN profiles p ON p.id = m.sender_profile_id
WHERE m.conversation_id = ?
ORDER BY m.sent_at ASC, m.id ASC
''',
      [conversationId],
    );
    return rows.map(OfflineMessage.fromRow).toList(growable: false);
  }

  @override
  Future<List<OfflineAttachment>> listAttachments(String messageId) async {
    final rows = await _db.query(
      'message_attachments',
      where: 'message_id = ?',
      whereArgs: [messageId],
      orderBy: 'created_at ASC, id ASC',
    );
    return rows.map(OfflineAttachment.fromRow).toList(growable: false);
  }

  @override
  Future<OfflineMessage> sendTextMessage({
    required String conversationId,
    required String senderProfileId,
    required String text,
    DateTime? sentAt,
  }) async {
    final body = text.trim();
    if (body.isEmpty) {
      throw ArgumentError.value(text, 'text', 'Message text cannot be empty.');
    }

    final timestamp = (sentAt ?? DateTime.now()).toUtc();
    final timestampValue = timestamp.toIso8601String();
    final messageId =
        'message_local_${timestamp.microsecondsSinceEpoch}_${_messageSequence++}';
    final preview = body.length > 80 ? '${body.substring(0, 80)}…' : body;

    return _db.transaction((txn) async {
      await txn.insert('messages', {
        'id': messageId,
        'conversation_id': conversationId,
        'sender_profile_id': senderProfileId,
        'kind': 'text',
        'text': body,
        'sent_at': timestampValue,
        'status': 'sent',
        'is_recalled': 0,
        'created_at': timestampValue,
        'updated_at': timestampValue,
      });

      final updated = await txn.update(
        'conversations',
        {
          'last_message_preview': preview,
          'last_message_at': timestampValue,
          'draft_text': '',
          'updated_at': timestampValue,
        },
        where: 'id = ?',
        whereArgs: [conversationId],
      );
      if (updated != 1) {
        throw StateError('Conversation $conversationId does not exist.');
      }

      final rows = await txn.rawQuery(
        '''
SELECT m.*, p.display_name AS sender_name
FROM messages m
JOIN profiles p ON p.id = m.sender_profile_id
WHERE m.id = ?
LIMIT 1
''',
        [messageId],
      );
      return OfflineMessage.fromRow(rows.single);
    });
  }

  @override
  Future<void> setPinned(String conversationId, bool isPinned) {
    return _updateConversation(
      conversationId,
      {'is_pinned': isPinned ? 1 : 0},
    );
  }

  @override
  Future<void> setMuted(String conversationId, bool isMuted) {
    return _updateConversation(
      conversationId,
      {'is_muted': isMuted ? 1 : 0},
    );
  }

  @override
  Future<void> markRead(String conversationId) {
    return _updateConversation(conversationId, {'unread_count': 0});
  }

  @override
  Future<void> saveDraft(String conversationId, String text) {
    return _updateConversation(conversationId, {'draft_text': text});
  }

  @override
  Future<void> deleteConversation(String conversationId) async {
    final deleted = await _db.delete(
      'conversations',
      where: 'id = ?',
      whereArgs: [conversationId],
    );
    if (deleted != 1) {
      throw StateError('Conversation $conversationId does not exist.');
    }
  }

  Future<void> _updateConversation(
    String conversationId,
    Map<String, Object?> values,
  ) async {
    final updated = await _db.update(
      'conversations',
      {
        ...values,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [conversationId],
    );
    if (updated != 1) {
      throw StateError('Conversation $conversationId does not exist.');
    }
  }
}

class UnavailableConversationRepository implements ConversationRepository {
  const UnavailableConversationRepository();

  @override
  bool get isAvailable => false;

  @override
  Set<ConversationFeature> get features => const {};

  @override
  Future<List<OfflineConversation>> listConversations() async => const [];

  @override
  Future<List<OfflineConversationMember>> listMembers(String conversationId) {
    return _unavailable();
  }

  @override
  Future<List<OfflineMessage>> listMessages(String conversationId) {
    return _unavailable();
  }

  @override
  Future<List<OfflineAttachment>> listAttachments(String messageId) {
    return _unavailable();
  }

  @override
  Future<OfflineMessage> sendTextMessage({
    required String conversationId,
    required String senderProfileId,
    required String text,
    DateTime? sentAt,
  }) {
    return _unavailable();
  }

  @override
  Future<void> setPinned(String conversationId, bool isPinned) {
    return _unavailable();
  }

  @override
  Future<void> setMuted(String conversationId, bool isMuted) {
    return _unavailable();
  }

  @override
  Future<void> markRead(String conversationId) => _unavailable();

  @override
  Future<void> saveDraft(String conversationId, String text) => _unavailable();

  @override
  Future<void> deleteConversation(String conversationId) => _unavailable();

  Future<T> _unavailable<T>() {
    return Future<T>.error(
      StateError('No active WeCom conversation dataset is available.'),
    );
  }
}

class SqliteActivityRepository implements ActivityRepository {
  const SqliteActivityRepository(this._db);

  final Database _db;

  @override
  bool get isAvailable => true;

  @override
  Future<List<OfflineNotification>> listNotifications() async {
    final rows = await _db.query(
      'notifications',
      orderBy: 'occurred_at DESC',
    );
    return rows.map(OfflineNotification.fromRow).toList(growable: false);
  }

  @override
  Future<List<OfflineAnnouncement>> listAnnouncements() async {
    final rows = await _db.rawQuery('''
SELECT a.*, p.display_name AS author_name
FROM announcements a
JOIN profiles p ON p.id = a.author_profile_id
ORDER BY a.is_pinned DESC, a.published_at DESC
''');
    return rows.map(OfflineAnnouncement.fromRow).toList(growable: false);
  }

  @override
  Future<List<OfflineCallRecord>> listCallRecords() async {
    final rows = await _db.rawQuery('''
SELECT c.*, p.display_name AS peer_name
FROM call_records c
JOIN profiles p ON p.id = c.peer_profile_id
ORDER BY c.started_at DESC
''');
    return rows.map(OfflineCallRecord.fromRow).toList(growable: false);
  }

  @override
  Future<void> markNotificationRead(String notificationId) async {
    await _db.update(
      'notifications',
      {
        'is_read': 1,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [notificationId],
    );
  }
}

class UnavailableActivityRepository implements ActivityRepository {
  const UnavailableActivityRepository();

  @override
  bool get isAvailable => false;

  @override
  Future<List<OfflineNotification>> listNotifications() async => const [];

  @override
  Future<List<OfflineAnnouncement>> listAnnouncements() async => const [];

  @override
  Future<List<OfflineCallRecord>> listCallRecords() async => const [];

  @override
  Future<void> markNotificationRead(String notificationId) {
    return Future<void>.error(
      StateError('No active WeCom activity dataset is available.'),
    );
  }
}
