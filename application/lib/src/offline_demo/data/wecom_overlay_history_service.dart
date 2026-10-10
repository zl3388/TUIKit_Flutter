import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

import 'wecom_database_package.dart';
import 'wecom_identity_repository.dart';
import 'wecom_message_overlay_repository.dart';
import 'wecom_overlay_contract_validator.dart';
import 'wecom_overlay_database.dart';
import 'wecom_scene_package.dart';
import 'wecom_overlay_schema.dart';

enum WeComHistoryKind { fields, simulations, messages }

class WeComHistoryEntry {
  const WeComHistoryEntry(this.kind, this.row);
  final WeComHistoryKind kind;
  final Map<String, Object?> row;

  WeComSceneLog get log => WeComScenePackage.logTypes[kind.index];
  int get id => row[log.id]! as int;
  int? get revertsId => row[log.revert] as int?;
  DateTime get createdAt =>
      DateTime.fromMicrosecondsSinceEpoch(row['created_at_micros']! as int,
          isUtc: true);
  String get action => row[switch (kind) {
        WeComHistoryKind.fields => 'operation',
        WeComHistoryKind.messages => 'action',
        WeComHistoryKind.simulations => 'event_type',
      }]! as String;
  String get target => switch (kind) {
        WeComHistoryKind.fields =>
          '${row['database_name']}/${row['table_name']} ${row['row_key_json']}',
        WeComHistoryKind.messages =>
          '${row['conversation_id']} / ${row['target_key']}',
        WeComHistoryKind.simulations => row['event_key']! as String,
      };
}

class WeComHistoryDetail {
  const WeComHistoryDetail(
      this.entry, this.before, this.after, this.undoReason);
  final WeComHistoryEntry entry;
  final Map<String, Object?> before;
  final Map<String, Object?> after;
  final String? undoReason;
}

class WeComOverlayHistoryService {
  WeComOverlayHistoryService({
    required WeComOverlayDatabase overlay,
    required WeComImportedPackage base,
    required DatabaseFactory factory,
    required WeComPackageContract contract,
    required WeComIdentityScope scope,
    required bool Function() canEdit,
  })  : _overlay = overlay,
        _base = base,
        _factory = factory,
        _validator = WeComOverlayContractValidator(contract),
        _scope = scope,
        _canEdit = canEdit;

  static const pageSize = 50;
  static const _editableFields = {
    'user.db/user_table': {'real_name', 'position'},
    'user.db/department_tableV2': {'name'},
    'user.db/user_dept_tableV2': {'job'},
    'session.db/conversation_table': {
      'roomname_remark',
      'is_sticked',
      'is_blocked'
    },
    'forever_store.db/announce_table': {'subject', 'summary'},
  };
  final WeComOverlayDatabase _overlay;
  final WeComImportedPackage _base;
  final DatabaseFactory _factory;
  final WeComOverlayContractValidator _validator;
  final WeComIdentityScope _scope;
  final bool Function() _canEdit;
  final _random = Random.secure();

  String get _where =>
      'identity_corp_id = ? AND identity_user_id = ? AND scene_id = ?';
  List<Object?> get _args =>
      [_scope.corporationId, _scope.userId, _overlay.sceneId];

  Future<int> fieldRecordCount() =>
      _overlay.connection.transaction((txn) async {
        await _requireAccess(txn);
        final rows = await txn.rawQuery(
            'SELECT COUNT(*) AS total FROM ${WeComOverlaySchema.operationsTable} '
            'WHERE $_where AND dataset_id = ?',
            [..._args, _base.datasetId]);
        await _requireAccess(txn);
        return rows.single['total']! as int;
      });

  Future<List<WeComHistoryEntry>> list(WeComHistoryKind kind,
      {int offset = 0}) async {
    if (offset < 0) throw ArgumentError.value(offset, 'offset');
    return _overlay.connection.transaction((txn) async {
      await _requireAccess(txn);
      final log = WeComScenePackage.logTypes[kind.index];
      final rows = await txn.query(log.table,
          where: _where,
          whereArgs: _args,
          orderBy: '${log.id} DESC',
          limit: pageSize,
          offset: offset);
      await _requireAccess(txn);
      return List.unmodifiable(rows.map((row) => WeComHistoryEntry(kind, row)));
    });
  }

