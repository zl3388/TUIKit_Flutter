import 'dart:math';

import 'package:sqflite/sqflite.dart';

import 'wecom_active_dataset_runtime.dart';
import 'wecom_identity_repository.dart';
import 'wecom_overlay_database.dart';
import 'wecom_overlay_schema.dart';

class WeComOverlayScene {
  const WeComOverlayScene({
    required this.id,
    required this.name,
    required this.datasetId,
    required this.isSnapshot,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String datasetId;
  final bool isSnapshot;
  final DateTime createdAt;
}

class WeComSceneService {
  WeComSceneService({
    required WeComOverlayDatabase overlayDatabase,
    required WeComActiveDatasetResolver datasetResolver,
    required WeComIdentityScope identityScope,
    required this.datasetId,
    required bool Function() canEdit,
  })  : _overlay = overlayDatabase,
        _resolver = datasetResolver,
        _scope = identityScope,
        _canEdit = canEdit;

  final WeComOverlayDatabase _overlay;
  final WeComActiveDatasetResolver _resolver;
  final WeComIdentityScope _scope;
  final String datasetId;
  final bool Function() _canEdit;
  final _random = Random.secure();

  String get activeSceneId => _overlay.sceneId;

  Future<void> ensureDefaultScene() async {
    await _overlay.connection.insert(
      WeComOverlaySchema.scenesTable,
      _metadata('default', '默认场景', datasetId, false),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<List<WeComOverlayScene>> list() async {
    final rows = await _overlay.connection.rawQuery(
      'SELECT s.*, COALESCE((SELECT a.dataset_id FROM '
      '${WeComOverlaySchema.datasetActivationsTable} a '
      'WHERE a.scene_id = s.scene_id AND a.current_corp_id = s.identity_corp_id '
      'AND a.current_user_id = s.identity_user_id '
      'ORDER BY a.activation_id DESC LIMIT 1), s.dataset_id) AS latest_dataset '
      'FROM ${WeComOverlaySchema.scenesTable} s '
      'WHERE s.identity_corp_id = ? AND s.identity_user_id = ? '
      'ORDER BY s.created_at_micros DESC, s.scene_id',
      [_scope.corporationId, _scope.userId],
    );
    return List.unmodifiable(rows.map(_decode));
  }

  Future<WeComOverlayScene> create(
    String name, {
    String? copyFromSceneId,
  }) async {
    _requireAdmin();
    final title = _validateName(name);
    final source = copyFromSceneId == null
        ? null
        : (await list())
            .where((item) => item.id == copyFromSceneId)
            .firstOrNull;
    if (copyFromSceneId != null && source == null) {
      throw StateError('Scene does not belong to the current identity.');
    }
    final base = source?.datasetId ?? datasetId;
    await _validateBase(base);
    return _overlay.connection.transaction((txn) async {
      _requireAdmin();
      await _requireActive(txn);
      final id = _newId();
      if (source != null) {
        await _copyLogs(txn, source.id, id);
      }
      final metadata = _metadata(id, title, base, false);
      await txn.insert(WeComOverlaySchema.scenesTable, metadata);
      await _activate(txn, id, base);
      return _decode({...metadata, 'latest_dataset': base});
    });
  }

  Future<WeComOverlayScene> saveSnapshot(String name) async {
    _requireAdmin();
    final title = _validateName(name);
    await _validateBase(datasetId);
    return _overlay.connection.transaction((txn) async {
      _requireAdmin();
      await _requireActive(txn);
      return _snapshot(txn, title);
    });
  }

  Future<void> switchScene(String sceneId) async {
    _requireAdmin();
    final scene =
        (await list()).where((item) => item.id == sceneId).firstOrNull;
    if (scene == null || scene.isSnapshot) {
      throw StateError(
          'An editable scene of the current identity is required.');
    }
    await _validateBase(scene.datasetId);
    await _overlay.connection.transaction((txn) async {
      _requireAdmin();
      await _requireActive(txn);
      if (scene.id != activeSceneId) {
        await _activate(txn, scene.id, scene.datasetId);
      }
    });
  }

  Future<void> reset(String name) async {
    _requireAdmin();
    final title = _validateName(name);
    await _validateBase(datasetId);
    await _overlay.connection.transaction((txn) async {
      _requireAdmin();
      await _requireActive(txn);
      await _snapshot(
          txn, '重置前 ${title.length > 56 ? title.substring(0, 56) : title}');
      final id = _newId();
      await txn.insert(
        WeComOverlaySchema.scenesTable,
        _metadata(id, title, datasetId, false),
      );
      await _activate(txn, id, datasetId);
    });
  }

  Future<WeComOverlayScene> _snapshot(Transaction txn, String name) async {
    final id = _newId();
    await _copyLogs(txn, activeSceneId, id);
    final metadata = _metadata(id, name, datasetId, true);
    await txn.insert(WeComOverlaySchema.scenesTable, metadata);
    return _decode({...metadata, 'latest_dataset': datasetId});
  }

  Future<void> _copyLogs(Transaction txn, String source, String target) async {
    // Preserve logical message keys, but remap revision references to the copy.
    for (final log in [
      (
        WeComOverlaySchema.operationsTable,
        'revision_id',
        'reverts_revision_id'
      ),
      (
        WeComOverlaySchema.simulationEventsTable,
        'event_id',
        'reverts_event_id'
      ),
      (WeComOverlaySchema.messageEditsTable, 'edit_id', 'reverts_edit_id'),
    ]) {
      final rows = await txn.query(
        log.$1,
        where: 'identity_corp_id = ? AND identity_user_id = ? AND scene_id = ?',
        whereArgs: [_scope.corporationId, _scope.userId, source],
        orderBy: log.$2,
      );
      final ids = <int, int>{};
      for (final row in rows) {
        final values = Map<String, Object?>.from(row);
        final oldId = values.remove(log.$2)! as int;
        final revertedId = values[log.$3] as int?;
        if (revertedId != null) {
          final copiedId = ids[revertedId];
          if (copiedId == null) {
            throw StateError('Scene revision reference is invalid.');
          }
          values[log.$3] = copiedId;
        }
        values['scene_id'] = target;
        ids[oldId] = await txn.insert(log.$1, values);
      }
    }
  }

  Future<void> _validateBase(String base) async {
    final identity = (await _resolver.inspectIdentity(
      base,
      selectedCorporationId: _scope.corporationId,
    ))
        .selected;
    if (identity?.userId != _scope.userId) {
      throw StateError(
          'Scene base package does not match the current identity.');
    }
  }

  Future<void> _requireActive(DatabaseExecutor executor) async {
    final rows = await executor.query(
      WeComOverlaySchema.datasetActivationsTable,
      orderBy: 'activation_id DESC',
      limit: 1,
    );
    final active = rows.firstOrNull;
    if (active == null ||
        active['scene_id'] != activeSceneId ||
        active['dataset_id'] != datasetId ||
        active['current_corp_id'] != _scope.corporationId ||
        active['current_user_id'] != _scope.userId) {
      throw StateError(
          'The active scene or identity changed; reload before editing.');
    }
  }

  Future<void> _activate(Transaction txn, String id, String base) => txn.insert(
        WeComOverlaySchema.datasetActivationsTable,
        {
          'previous_dataset_id': datasetId,
          'dataset_id': base,
          'scene_id': id,
          'merge_id': null,
          'current_corp_id': _scope.corporationId,
          'current_user_id': _scope.userId,
          'created_at_micros': DateTime.now().toUtc().microsecondsSinceEpoch,
        },
      );

  Map<String, Object?> _metadata(
          String id, String name, String base, bool snapshot) =>
      {
        'scene_id': id,
        'identity_corp_id': _scope.corporationId,
        'identity_user_id': _scope.userId,
        'name': name,
        'kind': snapshot ? 'snapshot' : 'scene',
        'dataset_id': base,
        'created_at_micros': DateTime.now().toUtc().microsecondsSinceEpoch,
      };

  WeComOverlayScene _decode(Map<String, Object?> row) => WeComOverlayScene(
        id: row['scene_id']! as String,
        name: row['name']! as String,
        datasetId: row['latest_dataset']! as String,
        isSnapshot: row['kind'] == 'snapshot',
        createdAt: DateTime.fromMicrosecondsSinceEpoch(
            row['created_at_micros']! as int,
            isUtc: true),
      );

  String _newId() => List.generate(
      16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  String _validateName(String value) {
    final name = value.trim();
    if (name.isEmpty || name.length > 60) {
      throw ArgumentError.value(value, 'name', 'Use 1 to 60 characters.');
    }
    return name;
  }

  void _requireAdmin() {
    if (!_canEdit()) {
      throw StateError('An active management session is required.');
    }
  }
}
