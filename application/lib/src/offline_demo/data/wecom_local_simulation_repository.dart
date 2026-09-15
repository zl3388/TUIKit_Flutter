import 'dart:convert';

import 'wecom_identity_repository.dart';
import 'wecom_overlay_database.dart';
import 'wecom_overlay_schema.dart';

class WeComSimulatedExchange {
  const WeComSimulatedExchange({
    required this.eventKey,
    required this.conversationId,
    required this.senderProfileId,
    required this.text,
    required this.createdAt,
    required this.serverAcknowledgedAt,
    required this.peerReadAt,
    required this.automaticReplyAt,
    required this.automaticReplyText,
    this.peerProfileId,
  });

  final String eventKey;
  final String conversationId;
  final String senderProfileId;
  final String? peerProfileId;
  final String text;
  final DateTime createdAt;
  final DateTime serverAcknowledgedAt;
  final DateTime peerReadAt;
  final DateTime automaticReplyAt;
  final String automaticReplyText;

  DateTime? nextTransitionAfter(DateTime instant) {
    for (final transition in [
      serverAcknowledgedAt,
      if (peerProfileId != null) ...[
        peerReadAt,
        automaticReplyAt,
      ],
    ]) {
      if (transition.isAfter(instant)) {
        return transition;
      }
    }
    return null;
  }
}

class WeComLocalSimulationRepository {
  WeComLocalSimulationRepository({
    required WeComOverlayDatabase overlayDatabase,
    required WeComIdentityScope identityScope,
    DateTime Function()? now,
    this.serverAcknowledgementDelay = const Duration(milliseconds: 800),
    this.peerReadDelay = const Duration(milliseconds: 1800),
    this.automaticReplyDelay = const Duration(milliseconds: 3000),
  })  : _overlayDatabase = overlayDatabase,
        _identityScope = identityScope,
        _now = now ?? _utcNow;

  static const _textExchangeEventType = 'textExchange';
  static const _cancelExchangeEventType = 'cancelExchange';
  static const _automaticReplyText = '收到';

  final WeComOverlayDatabase _overlayDatabase;
  final WeComIdentityScope _identityScope;
  final DateTime Function() _now;
  final Duration serverAcknowledgementDelay;
  final Duration peerReadDelay;
  final Duration automaticReplyDelay;
  var _sequence = 0;

  DateTime get now => _now().toUtc();

  Future<WeComSimulatedExchange> enqueueTextExchange({
    required String conversationId,
    required String senderProfileId,
    required String text,
    String? peerProfileId,
  }) async {
    final body = text.trim();
    if (body.isEmpty) {
      throw ArgumentError.value(text, 'text', 'Message text cannot be empty.');
    }
    final createdAt = now;
    final eventKey = '${_identityScope.userId}-'
        '${createdAt.microsecondsSinceEpoch}-${_sequence++}';
    final payload = <String, Object?>{
      'version': 1,
      'conversationId': conversationId,
      'senderProfileId': senderProfileId,
      'peerProfileId': peerProfileId,
      'text': body,
      'serverAcknowledgedAtMicros':
          createdAt.add(serverAcknowledgementDelay).microsecondsSinceEpoch,
      'peerReadAtMicros': createdAt.add(peerReadDelay).microsecondsSinceEpoch,
      'automaticReplyAtMicros':
          createdAt.add(automaticReplyDelay).microsecondsSinceEpoch,
      'automaticReplyText': _automaticReplyText,
    };
    await _overlayDatabase.connection.insert(
      WeComOverlaySchema.simulationEventsTable,
      {
        'identity_corp_id': _identityScope.corporationId,
        'identity_user_id': _identityScope.userId,
        'event_key': eventKey,
        'event_type': _textExchangeEventType,
        'payload_json': jsonEncode(payload),
        'reverts_event_id': null,
        'created_at_micros': createdAt.microsecondsSinceEpoch,
      },
    );
    return _decodeExchange(
      eventKey: eventKey,
      createdAtMicros: createdAt.microsecondsSinceEpoch,
      payloadJson: jsonEncode(payload),
    );
  }

