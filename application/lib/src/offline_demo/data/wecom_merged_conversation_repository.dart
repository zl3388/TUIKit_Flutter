import 'dart:convert';

import '../domain/wecom_conversation_models.dart';
import 'wecom_conversation_repository.dart';
import 'wecom_overlay_database.dart';
import 'wecom_overlay_schema.dart';

class WeComMergedConversationRepository {
  const WeComMergedConversationRepository({
    required this.datasetId,
    required WeComConversationRepository baseRepository,
    required WeComOverlayDatabase overlayDatabase,
  })  : _baseRepository = baseRepository,
        _overlayDatabase = overlayDatabase;

  static const _databaseName = 'session.db';
  static const _conversationTable = 'conversation_table';
  static const _unreadTable = 'unread_conversation_table';
  static const _memberTable = 'conversation_user_table';

  final String datasetId;
  final WeComConversationRepository _baseRepository;
  final WeComOverlayDatabase _overlayDatabase;

  Future<List<WeComConversationSummary>> listConversations({
    int limit = WeComConversationRepository.maxPageSize,
    int offset = 0,
  }) async {
    _validatePagination(limit, offset);

    final baseConversations = await _readAllBaseConversations();
    final baseByNumericId = <int, WeComConversationSummary>{
      for (final conversation in baseConversations)
        conversation.numericId: conversation,
    };
    final visibleConversations = <int, _ConversationState>{
      for (final conversation in baseConversations)
        conversation.numericId: _ConversationState.fromSummary(conversation),
    };
    for (final operation in await _readOperations(_conversationTable)) {
      final rowKey = _decodeObject(
        operation['row_key_json']! as String,
        'row_key_json',
      );
      final numericId = rowKey['con_numeric_id'];
      if (rowKey.length != 1 || numericId is! int) {
        throw const FormatException(
          'Invalid conversation_table overlay row key',
        );
      }
      switch (operation['operation']) {
        case 'tombstone':
          visibleConversations.remove(numericId);
        case 'upsert':
          final state = visibleConversations[numericId] ??
              (baseByNumericId[numericId] == null
                  ? _ConversationState.empty(numericId)
                  : _ConversationState.fromSummary(
                      baseByNumericId[numericId]!,
                    ));
          state.apply(_decodeValues(operation));
          visibleConversations[numericId] = state;
        default:
          throw FormatException(
            'Unsupported overlay operation: ${operation['operation']}',
          );
      }
    }

    final baseUnreadById = <String, WeComConversationUnreadState>{
      for (final conversation in baseConversations)
        if (conversation.unreadState != null)
          conversation.unreadState!.conversationId: conversation.unreadState!,
    };
    final visibleUnread = <String, _UnreadState>{
      for (final entry in baseUnreadById.entries)
        entry.key: _UnreadState.fromModel(entry.value),
    };
    for (final operation in await _readOperations(_unreadTable)) {
      final rowKey = _decodeObject(
        operation['row_key_json']! as String,
        'row_key_json',
      );
      final conversationId = rowKey['conversation_id'];
      if (rowKey.length != 1 || conversationId is! String) {
        throw const FormatException(
          'Invalid unread_conversation_table overlay row key',
        );
      }
      switch (operation['operation']) {
        case 'tombstone':
          visibleUnread.remove(conversationId);
        case 'upsert':
          final state = visibleUnread[conversationId] ??
              (baseUnreadById[conversationId] == null
                  ? _UnreadState.empty(conversationId)
                  : _UnreadState.fromModel(baseUnreadById[conversationId]!));
          state.apply(_decodeValues(operation));
          visibleUnread[conversationId] = state;
        default:
          throw FormatException(
            'Unsupported overlay operation: ${operation['operation']}',
          );
      }
    }

    final seenIds = <String>{};
    final conversations = <WeComConversationSummary>[];
    for (final state in visibleConversations.values) {
      if (!seenIds.add(state.id)) {
        throw StateError(
          'Duplicate conversation id after overlay projection: ${state.id}',
        );
      }
      conversations.add(
        state.toSummary(visibleUnread[state.id]?.toModel()),
      );
    }
    conversations.sort(_compareConversations);
    if (offset >= conversations.length) {
      return const [];
    }
    final requestedEnd = offset + limit;
    final end = requestedEnd < conversations.length
        ? requestedEnd
        : conversations.length;
    return List<WeComConversationSummary>.unmodifiable(
      conversations.sublist(offset, end),
    );
  }

