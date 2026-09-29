import '../domain/wecom_conversation_models.dart';
import 'wecom_conversation_repository.dart';
import 'wecom_local_simulation_repository.dart';
import 'wecom_merged_conversation_repository.dart';
import 'wecom_overlay_command_service.dart';

class WeComConversationEdit {
  WeComConversationEdit._({
    required this.revisionId,
    required this.numericId,
    required this.previousRemark,
  });

  final int revisionId;
  final int numericId;
  final String previousRemark;
  bool _undone = false;
}

class WeComConversationBatchEdit {
  WeComConversationBatchEdit._({
    required List<int> revisionIds,
    required List<_ReverseConversationMutation> reverseMutations,
  })  : revisionIds = List<int>.unmodifiable(revisionIds),
        _reverseMutations = List<_ReverseConversationMutation>.unmodifiable(
          reverseMutations,
        );

  final List<int> revisionIds;
  final List<_ReverseConversationMutation> _reverseMutations;
  bool _undone = false;
}

class WeComConversationEditor {
  const WeComConversationEditor({
    required this.datasetId,
    required WeComMergedConversationRepository conversations,
    required WeComOverlayCommandService commands,
    required WeComLocalSimulationRepository simulation,
  })  : _conversations = conversations,
        _commands = commands,
        _simulation = simulation;

  static const _databaseName = 'session.db';
  static const _conversationTable = 'conversation_table';
  static const _localMessagePrefix = 'local:';

  final String datasetId;
  final WeComMergedConversationRepository _conversations;
  final WeComOverlayCommandService _commands;
  final WeComLocalSimulationRepository _simulation;

  Future<WeComConversationEdit> renameGroup({
    required String conversationId,
    required String roomNameRemark,
  }) async {
    final summary = await _findConversation(conversationId);
    if (!summary.id.startsWith('R:')) {
      throw UnsupportedError('Only group conversation remarks are editable.');
    }
    final normalized = roomNameRemark.trim();
    final previous = summary.roomNameRemark ?? '';
    if (previous.trim() == normalized) {
      throw const WeComConversationNoChangesException();
    }
    final revisionId = await _commands.upsert(
      datasetId: datasetId,
      databaseName: _databaseName,
      tableName: _conversationTable,
      rowKey: {'con_numeric_id': summary.numericId},
      values: {'roomname_remark': normalized},
    );
    return WeComConversationEdit._(
      revisionId: revisionId,
      numericId: summary.numericId,
      previousRemark: previous,
    );
  }

  Future<void> undo(WeComConversationEdit edit) async {
    if (edit._undone) {
      throw StateError('This conversation edit was already undone.');
    }
    await _commands.upsert(
      datasetId: datasetId,
      databaseName: _databaseName,
      tableName: _conversationTable,
      rowKey: {'con_numeric_id': edit.numericId},
      values: {'roomname_remark': edit.previousRemark},
      revertsRevisionId: edit.revisionId,
    );
    edit._undone = true;
  }

