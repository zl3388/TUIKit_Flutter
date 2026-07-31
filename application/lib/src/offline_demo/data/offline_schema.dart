import 'package:sqflite/sqflite.dart';

abstract final class OfflineSchema {
  static const version = 1;

  static const expectedTables = <String>[
    'profiles',
    'org_units',
    'contacts',
    'conversations',
    'conversation_members',
    'messages',
    'message_attachments',
    'notifications',
    'announcements',
    'call_records',
    'settings',
  ];

  static const createStatements = <String>[
    '''
CREATE TABLE profiles (
  id TEXT PRIMARY KEY,
  display_name TEXT NOT NULL,
  title TEXT NOT NULL DEFAULT '',
  department TEXT NOT NULL DEFAULT '',
  avatar_path TEXT,
  phone TEXT,
  email TEXT,
  status TEXT NOT NULL DEFAULT 'active',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
)
''',
    '''
CREATE TABLE org_units (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  parent_id TEXT REFERENCES org_units(id) ON DELETE CASCADE,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
)
''',
    '''
CREATE TABLE contacts (
  id TEXT PRIMARY KEY,
  profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  org_unit_id TEXT NOT NULL REFERENCES org_units(id) ON DELETE RESTRICT,
  alias TEXT,
  is_favorite INTEGER NOT NULL DEFAULT 0 CHECK (is_favorite IN (0, 1)),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(profile_id)
)
''',
    '''
CREATE TABLE conversations (
  id TEXT PRIMARY KEY,
  type TEXT NOT NULL CHECK (type IN ('direct', 'group', 'system')),
  title TEXT NOT NULL,
  avatar_path TEXT,
  last_message_preview TEXT NOT NULL DEFAULT '',
  last_message_at TEXT NOT NULL,
  unread_count INTEGER NOT NULL DEFAULT 0 CHECK (unread_count >= 0),
  is_pinned INTEGER NOT NULL DEFAULT 0 CHECK (is_pinned IN (0, 1)),
  is_muted INTEGER NOT NULL DEFAULT 0 CHECK (is_muted IN (0, 1)),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
)
''',
    '''
CREATE TABLE conversation_members (
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  role TEXT NOT NULL DEFAULT 'member',
  joined_at TEXT NOT NULL,
  PRIMARY KEY (conversation_id, profile_id)
)
''',
    '''
CREATE TABLE messages (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  sender_profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE RESTRICT,
  kind TEXT NOT NULL CHECK (kind IN ('text', 'image', 'video', 'audio', 'file', 'system')),
  text TEXT NOT NULL DEFAULT '',
  sent_at TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'sent',
  is_recalled INTEGER NOT NULL DEFAULT 0 CHECK (is_recalled IN (0, 1)),
  reply_to_message_id TEXT REFERENCES messages(id) ON DELETE SET NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
)
''',
    '''
CREATE TABLE message_attachments (
  id TEXT PRIMARY KEY,
  message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,
  relative_path TEXT NOT NULL,
  thumbnail_relative_path TEXT,
  file_name TEXT NOT NULL,
  mime_type TEXT,
  size_bytes INTEGER NOT NULL DEFAULT 0,
  duration_ms INTEGER,
  width INTEGER,
  height INTEGER,
  created_at TEXT NOT NULL
)
''',
    '''
CREATE TABLE notifications (
  id TEXT PRIMARY KEY,
  category TEXT NOT NULL,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  occurred_at TEXT NOT NULL,
  is_read INTEGER NOT NULL DEFAULT 0 CHECK (is_read IN (0, 1)),
  route_key TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
)
''',
    '''
CREATE TABLE announcements (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  author_profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE RESTRICT,
  published_at TEXT NOT NULL,
  is_pinned INTEGER NOT NULL DEFAULT 0 CHECK (is_pinned IN (0, 1)),
  status TEXT NOT NULL DEFAULT 'published',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
)
''',
    '''
CREATE TABLE call_records (
  id TEXT PRIMARY KEY,
  peer_profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE RESTRICT,
  type TEXT NOT NULL CHECK (type IN ('audio', 'video')),
  direction TEXT NOT NULL CHECK (direction IN ('incoming', 'outgoing')),
  started_at TEXT NOT NULL,
  duration_seconds INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
)
''',
    '''
CREATE TABLE settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TEXT NOT NULL
)
''',
    'CREATE INDEX idx_org_units_parent ON org_units(parent_id, sort_order)',
    'CREATE INDEX idx_contacts_org ON contacts(org_unit_id, is_favorite)',
    'CREATE INDEX idx_conversations_sort ON conversations(is_pinned DESC, last_message_at DESC)',
    'CREATE INDEX idx_messages_conversation ON messages(conversation_id, sent_at)',
    'CREATE INDEX idx_attachments_message ON message_attachments(message_id)',
    'CREATE INDEX idx_notifications_time ON notifications(occurred_at DESC)',
    'CREATE INDEX idx_announcements_time ON announcements(is_pinned DESC, published_at DESC)',
    'CREATE INDEX idx_calls_time ON call_records(started_at DESC)',
  ];

  static Future<void> createV1(Database db) async {
    final batch = db.batch();
    for (final statement in createStatements) {
      batch.execute(statement);
    }
    await batch.commit(noResult: true);
  }

  static Future<void> migrate(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 1 && newVersion >= 1) {
      await createV1(db);
    }
  }
}