  Future<WeComHistoryDetail> detail(WeComHistoryKind kind, int id) =>
      _overlay.connection.transaction((txn) async {
        await _requireAccess(txn);
        final result = await _detail(txn, kind, id);
        await _requireAccess(txn);
        return result;
      });

  Future<void> undo(WeComHistoryKind kind, int id) =>
      _overlay.connection.transaction((txn) async {
        await _requireAccess(txn);
        final detail = await _detail(txn, kind, id);
        if (detail.undoReason != null) throw StateError(detail.undoReason!);
        final entry = detail.entry;
        final values = <String, Object?>{
          'identity_corp_id': _scope.corporationId,
          'identity_user_id': _scope.userId,
          'scene_id': _overlay.sceneId,
          entry.log.revert: id,
          'created_at_micros': DateTime.now().toUtc().microsecondsSinceEpoch,
        };
        switch (kind) {
          case WeComHistoryKind.fields:
            final row = entry.row;
            final target = _validator.resolveTarget(
                row['database_name']! as String, row['table_name']! as String);
            values.addAll({
              'dataset_id': _base.datasetId,
              'database_name': row['database_name'],
              'table_name': row['table_name'],
              'row_key_json': row['row_key_json'],
              'operation': 'upsert',
              'values_json':
                  jsonEncode(_validator.canonicalValues(target, detail.before)),
              'base_row_sha256': row['base_row_sha256'],
            });
          case WeComHistoryKind.messages:
            values.addAll({
              'conversation_id': entry.row['conversation_id'],
              'target_key': entry.row['target_key'],
              'action': 'undo',
              'state_json': jsonEncode(detail.before),
            });
          case WeComHistoryKind.simulations:
            values.addAll({
              'event_key': '${entry.row['event_key']}-history-'
                  '${values['created_at_micros']}-${_random.nextInt(0x7fffffff)}',
              'event_type': entry.action == 'textExchange'
                  ? 'cancelExchange'
                  : 'cancelCall',
              'payload_json': '{"version":1}',
            });
        }
        await _requireAccess(txn);
        await txn.insert(entry.log.table, values);
        await _requireAccess(txn);
      });

  Future<WeComHistoryDetail> _detail(
      Transaction txn, WeComHistoryKind kind, int id) async {
    final log = WeComScenePackage.logTypes[kind.index];
    final rows = await txn.query(log.table,
        where: '$_where AND ${log.id} = ?', whereArgs: [..._args, id]);
    if (rows.length != 1) throw StateError('Revision is outside this scene.');
    final entry = WeComHistoryEntry(kind, rows.single);
    return switch (kind) {
      WeComHistoryKind.fields => _fieldDetail(txn, entry),
      WeComHistoryKind.messages => _messageDetail(txn, entry),
      WeComHistoryKind.simulations => _simulationDetail(txn, entry),
    };
  }

  Future<WeComHistoryDetail> _fieldDetail(
      Transaction txn, WeComHistoryEntry entry) async {
    final row = entry.row;
    if (row['dataset_id'] != _base.datasetId || entry.action != 'upsert') {
      return WeComHistoryDetail(
          entry,
          const {},
          {'operation': entry.action, 'values': row['values_json']},
          '旧数据集或非字段覆盖修订仅供查看');
    }
    final databaseName = row['database_name']! as String;
    final tableName = row['table_name']! as String;
    final target = _validator.resolveTarget(databaseName, tableName);
    final key = _validator.canonicalRowKey(target, _json(row['row_key_json']));
    final after = _validator.canonicalValues(target, _json(row['values_json']));
    final db = await _base.openReadOnly(databaseName, factory: _factory);
    List<Map<String, Object?>> baseRows;
    try {
      baseRows = await db.query(tableName,
          columns: after.keys.toList(),
          where: key.keys.map((name) => '"$name" = ?').join(' AND '),
          whereArgs: key.values.toList(),
          limit: 2);
    } finally {
      await db.close();
    }
    final history = await txn.query(entry.log.table,
        where: '$_where AND dataset_id = ? AND database_name = ? '
            'AND table_name = ? AND row_key_json = ?',
        whereArgs: [
          ..._args,
          _base.datasetId,
          databaseName,
          tableName,
          row['row_key_json']
        ],
        orderBy: 'revision_id ASC');
    Map<String, Object?>? current = baseRows.length == 1
        ? Map<String, Object?>.from(baseRows.single)
        : null;
    Map<String, Object?> before = const {};
    for (final revision in history) {
      if (revision['revision_id'] == entry.id) {
        before = {for (final name in after.keys) name: current?[name]};
        break;
      }
      if (revision['operation'] == 'tombstone') {
        current = null;
      } else {
        current = {...?current, ..._json(revision['values_json'])};
      }
    }
    final allowed = _editableFields['$databaseName/$tableName'];
    final reason = baseRows.length != 1 || current == null
        ? '无法重建原始字段，仅供查看'
        : allowed == null || !allowed.containsAll(after.keys)
            ? '该字段不在当前编辑范围内'
            : _undoReason(entry, history);
    return WeComHistoryDetail(entry, before, after, reason);
  }