  Future<WeComConversationBatchEdit> updateFlags({
    required Set<String> conversationIds,
    bool? isPinned,
    bool? isMuted,
  }) async {
    if (conversationIds.isEmpty) {
      throw ArgumentError.value(
        conversationIds,
        'conversationIds',
        'Must not be empty',
      );
    }
    if (isPinned == null && isMuted == null) {
      throw ArgumentError('At least one flag must be provided.');
    }

    final conversations = {
      for (final conversation in await _listConversations())
        conversation.id: conversation,
    };
    final missing = conversationIds.difference(conversations.keys.toSet());
    if (missing.isNotEmpty) {
      throw StateError(
        'Conversations do not exist: ${(missing.toList()..sort()).join(', ')}',
      );
    }

    final forward = <WeComOverlayMutation>[];
    final reverse = <_ReverseConversationMutation>[];
    final sortedIds = conversationIds.toList()..sort();
    for (final conversationId in sortedIds) {
      final conversation = conversations[conversationId]!;
      final values = <String, Object?>{};
      final previousValues = <String, Object?>{};
      if (isPinned != null && (conversation.pinnedFlag == 1) != isPinned) {
        values['is_sticked'] = isPinned ? 1 : 0;
        previousValues['is_sticked'] = conversation.pinnedFlag;
      }
      if (isMuted != null && (conversation.blockedFlag == 1) != isMuted) {
        values['is_blocked'] = isMuted ? 1 : 0;
        previousValues['is_blocked'] = conversation.blockedFlag;
      }
      if (values.isEmpty) {
        continue;
      }
      final rowKey = <String, Object?>{
        'con_numeric_id': conversation.numericId,
      };
      forward.add(
        WeComOverlayMutation.upsert(
          databaseName: _databaseName,
          tableName: _conversationTable,
          rowKey: rowKey,
          values: values,
        ),
      );
      reverse.add(
        _ReverseConversationMutation(
          rowKey: rowKey,
          values: previousValues,
        ),
      );
    }
    if (forward.isEmpty) {
      throw const WeComConversationNoChangesException();
    }
    final revisionIds = await _commands.appendBatch(
      datasetId: datasetId,
      mutations: forward,
    );
    return WeComConversationBatchEdit._(
      revisionIds: revisionIds,
      reverseMutations: reverse,
    );
  }

  Future<void> undoBatch(WeComConversationBatchEdit edit) async {
    if (edit._undone) {
      throw StateError('This conversation batch edit was already undone.');
    }
    if (edit.revisionIds.length != edit._reverseMutations.length) {
      throw StateError('Conversation batch edit metadata is inconsistent.');
    }
    await _commands.appendBatch(
      datasetId: datasetId,
      mutations: [
        for (var index = 0; index < edit._reverseMutations.length; index++)
          edit._reverseMutations[index].toMutation(edit.revisionIds[index]),
      ],
    );
    edit._undone = true;
  }

  Future<void> cancelLocalMessage({
    required String conversationId,
    required String messageId,
  }) async {
    if (!messageId.startsWith(_localMessagePrefix)) {
      throw UnsupportedError('Only local simulated messages can be revoked.');
    }
    final eventKey = messageId.substring(_localMessagePrefix.length);
    if (eventKey.isEmpty) {
      throw ArgumentError.value(messageId, 'messageId', 'Missing event key.');
    }
    final exchanges = await _simulation.listExchanges(
      conversationId: conversationId,
    );
    if (!exchanges.any((exchange) => exchange.eventKey == eventKey)) {
      throw StateError('Local simulated message does not exist.');
    }
    await _simulation.cancelTextExchange(eventKey);
  }

  Future<WeComConversationSummary> _findConversation(
    String conversationId,
  ) async {
    for (final conversation in await _listConversations()) {
      if (conversation.id == conversationId) {
        return conversation;
      }
    }
    throw StateError('Conversation does not exist: $conversationId');
  }

  Future<List<WeComConversationSummary>> _listConversations() async {
    final conversations = <WeComConversationSummary>[];
    var offset = 0;
    while (true) {
      final page = await _conversations.listConversations(offset: offset);
      conversations.addAll(page);
      if (page.length < WeComConversationRepository.maxPageSize) {
        return conversations;
      }
      offset += page.length;
    }
  }
}

class WeComConversationNoChangesException implements Exception {
  const WeComConversationNoChangesException();
}

class _ReverseConversationMutation {
  const _ReverseConversationMutation({
    required this.rowKey,
    required this.values,
  });

  final Map<String, Object?> rowKey;
  final Map<String, Object?> values;

  WeComOverlayMutation toMutation(int revisionId) {
    return WeComOverlayMutation.upsert(
      databaseName: WeComConversationEditor._databaseName,
      tableName: WeComConversationEditor._conversationTable,
      rowKey: rowKey,
      values: values,
      revertsRevisionId: revisionId,
    );
  }
}
