class WeComConversationSummary {
  const WeComConversationSummary({
    required this.numericId,
    required this.id,
    required this.displayName,
    required this.name,
    required this.roomNameRemark,
    required this.lastMessageTime,
    required this.lastMessageId,
    required this.pinnedFlag,
    required this.blockedFlag,
    required this.status,
    required this.foldStatus,
    required this.unreadState,
  });

  final int numericId;
  final String id;
  final String displayName;
  final String name;
  final String? roomNameRemark;
  final int? lastMessageTime;
  final int? lastMessageId;
  final int pinnedFlag;
  final int blockedFlag;
  final int status;
  final int? foldStatus;
  final WeComConversationUnreadState? unreadState;

  factory WeComConversationSummary.fromRow(Map<String, Object?> row) {
    final unreadConversationId = row['unread_conversation_id'];
    return WeComConversationSummary(
      numericId: row['con_numeric_id']! as int,
      id: row['id']! as String,
      displayName: row['display_name']! as String,
      name: row['name']! as String,
      roomNameRemark: row['roomname_remark'] as String?,
      lastMessageTime: row['last_message_time'] as int?,
      lastMessageId: row['last_message_id'] as int?,
      pinnedFlag: row['is_sticked']! as int,
      blockedFlag: row['is_blocked']! as int,
      status: row['status']! as int,
      foldStatus: row['fold_status'] as int?,
      unreadState: unreadConversationId == null
          ? null
          : WeComConversationUnreadState(
              conversationId: unreadConversationId as String,
              beginCursor: row['unread_begin_cursor']! as int,
              currentCursor: row['unread_current_cursor']! as int,
              unreadCount: row['unread_count']! as int,
            ),
    );
  }

  factory WeComConversationSummary.fromFields({
    required int numericId,
    required String id,
    required String name,
    required String? roomNameRemark,
    required int? lastMessageTime,
    required int? lastMessageId,
    required int pinnedFlag,
    required int blockedFlag,
    required int status,
    required int? foldStatus,
    required WeComConversationUnreadState? unreadState,
  }) {
    return WeComConversationSummary(
      numericId: numericId,
      id: id,
      displayName: _firstNonEmpty([roomNameRemark, name]),
      name: name,
      roomNameRemark: roomNameRemark,
      lastMessageTime: lastMessageTime,
      lastMessageId: lastMessageId,
      pinnedFlag: pinnedFlag,
      blockedFlag: blockedFlag,
      status: status,
      foldStatus: foldStatus,
      unreadState: unreadState,
    );
  }

  static String _firstNonEmpty(Iterable<String?> values) {
    for (final value in values) {
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
    return '';
  }
}

class WeComConversationUnreadState {
  const WeComConversationUnreadState({
    required this.conversationId,
    required this.beginCursor,
    required this.currentCursor,
    required this.unreadCount,
  });

  final String conversationId;
  final int beginCursor;
  final int currentCursor;
  final int unreadCount;
}

class WeComConversationMember {
  const WeComConversationMember({
    required this.conversationId,
    required this.userId,
    required this.joinTime,
    required this.gagType,
    required this.nickname,
    required this.adminFlag,
  });

  final String conversationId;
  final int userId;
  final int joinTime;
  final int gagType;
  final String? nickname;
  final int? adminFlag;

  factory WeComConversationMember.fromRow(Map<String, Object?> row) {
    return WeComConversationMember(
      conversationId: row['conversation_id']! as String,
      userId: row['user_id']! as int,
      joinTime: row['join_time']! as int,
      gagType: row['gag_type']! as int,
      nickname: row['nick_name'] as String?,
      adminFlag: row['is_admin'] as int?,
    );
  }
}
