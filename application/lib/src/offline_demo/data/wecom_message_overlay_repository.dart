import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../domain/models.dart';
import '../domain/wecom_message_models.dart';
import 'wecom_identity_repository.dart';
import 'wecom_overlay_database.dart';
import 'wecom_overlay_schema.dart';

class WeComMessageOverlayState {
  const WeComMessageOverlayState._({
    required this.mode,
    this.senderId,
    this.text,
    this.sentAtMicros,
  });

  const WeComMessageOverlayState.inherit() : this._(mode: 'inherit');
  const WeComMessageOverlayState.hidden() : this._(mode: 'hidden');
  WeComMessageOverlayState.text({
    required String senderId,
    required String text,
    DateTime? sentAt,
  }) : this._(
          mode: 'text',
          senderId: senderId,
          text: text,
          sentAtMicros: sentAt?.microsecondsSinceEpoch,
        );

  final String mode;
  final String? senderId;
  final String? text;
  final int? sentAtMicros;

  String encode() => jsonEncode({
        'mode': mode,
        if (senderId != null) 'senderId': senderId,
        if (text != null) 'text': text,
        if (sentAtMicros != null) 'sentAtMicros': sentAtMicros,
      });

  factory WeComMessageOverlayState.decode(String value) {
    final data = jsonDecode(value);
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Invalid message overlay state.');
    }
    return switch (data['mode']) {
      'inherit' => const WeComMessageOverlayState.inherit(),
      'hidden' => const WeComMessageOverlayState.hidden(),
      'text'
          when data['senderId'] is String &&
              data['text'] is String &&
              (data['sentAtMicros'] == null || data['sentAtMicros'] is int) =>
        WeComMessageOverlayState._(
          mode: 'text',
          senderId: data['senderId'] as String,
          text: data['text'] as String,
          sentAtMicros: data['sentAtMicros'] as int?,
        ),
      _ => throw const FormatException('Invalid message overlay state.'),
    };
  }
}

class WeComMessageOverlayEdit {
  const WeComMessageOverlayEdit._({
    required this.editId,
    required this.conversationId,
    required this.targetKey,
    required this.previousState,
  });

  final int editId;
  final String conversationId;
  final String targetKey;
  final WeComMessageOverlayState previousState;
}

class WeComMessageOverlayRepository {
  WeComMessageOverlayRepository({
    required WeComOverlayDatabase overlayDatabase,
    required WeComIdentityScope identityScope,
    DateTime Function()? now,
  })  : _database = overlayDatabase.connection,
        _sceneId = overlayDatabase.sceneId,
        _scope = identityScope,
        _now = now ?? DateTime.now;

  final Database _database;
  final String _sceneId;
  final WeComIdentityScope _scope;
  final DateTime Function() _now;
  final _random = Random.secure();

  String newMessageId() => 'overlay:${_now().toUtc().microsecondsSinceEpoch}-'
      '${_random.nextInt(0x7fffffff)}';

  String targetKeyForBase(WeComMessageRecord record) {
    final identity = utf8.encode(
      '${record.messageId}\u0000${record.conversationId}\u0000'
      '${record.senderId}\u0000${record.sendTime}\u0000',
    );
    final digest = sha256.convert([...identity, ...?record.content]).toString();
    return 'base:${record.messageId}:$digest';
  }

  String targetKeyForProjected(String messageId) {
    if (messageId.startsWith('overlay:')) return messageId;
    if (messageId.startsWith('local:') ||
        messageId.startsWith('local-reply:')) {
      return 'sim:$messageId';
    }
    throw ArgumentError.value(messageId, 'messageId', 'Not a local message');
  }

  Future<Set<String>> touchedConversations() async {
    final rows = await _database.query(
      WeComOverlaySchema.messageEditsTable,
      distinct: true,
      columns: ['conversation_id'],
      where: 'identity_corp_id = ? AND identity_user_id = ? AND scene_id = ?',
      whereArgs: [_scope.corporationId, _scope.userId, _sceneId],
    );
    return rows.map((row) => row['conversation_id']! as String).toSet();
  }

  Future<List<OfflineMessage>> apply({
    required String conversationId,
    required List<OfflineMessage> messages,
    required Map<String, String> baseTargetKeys,
    required Map<String, String> senderNames,
  }) async {
    final rows = await _database.query(
      WeComOverlaySchema.messageEditsTable,
      columns: ['target_key', 'state_json'],
      where: 'identity_corp_id = ? AND identity_user_id = ? '
          'AND scene_id = ? AND conversation_id = ?',
      whereArgs: [
        _scope.corporationId,
        _scope.userId,
        _sceneId,
        conversationId
      ],
      orderBy: 'edit_id ASC',
    );
    final states = <String, WeComMessageOverlayState>{};
    for (final row in rows) {
      states[row['target_key']! as String] =
          WeComMessageOverlayState.decode(row['state_json']! as String);
    }
    final result = <OfflineMessage>[];
    for (final message in messages) {
      final targetKey = baseTargetKeys[message.id] ??
          (message.id.startsWith('local:') ||
                  message.id.startsWith('local-reply:')
              ? 'sim:${message.id}'
              : null);
      final state = states[targetKey];
      if (state == null || state.mode == 'inherit') {
        result.add(message);
      } else if (state.mode == 'text') {
        result.add(_applyText(message, state, senderNames));
      }
    }
    for (final entry in states.entries) {
      if (!entry.key.startsWith('overlay:') || entry.value.mode != 'text') {
        continue;
      }
      final state = entry.value;
      final senderId = state.senderId!;
      result.add(OfflineMessage(
        id: entry.key,
        conversationId: conversationId,
        senderProfileId: senderId,
        senderName: senderNames[senderId] ?? senderId,
        kind: 'text',
        text: state.text!,
        sentAt: DateTime.fromMicrosecondsSinceEpoch(
          state.sentAtMicros!,
          isUtc: true,
        ),
        status: '',
        isRecalled: false,
        isLocalOverlay: true,
      ));
    }
    result.sort((left, right) {
      final time = left.sentAt.compareTo(right.sentAt);
      return time != 0 ? time : left.id.compareTo(right.id);
    });
    return List.unmodifiable(result);
  }

