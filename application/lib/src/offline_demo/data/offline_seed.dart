import 'package:sqflite/sqflite.dart';

abstract final class OfflineSeed {
  static const version = '1';
  static const scenarioName = '协作团队基础场景';
  static const _createdAt = '2026-07-30T00:00:00.000Z';

  static Future<void> ensureSeeded(Database db) async {
    final existing = await db.query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['seed_version'],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      return;
    }

    await db.transaction((txn) async {
      final recheck = await txn.query(
        'settings',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: ['seed_version'],
        limit: 1,
      );
      if (recheck.isNotEmpty) {
        return;
      }

      final batch = txn.batch();
      for (final row in _profiles) {
        batch.insert('profiles', row);
      }
      for (final row in _orgUnits) {
        batch.insert('org_units', row);
      }
      for (final row in _contacts) {
        batch.insert('contacts', row);
      }
      for (final row in _conversations) {
        batch.insert('conversations', row);
      }
      for (final row in _members) {
        batch.insert('conversation_members', row);
      }
      for (final row in _messages) {
        batch.insert('messages', row);
      }
      for (final row in _notifications) {
        batch.insert('notifications', row);
      }
      for (final row in _announcements) {
        batch.insert('announcements', row);
      }
      for (final row in _callRecords) {
        batch.insert('call_records', row);
      }
      for (final row in _settings) {
        batch.insert('settings', row);
      }
      await batch.commit(noResult: true);
    });
  }

  static const _profiles = <Map<String, Object?>>[
    {
      'id': 'profile_current',
      'display_name': '林墨',
      'title': '产品负责人',
      'department': '产品中心',
      'phone': '138 0000 2101',
      'email': 'lin.mo@example.local',
      'status': 'active',
      'created_at': _createdAt,
      'updated_at': _createdAt,
    },
    {
      'id': 'profile_chen',
      'display_name': '陈一凡',
      'title': 'Android 工程师',
      'department': '研发中心',
      'phone': '138 0000 2102',
      'email': 'chen.yifan@example.local',
      'status': 'active',
      'created_at': _createdAt,
      'updated_at': _createdAt,
    },
    {
      'id': 'profile_luo',
      'display_name': '罗晴',
      'title': '体验设计师',
      'department': '设计中心',
      'phone': '138 0000 2103',
      'email': 'luo.qing@example.local',
      'status': 'active',
      'created_at': _createdAt,
      'updated_at': _createdAt,
    },
    {
      'id': 'profile_wang',
      'display_name': '王泽',
      'title': '市场经理',
      'department': '市场中心',
      'phone': '138 0000 2104',
      'email': 'wang.ze@example.local',
      'status': 'busy',
      'created_at': _createdAt,
      'updated_at': _createdAt,
    },
    {
      'id': 'profile_assistant',
      'display_name': '离线助手',
      'title': '系统服务',
      'department': '协作平台',
      'email': 'assistant@example.local',
      'status': 'active',
      'created_at': _createdAt,
      'updated_at': _createdAt,
    },
  ];

  static const _orgUnits = <Map<String, Object?>>[
    {
      'id': 'org_company',
      'name': '示例科技',
      'sort_order': 0,
      'created_at': _createdAt,
      'updated_at': _createdAt,
    },
    {
      'id': 'org_product',
      'name': '产品中心',
      'parent_id': 'org_company',
      'sort_order': 10,
      'created_at': _createdAt,
      'updated_at': _createdAt,
    },
    {
      'id': 'org_engineering',
      'name': '研发中心',
      'parent_id': 'org_company',
      'sort_order': 20,
      'created_at': _createdAt,
      'updated_at': _createdAt,
    },
    {
      'id': 'org_design',
      'name': '设计中心',
      'parent_id': 'org_company',
      'sort_order': 30,
      'created_at': _createdAt,
      'updated_at': _createdAt,
    },
    {
      'id': 'org_market',
      'name': '市场中心',
      'parent_id': 'org_company',
      'sort_order': 40,
      'created_at': _createdAt,
      'updated_at': _createdAt,
    },
    {
      'id': 'org_platform',
      'name': '协作平台',
      'parent_id': 'org_company',
      'sort_order': 50,
      'created_at': _createdAt,
      'updated_at': _createdAt,
    },
  ];

  static const _contacts = <Map<String, Object?>>[
    {
      'id': 'contact_current',
      'profile_id': 'profile_current',
      'org_unit_id': 'org_product',
      'is_favorite': 0,
      'created_at': _createdAt,
      'updated_at': _createdAt,
    },
    {
      'id': 'contact_chen',
      'profile_id': 'profile_chen',
      'org_unit_id': 'org_engineering',
      'is_favorite': 1,
      'created_at': _createdAt,
      'updated_at': _createdAt,
    },
    {
      'id': 'contact_luo',
      'profile_id': 'profile_luo',
      'org_unit_id': 'org_design',
      'is_favorite': 1,
      'created_at': _createdAt,
      'updated_at': _createdAt,
    },
    {
      'id': 'contact_wang',
      'profile_id': 'profile_wang',
      'org_unit_id': 'org_market',
      'is_favorite': 0,
      'created_at': _createdAt,
      'updated_at': _createdAt,
    },
    {
      'id': 'contact_assistant',
      'profile_id': 'profile_assistant',
      'org_unit_id': 'org_platform',
      'is_favorite': 0,
      'created_at': _createdAt,
      'updated_at': _createdAt,
    },
  ];

  static const _conversations = <Map<String, Object?>>[
    {
      'id': 'conversation_product',
      'type': 'group',
      'title': '产品项目组',
      'last_message_preview': '罗晴：新版本原型已更新，请查收。',
      'last_message_at': '2026-07-30T10:18:00.000Z',
      'unread_count': 3,
      'is_pinned': 0,
      'is_muted': 0,
      'created_at': _createdAt,
      'updated_at': '2026-07-30T10:18:00.000Z',
    },
    {
      'id': 'conversation_chen',
      'type': 'direct',
      'title': '陈一凡',
      'last_message_preview': '离线数据库迁移测试已经通过。',
      'last_message_at': '2026-07-30T09:42:00.000Z',
      'unread_count': 0,
      'is_pinned': 1,
      'is_muted': 0,
      'created_at': _createdAt,
      'updated_at': '2026-07-30T09:42:00.000Z',
    },
    {
      'id': 'conversation_company',
      'type': 'system',
      'title': '全员公告',
      'last_message_preview': '本周五 16:00 举行季度分享会。',
      'last_message_at': '2026-07-30T08:30:00.000Z',
      'unread_count': 1,
      'is_pinned': 0,
      'is_muted': 1,
      'created_at': _createdAt,
      'updated_at': '2026-07-30T08:30:00.000Z',
    },
    {
      'id': 'conversation_assistant',
      'type': 'direct',
      'title': '离线助手',
      'last_message_preview': '本地场景已准备完成。',
      'last_message_at': '2026-07-30T07:10:00.000Z',
      'unread_count': 0,
      'is_pinned': 0,
      'is_muted': 0,
      'created_at': _createdAt,
      'updated_at': '2026-07-30T07:10:00.000Z',
    },
  ];

  static const _members = <Map<String, Object?>>[
    {
      'conversation_id': 'conversation_product',
      'profile_id': 'profile_current',
      'role': 'owner',
      'joined_at': _createdAt,
    },
    {
      'conversation_id': 'conversation_product',
      'profile_id': 'profile_chen',
      'role': 'member',
      'joined_at': _createdAt,
    },
    {
      'conversation_id': 'conversation_product',
      'profile_id': 'profile_luo',
      'role': 'member',
      'joined_at': _createdAt,
    },
    {
      'conversation_id': 'conversation_product',
      'profile_id': 'profile_wang',
      'role': 'member',
      'joined_at': _createdAt,
    },
    {
      'conversation_id': 'conversation_chen',
      'profile_id': 'profile_current',
      'role': 'member',
      'joined_at': _createdAt,
    },
    {
      'conversation_id': 'conversation_chen',
      'profile_id': 'profile_chen',
      'role': 'member',
      'joined_at': _createdAt,
    },
    {
      'conversation_id': 'conversation_company',
      'profile_id': 'profile_current',
      'role': 'member',
      'joined_at': _createdAt,
    },
    {
      'conversation_id': 'conversation_company',
      'profile_id': 'profile_assistant',
      'role': 'owner',
      'joined_at': _createdAt,
    },
    {
      'conversation_id': 'conversation_assistant',
      'profile_id': 'profile_current',
      'role': 'member',
      'joined_at': _createdAt,
    },
    {
      'conversation_id': 'conversation_assistant',
      'profile_id': 'profile_assistant',
      'role': 'member',
      'joined_at': _createdAt,
    },
  ];

  static const _messages = <Map<String, Object?>>[
    {
      'id': 'message_001',
      'conversation_id': 'conversation_product',
      'sender_profile_id': 'profile_current',
      'kind': 'text',
      'text': '今天先确认离线演示的核心流程。',
      'sent_at': '2026-07-30T09:55:00.000Z',
      'status': 'read',
      'is_recalled': 0,
      'created_at': '2026-07-30T09:55:00.000Z',
      'updated_at': '2026-07-30T09:55:00.000Z',
    },
    {
      'id': 'message_002',
      'conversation_id': 'conversation_product',
      'sender_profile_id': 'profile_chen',
      'kind': 'text',
      'text': '数据库、附件目录和模拟器会保持完全本地。',
      'sent_at': '2026-07-30T10:02:00.000Z',
      'status': 'read',
      'is_recalled': 0,
      'created_at': '2026-07-30T10:02:00.000Z',
      'updated_at': '2026-07-30T10:02:00.000Z',
    },
    {
      'id': 'message_003',
      'conversation_id': 'conversation_product',
      'sender_profile_id': 'profile_luo',
      'kind': 'text',
      'text': '新版本原型已更新，请查收。',
      'sent_at': '2026-07-30T10:18:00.000Z',
      'status': 'delivered',
      'is_recalled': 0,
      'created_at': '2026-07-30T10:18:00.000Z',
      'updated_at': '2026-07-30T10:18:00.000Z',
    },
    {
      'id': 'message_004',
      'conversation_id': 'conversation_chen',
      'sender_profile_id': 'profile_current',
      'kind': 'text',
      'text': '重启后自定义数据能保留吗？',
      'sent_at': '2026-07-30T09:37:00.000Z',
      'status': 'read',
      'is_recalled': 0,
      'created_at': '2026-07-30T09:37:00.000Z',
      'updated_at': '2026-07-30T09:37:00.000Z',
    },
    {
      'id': 'message_005',
      'conversation_id': 'conversation_chen',
      'sender_profile_id': 'profile_chen',
      'kind': 'text',
      'text': '可以，离线数据库迁移测试已经通过。',
      'sent_at': '2026-07-30T09:42:00.000Z',
      'status': 'read',
      'is_recalled': 0,
      'created_at': '2026-07-30T09:42:00.000Z',
      'updated_at': '2026-07-30T09:42:00.000Z',
    },
    {
      'id': 'message_006',
      'conversation_id': 'conversation_company',
      'sender_profile_id': 'profile_assistant',
      'kind': 'system',
      'text': '本周五 16:00 举行季度分享会。',
      'sent_at': '2026-07-30T08:30:00.000Z',
      'status': 'delivered',
      'is_recalled': 0,
      'created_at': '2026-07-30T08:30:00.000Z',
      'updated_at': '2026-07-30T08:30:00.000Z',
    },
    {
      'id': 'message_007',
      'conversation_id': 'conversation_assistant',
      'sender_profile_id': 'profile_assistant',
      'kind': 'text',
      'text': '欢迎回来，本地场景已准备完成。',
      'sent_at': '2026-07-30T07:10:00.000Z',
      'status': 'read',
      'is_recalled': 0,
      'created_at': '2026-07-30T07:10:00.000Z',
      'updated_at': '2026-07-30T07:10:00.000Z',
    },
  ];

  static const _notifications = <Map<String, Object?>>[
    {
      'id': 'notification_001',
      'category': 'task',
      'title': '需求评审待确认',
      'body': '移动端离线体验需求将在今天 15:00 评审。',
      'occurred_at': '2026-07-30T08:10:00.000Z',
      'is_read': 0,
      'route_key': 'conversation_product',
      'created_at': '2026-07-30T08:10:00.000Z',
      'updated_at': '2026-07-30T08:10:00.000Z',
    },
    {
      'id': 'notification_002',
      'category': 'calendar',
      'title': '会议提醒',
      'body': '季度分享会将在周五 16:00 开始。',
      'occurred_at': '2026-07-30T07:30:00.000Z',
      'is_read': 0,
      'route_key': 'announcement_001',
      'created_at': '2026-07-30T07:30:00.000Z',
      'updated_at': '2026-07-30T07:30:00.000Z',
    },
    {
      'id': 'notification_003',
      'category': 'system',
      'title': '本地场景已更新',
      'body': '基础联系人、会话和公告数据已载入。',
      'occurred_at': '2026-07-30T06:50:00.000Z',
      'is_read': 1,
      'created_at': '2026-07-30T06:50:00.000Z',
      'updated_at': '2026-07-30T06:50:00.000Z',
    },
  ];

  static const _announcements = <Map<String, Object?>>[
    {
      'id': 'announcement_001',
      'title': '季度分享会安排',
      'body': '本周五 16:00 在一号会议室举行季度分享会，请提前十分钟到场。',
      'author_profile_id': 'profile_current',
      'published_at': '2026-07-30T08:30:00.000Z',
      'is_pinned': 1,
      'status': 'published',
      'created_at': '2026-07-30T08:30:00.000Z',
      'updated_at': '2026-07-30T08:30:00.000Z',
    },
    {
      'id': 'announcement_002',
      'title': '办公区网络维护',
      'body': '周六凌晨将进行网络维护，离线演示环境不受影响。',
      'author_profile_id': 'profile_assistant',
      'published_at': '2026-07-29T03:20:00.000Z',
      'is_pinned': 0,
      'status': 'published',
      'created_at': '2026-07-29T03:20:00.000Z',
      'updated_at': '2026-07-29T03:20:00.000Z',
    },
  ];

  static const _callRecords = <Map<String, Object?>>[
    {
      'id': 'call_001',
      'peer_profile_id': 'profile_chen',
      'type': 'audio',
      'direction': 'outgoing',
      'started_at': '2026-07-30T05:15:00.000Z',
      'duration_seconds': 386,
      'status': 'completed',
      'created_at': '2026-07-30T05:15:00.000Z',
      'updated_at': '2026-07-30T05:21:26.000Z',
    },
    {
      'id': 'call_002',
      'peer_profile_id': 'profile_luo',
      'type': 'video',
      'direction': 'incoming',
      'started_at': '2026-07-29T09:40:00.000Z',
      'duration_seconds': 0,
      'status': 'missed',
      'created_at': '2026-07-29T09:40:00.000Z',
      'updated_at': '2026-07-29T09:40:00.000Z',
    },
  ];

  static const _settings = <Map<String, Object?>>[
    {
      'key': 'seed_version',
      'value': version,
      'updated_at': _createdAt,
    },
    {
      'key': 'scenario_name',
      'value': scenarioName,
      'updated_at': _createdAt,
    },
    {
      'key': 'current_profile_id',
      'value': 'profile_current',
      'updated_at': _createdAt,
    },
    {
      'key': 'app_mode',
      'value': 'user',
      'updated_at': _createdAt,
    },
  ];
}