  Future<List<WeComSimulatedExchange>> listExchanges({
    String? conversationId,
  }) async {
    final rows = await _overlayDatabase.connection.query(
      WeComOverlaySchema.simulationEventsTable,
      columns: [
        'event_id',
        'event_key',
        'event_type',
        'payload_json',
        'reverts_event_id',
        'created_at_micros',
      ],
      where: 'identity_corp_id = ? AND identity_user_id = ? '
          'AND event_type IN (?, ?)',
      whereArgs: [
        _identityScope.corporationId,
        _identityScope.userId,
        _textExchangeEventType,
        _cancelExchangeEventType,
      ],
      orderBy: 'event_id ASC',
    );
    final revertedEventIds = rows
        .where((row) => row['event_type'] == _cancelExchangeEventType)
        .map((row) => row['reverts_event_id']! as int)
        .toSet();
    final exchanges = rows.where((row) {
      return row['event_type'] == _textExchangeEventType &&
          !revertedEventIds.contains(row['event_id']);
    }).map((row) {
      return _decodeExchange(
        eventKey: row['event_key']! as String,
        createdAtMicros: row['created_at_micros']! as int,
        payloadJson: row['payload_json']! as String,
      );
    }).where((exchange) {
      return conversationId == null ||
          exchange.conversationId == conversationId;
    }).toList(growable: false);
    return List.unmodifiable(exchanges);
  }

  Future<void> cancelTextExchange(String eventKey) async {
    final rows = await _overlayDatabase.connection.query(
      WeComOverlaySchema.simulationEventsTable,
      columns: ['event_id'],
      where: 'identity_corp_id = ? AND identity_user_id = ? '
          'AND event_key = ? AND event_type = ?',
      whereArgs: [
        _identityScope.corporationId,
        _identityScope.userId,
        eventKey,
        _textExchangeEventType,
      ],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw StateError('Overlay simulation event does not exist.');
    }
    final createdAt = now;
    await _overlayDatabase.connection.insert(
      WeComOverlaySchema.simulationEventsTable,
      {
        'identity_corp_id': _identityScope.corporationId,
        'identity_user_id': _identityScope.userId,
        'event_key': '$eventKey-cancel-${createdAt.microsecondsSinceEpoch}',
        'event_type': _cancelExchangeEventType,
        'payload_json': '{"version":1}',
        'reverts_event_id': rows.single['event_id']! as int,
        'created_at_micros': createdAt.microsecondsSinceEpoch,
      },
    );
  }

  WeComSimulatedExchange _decodeExchange({
    required String eventKey,
    required int createdAtMicros,
    required String payloadJson,
  }) {
    final value = jsonDecode(payloadJson);
    if (value is! Map<String, Object?> || value['version'] != 1) {
      throw const FormatException('Unsupported overlay simulation payload.');
    }
    return WeComSimulatedExchange(
      eventKey: eventKey,
      conversationId: _requiredString(value, 'conversationId'),
      senderProfileId: _requiredString(value, 'senderProfileId'),
      peerProfileId: _optionalString(value, 'peerProfileId'),
      text: _requiredString(value, 'text'),
      createdAt: _fromMicros(createdAtMicros),
      serverAcknowledgedAt:
          _fromMicros(_requiredInt(value, 'serverAcknowledgedAtMicros')),
      peerReadAt: _fromMicros(_requiredInt(value, 'peerReadAtMicros')),
      automaticReplyAt:
          _fromMicros(_requiredInt(value, 'automaticReplyAtMicros')),
      automaticReplyText: _requiredString(value, 'automaticReplyText'),
    );
  }

  static String _requiredString(Map<String, Object?> value, String key) {
    final field = value[key];
    if (field is! String || field.isEmpty) {
      throw FormatException('Overlay simulation payload has invalid $key.');
    }
    return field;
  }

  static String? _optionalString(Map<String, Object?> value, String key) {
    final field = value[key];
    if (field == null) {
      return null;
    }
    if (field is! String || field.isEmpty) {
      throw FormatException('Overlay simulation payload has invalid $key.');
    }
    return field;
  }

  static int _requiredInt(Map<String, Object?> value, String key) {
    final field = value[key];
    if (field is! int || field <= 0) {
      throw FormatException('Overlay simulation payload has invalid $key.');
    }
    return field;
  }

  static DateTime _fromMicros(int value) =>
      DateTime.fromMicrosecondsSinceEpoch(value, isUtc: true);

  static DateTime _utcNow() => DateTime.now().toUtc();
}