  Future<List<WeComConversationMember>> listConversationMembers(
    String conversationId,
  ) async {
    final baseMembers =
        await _baseRepository.listConversationMembers(conversationId);
    final baseByUserId = <int, WeComConversationMember>{
      for (final member in baseMembers) member.userId: member,
    };
    final visible = <int, _MemberState>{
      for (final member in baseMembers)
        member.userId: _MemberState.fromModel(member),
    };

    for (final operation in await _readOperations(_memberTable)) {
      final rowKey = _decodeObject(
        operation['row_key_json']! as String,
        'row_key_json',
      );
      final rowConversationId = rowKey['conversation_id'];
      final userId = rowKey['user_id'];
      if (rowKey.length != 2 ||
          rowConversationId is! String ||
          userId is! int) {
        throw const FormatException(
          'Invalid conversation_user_table overlay row key',
        );
      }
      if (rowConversationId != conversationId) {
        continue;
      }
      switch (operation['operation']) {
        case 'tombstone':
          visible.remove(userId);
        case 'upsert':
          final state = visible[userId] ??
              (baseByUserId[userId] == null
                  ? _MemberState.empty(conversationId, userId)
                  : _MemberState.fromModel(baseByUserId[userId]!));
          state.apply(_decodeValues(operation));
          visible[userId] = state;
        default:
          throw FormatException(
            'Unsupported overlay operation: ${operation['operation']}',
          );
      }
    }

    final members = visible.values
        .map((state) => state.toModel())
        .toList(growable: false)
      ..sort((left, right) => left.userId.compareTo(right.userId));
    return List<WeComConversationMember>.unmodifiable(members);
  }

  Future<List<WeComConversationSummary>> _readAllBaseConversations() async {
    final conversations = <WeComConversationSummary>[];
    var offset = 0;
    while (true) {
      final page = await _baseRepository.listConversations(offset: offset);
      conversations.addAll(page);
      if (page.length < WeComConversationRepository.maxPageSize) {
        return conversations;
      }
      offset += page.length;
    }
  }

  Future<List<Map<String, Object?>>> _readOperations(String tableName) {
    return _overlayDatabase.connection.query(
      WeComOverlaySchema.operationsTable,
      columns: ['row_key_json', 'operation', 'values_json'],
      where: 'dataset_id = ? AND database_name = ? AND table_name = ?',
      whereArgs: [datasetId, _databaseName, tableName],
      orderBy: 'revision_id',
    );
  }

  Map<String, Object?> _decodeValues(Map<String, Object?> operation) {
    final valuesJson = operation['values_json'];
    if (valuesJson is! String) {
      throw const FormatException('Overlay upsert values are missing');
    }
    return _decodeObject(valuesJson, 'values_json');
  }

  Map<String, Object?> _decodeObject(String source, String fieldName) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw FormatException('$fieldName must be a JSON object');
    }
    return Map<String, Object?>.from(decoded);
  }

  void _validatePagination(int limit, int offset) {
    if (limit < 1 || limit > WeComConversationRepository.maxPageSize) {
      throw RangeError.range(
        limit,
        1,
        WeComConversationRepository.maxPageSize,
        'limit',
      );
    }
    if (offset < 0) {
      throw RangeError.value(offset, 'offset', 'Must not be negative');
    }
  }

  static int _compareConversations(
    WeComConversationSummary left,
    WeComConversationSummary right,
  ) {
    final leftTime = left.lastMessageTime;
    final rightTime = right.lastMessageTime;
    if (leftTime == null && rightTime != null) {
      return 1;
    }
    if (leftTime != null && rightTime == null) {
      return -1;
    }
    if (leftTime != null && rightTime != null) {
      final byTime = rightTime.compareTo(leftTime);
      if (byTime != 0) {
        return byTime;
      }
    }
    return right.numericId.compareTo(left.numericId);
  }
}

class _ConversationState {
  _ConversationState({
    required this.numericId,
    required this.id,
    required this.name,
    required this.roomNameRemark,
    required this.lastMessageTime,
    required this.lastMessageId,
    required this.pinnedFlag,
    required this.blockedFlag,
    required this.status,
    required this.foldStatus,
  });

  factory _ConversationState.fromSummary(WeComConversationSummary summary) {
    return _ConversationState(
      numericId: summary.numericId,
      id: summary.id,
      name: summary.name,
      roomNameRemark: summary.roomNameRemark,
      lastMessageTime: summary.lastMessageTime,
      lastMessageId: summary.lastMessageId,
      pinnedFlag: summary.pinnedFlag,
      blockedFlag: summary.blockedFlag,
      status: summary.status,
      foldStatus: summary.foldStatus,
    );
  }

  factory _ConversationState.empty(int numericId) {
    return _ConversationState(
      numericId: numericId,
      id: '',
      name: '',
      roomNameRemark: '',
      lastMessageTime: 0,
      lastMessageId: 0,
      pinnedFlag: 0,
      blockedFlag: 0,
      status: 0,
      foldStatus: 0,
    );
  }

  final int numericId;
  String id;
  String name;
  String? roomNameRemark;
  int? lastMessageTime;
  int? lastMessageId;
  int pinnedFlag;
  int blockedFlag;
  int status;
  int? foldStatus;

