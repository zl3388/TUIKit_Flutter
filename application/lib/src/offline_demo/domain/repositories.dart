import 'package:sqflite/sqflite.dart';

import '../data/offline_database.dart';
import 'models.dart';

abstract interface class IdentityRepository {
  Future<OfflineProfile> currentProfile();
}

abstract interface class ContactRepository {
  Future<List<OfflineContact>> listContacts();
}

abstract interface class ConversationRepository {
  Future<List<OfflineConversation>> listConversations();

  Future<List<OfflineMessage>> listMessages(String conversationId);

  Future<List<OfflineAttachment>> listAttachments(String messageId);
}

abstract interface class ActivityRepository {
  Future<List<OfflineNotification>> listNotifications();

  Future<List<OfflineAnnouncement>> listAnnouncements();

  Future<List<OfflineCallRecord>> listCallRecords();

  Future<void> markNotificationRead(String notificationId);
}

abstract interface class SettingsRepository {
  Future<String?> read(String key);
}

class OfflineRepositoryBundle {
  OfflineRepositoryBundle(OfflineDatabase database)
      : identity = SqliteIdentityRepository(database.connection),
        contacts = SqliteContactRepository(database.connection),
        conversations = SqliteConversationRepository(database.connection),
        activity = SqliteActivityRepository(database.connection),
        settings = SqliteSettingsRepository(database.connection);

  final IdentityRepository identity;
  final ContactRepository contacts;
  final ConversationRepository conversations;
  final ActivityRepository activity;
  final SettingsRepository settings;
}

class SqliteIdentityRepository implements IdentityRepository {
  const SqliteIdentityRepository(this._db);

  final Database _db;

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

class SqliteContactRepository implements ContactRepository {
  const SqliteContactRepository(this._db);

  final Database _db;

  @override
  Future<List<OfflineContact>> listContacts() async {
    final rows = await _db.rawQuery('''
SELECT
  c.id AS contact_id,
  c.alias,
  c.is_favorite,
  p.*,
  ou.name AS org_unit_name
FROM contacts c
JOIN profiles p ON p.id = c.profile_id
JOIN org_units ou ON ou.id = c.org_unit_id
WHERE p.id != (
  SELECT value FROM settings WHERE key = 'current_profile_id' LIMIT 1
)
ORDER BY c.is_favorite DESC, ou.sort_order ASC, p.display_name COLLATE NOCASE ASC
''');
    return rows.map(OfflineContact.fromRow).toList(growable: false);
  }
}

class SqliteConversationRepository implements ConversationRepository {
  const SqliteConversationRepository(this._db);

  final Database _db;

  @override
  Future<List<OfflineConversation>> listConversations() async {
    final rows = await _db.query(
      'conversations',
      orderBy: 'is_pinned DESC, last_message_at DESC',
    );
    return rows.map(OfflineConversation.fromRow).toList(growable: false);
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
}

class SqliteActivityRepository implements ActivityRepository {
  const SqliteActivityRepository(this._db);

  final Database _db;

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

class SqliteSettingsRepository implements SettingsRepository {
  const SqliteSettingsRepository(this._db);

  final Database _db;

  @override
  Future<String?> read(String key) async {
    final rows = await _db.query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['value'] as String;
  }
}
