import 'dart:convert';

import 'wecom_database_package.dart';
import 'wecom_identity_repository.dart';
import 'wecom_message_overlay_repository.dart';
import 'wecom_overlay_contract_validator.dart';
import 'wecom_overlay_schema.dart';

enum WeComScenePackageIssue { invalid, unsupportedVersion, identity, dataset }

class WeComScenePackageException implements Exception {
  const WeComScenePackageException(this.issue);
  final WeComScenePackageIssue issue;
}

class WeComSceneLog {
  const WeComSceneLog(this.table, this.id, this.revert, this.columns);
  final String table;
  final String id;
  final String revert;
  final List<String> columns;
}

class WeComScenePackage {
  WeComScenePackage._(this.name, this.datasetId, this.scope, this.logs);

  static const maxBytes = 16 * 1024 * 1024;
  static const maxRows = 50000;
  static const format = 'tui-overlay-scene';
  static const logTypes = [
    WeComSceneLog(WeComOverlaySchema.operationsTable, 'revision_id',
        'reverts_revision_id', [
      'revision_id',
      'dataset_id',
      'database_name',
      'table_name',
      'row_key_json',
      'operation',
      'values_json',
      'base_row_sha256',
      'reverts_revision_id',
      'created_at_micros',
    ]),
    WeComSceneLog(WeComOverlaySchema.simulationEventsTable, 'event_id',
        'reverts_event_id', [
      'event_id',
      'event_key',
      'event_type',
      'payload_json',
      'reverts_event_id',
      'created_at_micros',
    ]),
    WeComSceneLog(
        WeComOverlaySchema.messageEditsTable, 'edit_id', 'reverts_edit_id', [
      'edit_id',
      'conversation_id',
      'target_key',
      'action',
      'state_json',
      'reverts_edit_id',
      'created_at_micros',
    ]),
  ];

  final String name;
  final String datasetId;
  final WeComIdentityScope scope;
  final Map<String, List<Map<String, Object?>>> logs;

  static WeComScenePackage decode(String text, WeComPackageContract contract) {
    try {
      if (utf8.encode(text).length > maxBytes) _invalid();
      final data = _object(jsonDecode(text));
      _keys(data, const [
        'format',
        'version',
        'overlay_schema',
        'name',
        'dataset_id',
        'identity_corp_id',
        'identity_user_id',
        'logs',
      ]);
      if (data['format'] != format) _invalid();
      if (data['version'] != 1 ||
          data['overlay_schema'] != WeComOverlaySchema.version) {
        throw const WeComScenePackageException(
            WeComScenePackageIssue.unsupportedVersion);
      }
      final name = _text(data, 'name');
      if (name.trim() != name || name.length > 60) _invalid();
      final dataset = _hash(data['dataset_id']);
      final scope = WeComIdentityScope(
        corporationId: _positive(data['identity_corp_id']),
        userId: _positive(data['identity_user_id']),
      );
      final rawLogs = _object(data['logs']);
      _keys(rawLogs, logTypes.map((log) => log.table).toList());
      final logs = <String, List<Map<String, Object?>>>{};
      var count = 0;
      final validator = WeComOverlayContractValidator(contract);
      for (final log in logTypes) {
        final raw = rawLogs[log.table];
        if (raw is! List || (count += raw.length) > maxRows) _invalid();
        final rows = <Map<String, Object?>>[];
        final ids = <int, Map<String, Object?>>{};
        final eventKeys = <String>{};
        final reverted = <int>{};
        final messageStacks = <(String, String), List<int>>{};
        final messageStates = <(String, String), String>{};
        final beforeStates = <int, String>{};
        for (final value in raw) {
          final row = _object(value);
          _keys(row, log.columns);
          final id = _positive(row[log.id]);
          if (rows.isNotEmpty && id <= (rows.last[log.id]! as int)) _invalid();
          _time(row['created_at_micros']);
          Map<String, Object?>? target;
          if (row[log.revert] != null) {
            final ref = _positive(row[log.revert]);
            target = ids[ref];
            if (target == null) _invalid();
            if (log.table != WeComOverlaySchema.operationsTable &&
                !reverted.add(ref)) {
              _invalid();
            }
          }
          switch (log.table) {
            case WeComOverlaySchema.operationsTable:
              _operation(row, target, validator);
            case WeComOverlaySchema.simulationEventsTable:
              if (!eventKeys.add(_text(row, 'event_key'))) _invalid();
              _simulation(row, target);
            case WeComOverlaySchema.messageEditsTable:
              _message(row, target);
              final key = (
                row['conversation_id']! as String,
                row['target_key']! as String
              );
              final stack = messageStacks.putIfAbsent(key, () => []);
              if (row['action'] == 'undo') {
                final ref = row[log.revert]! as int;
                if (stack.isEmpty ||
                    stack.last != ref ||
                    beforeStates[ref] != row['state_json']) {
                  _invalid();
                }
                stack.removeLast();
              } else {
                if (row['action'] == 'add' && messageStates.containsKey(key)) {
                  _invalid();
                }
                beforeStates[id] = messageStates[key] ??
                    (key.$2.startsWith('overlay:')
                            ? const WeComMessageOverlayState.hidden()
                            : const WeComMessageOverlayState.inherit())
                        .encode();
                stack.add(id);
              }
              messageStates[key] = row['state_json']! as String;
          }
          rows.add(row);
          ids[id] = row;
        }
        logs[log.table] = rows;
      }
      return WeComScenePackage._(name, dataset, scope, logs);
    } on WeComScenePackageException {
      rethrow;
    } catch (_) {
      throw const WeComScenePackageException(WeComScenePackageIssue.invalid);
    }
  }

