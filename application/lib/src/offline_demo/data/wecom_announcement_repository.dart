import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../domain/models.dart';
import 'wecom_identity_repository.dart';
import 'wecom_overlay_database.dart';
import 'wecom_overlay_schema.dart';

class WeComAnnouncementRepository {
  const WeComAnnouncementRepository({
    required this.datasetId,
    required this.identityScope,
    required Database baseDatabase,
    required WeComOverlayDatabase overlayDatabase,
  })  : _baseDatabase = baseDatabase,
        _overlayDatabase = overlayDatabase;

  static const databaseName = 'forever_store.db';
  static const tableName = 'announce_table';

  final String datasetId;
  final WeComIdentityScope identityScope;
  final Database _baseDatabase;
  final WeComOverlayDatabase _overlayDatabase;

  Future<List<OfflineAnnouncement>> listAnnouncements() async {
    final rows = await _baseDatabase.query(
      tableName,
      columns: const [
        'id',
        'time',
        'subject',
        'summary',
        'attachment_count',
        'sender_name',
        'is_read',
      ],
    );
    final states = <int, _AnnouncementState>{};
    for (final row in rows) {
      final state = _AnnouncementState.fromRow(row);
      states[state.id] = state;
    }

    final operations = await _overlayDatabase.connection.query(
      WeComOverlaySchema.operationsTable,
      columns: const ['row_key_json', 'operation', 'values_json'],
      where: 'dataset_id = ? AND identity_corp_id = ? '
          'AND identity_user_id = ? AND database_name = ? AND table_name = ?',
      whereArgs: [
        datasetId,
        identityScope.corporationId,
        identityScope.userId,
        databaseName,
        tableName,
      ],
      orderBy: 'revision_id',
    );
    for (final operation in operations) {
      final rowKey = _decodeObject(
        operation['row_key_json'],
        'row_key_json',
      );
      final id = rowKey['id'];
      if (rowKey.length != 1 || id is! int) {
        throw const FormatException('Invalid announce_table overlay row key');
      }
      final state = states[id];
      if (state == null) {
        throw StateError('Announcement overlay targets a missing row: $id');
      }
      if (operation['operation'] != 'upsert') {
        throw UnsupportedError('Announcement deletion is not supported.');
      }
      state.apply(
        _decodeObject(operation['values_json'], 'values_json'),
      );
    }

    final announcements =
        states.values.map((state) => state.toModel()).toList(growable: false)
          ..sort((left, right) {
            final byTime = right.publishedAt.compareTo(left.publishedAt);
            if (byTime != 0) {
              return byTime;
            }
            return int.parse(right.id).compareTo(int.parse(left.id));
          });
    return List<OfflineAnnouncement>.unmodifiable(announcements);
  }

  Map<String, Object?> _decodeObject(Object? source, String fieldName) {
    if (source is! String) {
      throw FormatException('$fieldName must be a JSON object');
    }
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw FormatException('$fieldName must be a JSON object');
    }
    return Map<String, Object?>.from(decoded);
  }
}

class _AnnouncementState {
  _AnnouncementState({
    required this.id,
    required this.time,
    required this.subject,
    required this.summary,
    required this.attachmentCount,
    required this.senderName,
    required this.isRead,
  });

  factory _AnnouncementState.fromRow(Map<String, Object?> row) {
    return _AnnouncementState(
      id: _requiredInt(row['id'], 'id'),
      time: _requiredInt(row['time'], 'time'),
      subject: _requiredString(row['subject'], 'subject'),
      summary: _requiredString(row['summary'], 'summary'),
      attachmentCount:
          _requiredInt(row['attachment_count'], 'attachment_count'),
      senderName: _requiredString(row['sender_name'], 'sender_name'),
      isRead: _requiredInt(row['is_read'], 'is_read') != 0,
    );
  }

  final int id;
  final int time;
  String subject;
  String summary;
  final int attachmentCount;
  final String senderName;
  final bool isRead;

  void apply(Map<String, Object?> values) {
    final unsupported = values.keys.toSet().difference(
      const {'subject', 'summary'},
    );
    if (unsupported.isNotEmpty) {
      throw UnsupportedError(
        'Unsupported announcement overlay fields: ${unsupported.join(', ')}',
      );
    }
    if (values.containsKey('subject')) {
      subject = _requiredString(values['subject'], 'subject');
    }
    if (values.containsKey('summary')) {
      summary = _requiredString(values['summary'], 'summary');
    }
  }

  OfflineAnnouncement toModel() {
    return OfflineAnnouncement(
      id: id.toString(),
      title: subject,
      summary: summary,
      authorName: senderName,
      publishedAt: DateTime.fromMillisecondsSinceEpoch(
        time * 1000,
        isUtc: true,
      ),
      attachmentCount: attachmentCount,
      isRead: isRead,
    );
  }
}

int _requiredInt(Object? value, String fieldName) {
  if (value is! int) {
    throw FormatException('$fieldName must be an integer');
  }
  return value;
}

String _requiredString(Object? value, String fieldName) {
  if (value is! String) {
    throw FormatException('$fieldName must be a string');
  }
  return value;
}
