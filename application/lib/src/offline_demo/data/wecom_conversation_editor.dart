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
    var offset = 0;
    while (true) {
      final page = await _conversations.listConversations(offset: offset);
      for (final conversation in page) {
        if (conversation.id == conversationId) {
          return conversation;
        }
      }
      if (page.length < WeComConversationRepository.maxPageSize) {
        throw StateError('Conversation does not exist: $conversationId');
      }
      offset += page.length;
    }
  }
}

class WeComConversationNoChangesException implements Exception {
  const WeComConversationNoChangesException();
}