  void apply(Map<String, Object?> values) {
    if (values.containsKey('id')) {
      id = _requiredString(values['id'], 'id');
    }
    if (values.containsKey('name')) {
      name = _requiredString(values['name'], 'name');
    }
    if (values.containsKey('roomname_remark')) {
      roomNameRemark = _nullableString(
        values['roomname_remark'],
        'roomname_remark',
      );
    }
    if (values.containsKey('last_message_time')) {
      lastMessageTime = _nullableInt(
        values['last_message_time'],
        'last_message_time',
      );
    }
    if (values.containsKey('last_message_id')) {
      lastMessageId = _nullableInt(
        values['last_message_id'],
        'last_message_id',
      );
    }
    if (values.containsKey('is_sticked')) {
      pinnedFlag = _requiredInt(values['is_sticked'], 'is_sticked');
    }
    if (values.containsKey('is_blocked')) {
      blockedFlag = _requiredInt(values['is_blocked'], 'is_blocked');
    }
    if (values.containsKey('status')) {
      status = _requiredInt(values['status'], 'status');
    }
    if (values.containsKey('fold_status')) {
      foldStatus = _nullableInt(values['fold_status'], 'fold_status');
    }
  }

  WeComConversationSummary toSummary(
    WeComConversationUnreadState? unreadState,
  ) {
    return WeComConversationSummary.fromFields(
      numericId: numericId,
      id: id,
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
}

class _UnreadState {
  _UnreadState({
    required this.conversationId,
    required this.beginCursor,
    required this.currentCursor,
    required this.unreadCount,
  });

  factory _UnreadState.fromModel(WeComConversationUnreadState state) {
    return _UnreadState(
      conversationId: state.conversationId,
      beginCursor: state.beginCursor,
      currentCursor: state.currentCursor,
      unreadCount: state.unreadCount,
    );
  }

  factory _UnreadState.empty(String conversationId) {
    return _UnreadState(
      conversationId: conversationId,
      beginCursor: 0,
      currentCursor: 0,
      unreadCount: 0,
    );
  }

  final String conversationId;
  int beginCursor;
  int currentCursor;
  int unreadCount;

  void apply(Map<String, Object?> values) {
    if (values.containsKey('begin_cursor')) {
      beginCursor = _requiredInt(values['begin_cursor'], 'begin_cursor');
    }
    if (values.containsKey('current_cursor')) {
      currentCursor = _requiredInt(values['current_cursor'], 'current_cursor');
    }
    if (values.containsKey('unread_count')) {
      unreadCount = _requiredInt(values['unread_count'], 'unread_count');
    }
  }

  WeComConversationUnreadState toModel() {
    return WeComConversationUnreadState(
      conversationId: conversationId,
      beginCursor: beginCursor,
      currentCursor: currentCursor,
      unreadCount: unreadCount,
    );
  }
}

class _MemberState {
  _MemberState({
    required this.conversationId,
    required this.userId,
    required this.joinTime,
    required this.gagType,
    required this.nickname,
    required this.adminFlag,
  });

  factory _MemberState.fromModel(WeComConversationMember member) {
    return _MemberState(
      conversationId: member.conversationId,
      userId: member.userId,
      joinTime: member.joinTime,
      gagType: member.gagType,
      nickname: member.nickname,
      adminFlag: member.adminFlag,
    );
  }

  factory _MemberState.empty(String conversationId, int userId) {
    return _MemberState(
      conversationId: conversationId,
      userId: userId,
      joinTime: 0,
      gagType: 0,
      nickname: '',
      adminFlag: 0,
    );
  }

  final String conversationId;
  final int userId;
  int joinTime;
  int gagType;
  String? nickname;
  int? adminFlag;

  void apply(Map<String, Object?> values) {
    if (values.containsKey('join_time')) {
      joinTime = _requiredInt(values['join_time'], 'join_time');
    }
    if (values.containsKey('gag_type')) {
      gagType = _requiredInt(values['gag_type'], 'gag_type');
    }
    if (values.containsKey('nick_name')) {
      nickname = _nullableString(values['nick_name'], 'nick_name');
    }
    if (values.containsKey('is_admin')) {
      adminFlag = _nullableInt(values['is_admin'], 'is_admin');
    }
  }

  WeComConversationMember toModel() {
    return WeComConversationMember(
      conversationId: conversationId,
      userId: userId,
      joinTime: joinTime,
      gagType: gagType,
      nickname: nickname,
      adminFlag: adminFlag,
    );
  }
}

int _requiredInt(Object? value, String fieldName) {
  if (value is! int) {
    throw FormatException('$fieldName must be an integer');
  }
  return value;
}

int? _nullableInt(Object? value, String fieldName) {
  if (value != null && value is! int) {
    throw FormatException('$fieldName must be a nullable integer');
  }
  return value as int?;
}

String _requiredString(Object? value, String fieldName) {
  if (value is! String) {
    throw FormatException('$fieldName must be a string');
  }
  return value;
}

String? _nullableString(Object? value, String fieldName) {
  if (value != null && value is! String) {
    throw FormatException('$fieldName must be a nullable string');
  }
  return value as String?;
}