  Future<WeComHistoryDetail> _messageDetail(
      Transaction txn, WeComHistoryEntry entry) async {
    final rows = await txn.query(entry.log.table,
        where: '$_where AND conversation_id = ? AND target_key = ?',
        whereArgs: [
          ..._args,
          entry.row['conversation_id'],
          entry.row['target_key']
        ],
        orderBy: 'edit_id ASC');
    var previous = (entry.row['target_key']! as String).startsWith('overlay:')
        ? const WeComMessageOverlayState.hidden().encode()
        : const WeComMessageOverlayState.inherit().encode();
    for (final row in rows) {
      if (row['edit_id'] == entry.id) break;
      previous = row['state_json']! as String;
    }
    return WeComHistoryDetail(entry, _json(previous),
        _json(entry.row['state_json']), _undoReason(entry, rows));
  }

  Future<WeComHistoryDetail> _simulationDetail(
      Transaction txn, WeComHistoryEntry entry) async {
    final actions = await txn.query(entry.log.table,
        where: '$_where AND reverts_event_id = ?',
        whereArgs: [..._args, entry.id],
        limit: 1);
    final reason = entry.revertsId != null ||
            !const {'textExchange', 'scheduledCall'}.contains(entry.action)
        ? '反向或未知事件仅供查看'
        : actions.isNotEmpty
            ? '该模拟已有取消或拒绝记录'
            : null;
    Map<String, Object?> before = const {};
    if (entry.revertsId != null) {
      final parents = await txn.query(entry.log.table,
          where: '$_where AND event_id = ?',
          whereArgs: [..._args, entry.revertsId],
          limit: 1);
      if (parents.isNotEmpty) {
        before = {
          'event_type': parents.single['event_type'],
          ..._json(parents.single['payload_json'])
        };
      }
    }
    return WeComHistoryDetail(
        entry,
        before,
        {'event_type': entry.action, ..._json(entry.row['payload_json'])},
        reason);
  }

  String? _undoReason(
      WeComHistoryEntry entry, List<Map<String, Object?>> history) {
    if (entry.revertsId != null) return '反向修订仅供查看';
    final stack = <int>[];
    var consistent = true;
    for (final row in history) {
      final ref = row[entry.log.revert];
      if (ref == null) {
        stack.add(row[entry.log.id]! as int);
      } else if (stack.isNotEmpty && stack.last == ref) {
        stack.removeLast();
      } else {
        consistent = false;
      }
    }
    if (!consistent) return '历史撤销顺序不一致，仅供查看';
    if (!stack.contains(entry.id)) return '该修订已撤销';
    if (stack.last != entry.id) return '请先撤销同一记录的后续修订';
    return null;
  }

  Future<void> _requireAccess(DatabaseExecutor txn) async {
    if (!_canEdit()) throw StateError('Management session expired.');
    final rows = await txn.query(WeComOverlaySchema.datasetActivationsTable,
        orderBy: 'activation_id DESC', limit: 1);
    final active = rows.firstOrNull;
    if (active == null ||
        active['dataset_id'] != _base.datasetId ||
        active['scene_id'] != _overlay.sceneId ||
        active['current_corp_id'] != _scope.corporationId ||
        active['current_user_id'] != _scope.userId ||
        !_canEdit()) {
      throw StateError('The active identity, dataset or scene changed.');
    }
  }

  Map<String, Object?> _json(Object? text) =>
      Map<String, Object?>.from(jsonDecode(text! as String) as Map);
}