  static String encode({
    required String name,
    required String datasetId,
    required WeComIdentityScope scope,
    required Map<String, List<Map<String, Object?>>> logs,
    required WeComPackageContract contract,
  }) {
    final text = jsonEncode({
      'format': format,
      'version': 1,
      'overlay_schema': WeComOverlaySchema.version,
      'name': name,
      'dataset_id': datasetId,
      'identity_corp_id': scope.corporationId,
      'identity_user_id': scope.userId,
      'logs': logs,
    });
    decode(text, contract);
    return text;
  }

  static void _operation(Map<String, Object?> row, Map<String, Object?>? undo,
      WeComOverlayContractValidator validator) {
    _hash(row['dataset_id']);
    if (row['base_row_sha256'] != null) _hash(row['base_row_sha256']);
    final target = validator.resolveTarget(
        _text(row, 'database_name'), _text(row, 'table_name'));
    row['row_key_json'] = jsonEncode(
        validator.canonicalRowKey(target, _json(row, 'row_key_json')));
    if (row['operation'] == 'upsert') {
      row['values_json'] = jsonEncode(
          validator.canonicalValues(target, _json(row, 'values_json')));
    } else if (row['operation'] != 'tombstone' || row['values_json'] != null) {
      _invalid();
    }
    if (undo != null &&
        const ['dataset_id', 'database_name', 'table_name', 'row_key_json']
            .any((key) => undo[key] != row[key])) {
      _invalid();
    }
  }

  static void _simulation(
      Map<String, Object?> row, Map<String, Object?>? undo) {
    final payload = _json(row, 'payload_json');
    if (payload['version'] != 1) _invalid();
    switch (row['event_type']) {
      case 'textExchange':
        if (undo != null) _invalid();
        _keys(payload, const [
          'version',
          'conversationId',
          'senderProfileId',
          'peerProfileId',
          'text',
          'serverAcknowledgedAtMicros',
          'peerReadAtMicros',
          'automaticReplyAtMicros',
          'automaticReplyText'
        ]);
        for (final key in [
          'conversationId',
          'senderProfileId',
          'text',
          'automaticReplyText'
        ]) {
          _text(payload, key);
        }
        if (payload['peerProfileId'] != null) {
          _text(payload, 'peerProfileId');
        }
        for (final key in [
          'serverAcknowledgedAtMicros',
          'peerReadAtMicros',
          'automaticReplyAtMicros'
        ]) {
          _time(payload[key]);
        }
      case 'scheduledCall':
        if (undo != null) _invalid();
        _keys(payload, const ['version', 'peerProfileId', 'scheduledAtMicros']);
        _text(payload, 'peerProfileId');
        _time(payload['scheduledAtMicros']);
      case 'cancelExchange' || 'cancelCall' || 'rejectCall':
        _keys(payload, const ['version']);
        if (undo == null ||
            undo['event_type'] !=
                (row['event_type'] == 'cancelExchange'
                    ? 'textExchange'
                    : 'scheduledCall')) {
          _invalid();
        }
      default:
        _invalid();
    }
  }

  static void _message(Map<String, Object?> row, Map<String, Object?>? undo) {
    _text(row, 'conversation_id');
    final key = _text(row, 'target_key');
    if (!key.startsWith('overlay:') &&
        !key.startsWith('base:') &&
        !key.startsWith('sim:')) {
      _invalid();
    }
    final state = WeComMessageOverlayState.decode(_text(row, 'state_json'));
    final data = _json(row, 'state_json');
    _keys(data, _object(jsonDecode(state.encode())).keys.toList());
    row['state_json'] = state.encode();
    if (state.mode == 'text') {
      if (state.senderId!.isEmpty || state.text!.trim().isEmpty) _invalid();
      if (state.sentAtMicros != null) {
        _time(state.sentAtMicros);
      }
      if (key.startsWith('overlay:') && state.sentAtMicros == null) _invalid();
    }
    switch (row['action']) {
      case 'add':
        if (undo != null ||
            !key.startsWith('overlay:') ||
            state.mode != 'text') {
          _invalid();
        }
      case 'replace':
        if (undo != null || state.mode != 'text') _invalid();
      case 'hide':
        if (undo != null || state.mode != 'hidden') _invalid();
      case 'undo':
        if (undo == null ||
            undo['action'] == 'undo' ||
            undo['conversation_id'] != row['conversation_id'] ||
            undo['target_key'] != key) {
          _invalid();
        }
      default:
        _invalid();
    }
  }

  static Map<String, Object?> _object(Object? value) {
    if (value is! Map<String, dynamic>) _invalid();
    return Map<String, Object?>.from(value);
  }

  static Map<String, Object?> _json(Map<String, Object?> row, String key) =>
      _object(jsonDecode(_text(row, key)));

  static void _keys(Map<String, Object?> data, List<String> keys) {
    if (data.length != keys.length || !data.keys.toSet().containsAll(keys)) {
      _invalid();
    }
  }

  static String _text(Map<String, Object?> data, String key) {
    final value = data[key];
    if (value is! String || value.trim().isEmpty) _invalid();
    return value;
  }

  static String _hash(Object? value) {
    if (value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
      _invalid();
    }
    return value;
  }

  static int _positive(Object? value) {
    if (value is! int || value <= 0) _invalid();
    return value;
  }

  static void _time(Object? value) =>
      DateTime.fromMicrosecondsSinceEpoch(_positive(value));
  static Never _invalid() =>
      throw const WeComScenePackageException(WeComScenePackageIssue.invalid);
}