  Future<WeComMessageOverlayEdit> append({
    required String conversationId,
    required String targetKey,
    required String action,
    required WeComMessageOverlayState state,
  }) async {
    if (!const {'add', 'replace', 'hide'}.contains(action)) {
      throw ArgumentError.value(action, 'action');
    }
    return _database.transaction((txn) async {
      final previous = await _latest(txn, conversationId, targetKey);
      final previousState = previous == null
          ? targetKey.startsWith('overlay:')
              ? const WeComMessageOverlayState.hidden()
              : const WeComMessageOverlayState.inherit()
          : WeComMessageOverlayState.decode(previous['state_json']! as String);
      if (previousState.encode() == state.encode()) {
        throw StateError('Message edit does not change the visible state.');
      }
      if (action == 'add' && previous != null) {
        throw StateError('Local message already exists.');
      }
      final editId = await txn.insert(WeComOverlaySchema.messageEditsTable, {
        'identity_corp_id': _scope.corporationId,
        'identity_user_id': _scope.userId,
        'conversation_id': conversationId,
        'target_key': targetKey,
        'action': action,
        'scene_id': _sceneId,
        'state_json': state.encode(),
        'created_at_micros': _now().toUtc().microsecondsSinceEpoch,
      });
      return WeComMessageOverlayEdit._(
        editId: editId,
        conversationId: conversationId,
        targetKey: targetKey,
        previousState: previousState,
      );
    });
  }

  Future<void> undo(WeComMessageOverlayEdit edit) async {
    await _database.transaction((txn) async {
      final rows = await txn.query(
        WeComOverlaySchema.messageEditsTable,
        columns: ['edit_id', 'action', 'reverts_edit_id'],
        where: 'identity_corp_id = ? AND identity_user_id = ? '
            'AND scene_id = ? AND conversation_id = ? AND target_key = ?',
        whereArgs: [
          _scope.corporationId,
          _scope.userId,
          _sceneId,
          edit.conversationId,
          edit.targetKey,
        ],
        orderBy: 'edit_id ASC',
      );
      final active = <int>[];
      for (final row in rows) {
        if (row['action'] == 'undo') {
          if (active.isEmpty || active.last != row['reverts_edit_id']) {
            throw StateError('Message edit history is inconsistent.');
          }
          active.removeLast();
        } else {
          active.add(row['edit_id']! as int);
        }
      }
      if (active.isEmpty || active.last != edit.editId) {
        throw StateError('A newer message edit must be undone first.');
      }
      await txn.insert(WeComOverlaySchema.messageEditsTable, {
        'identity_corp_id': _scope.corporationId,
        'identity_user_id': _scope.userId,
        'conversation_id': edit.conversationId,
        'target_key': edit.targetKey,
        'action': 'undo',
        'scene_id': _sceneId,
        'state_json': edit.previousState.encode(),
        'reverts_edit_id': edit.editId,
        'created_at_micros': _now().toUtc().microsecondsSinceEpoch,
      });
    });
  }

  Future<Map<String, Object?>?> _latest(
    Transaction txn,
    String conversationId,
    String targetKey,
  ) async {
    final rows = await txn.query(
      WeComOverlaySchema.messageEditsTable,
      columns: ['edit_id', 'state_json'],
      where: 'identity_corp_id = ? AND identity_user_id = ? '
          'AND scene_id = ? AND conversation_id = ? AND target_key = ?',
      whereArgs: [
        _scope.corporationId,
        _scope.userId,
        _sceneId,
        conversationId,
        targetKey,
      ],
      orderBy: 'edit_id DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single;
  }

  OfflineMessage _applyText(
    OfflineMessage original,
    WeComMessageOverlayState state,
    Map<String, String> senderNames,
  ) {
    final senderId = state.senderId!;
    return OfflineMessage(
      id: original.id,
      conversationId: original.conversationId,
      senderProfileId: senderId,
      senderName: senderNames[senderId] ?? senderId,
      kind: 'text',
      text: state.text!,
      sentAt: original.sentAt,
      status: '',
      isRecalled: false,
      isLocalOverlay: true,
    );
  }
}
