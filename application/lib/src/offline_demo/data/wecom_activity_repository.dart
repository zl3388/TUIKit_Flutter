import '../domain/models.dart';
import '../domain/repositories.dart';
import '../domain/wecom_message_models.dart';
import 'wecom_advanced_message_codec.dart';
import 'wecom_message_repository.dart';

class WeComActivityRepository implements ActivityRepository {
  const WeComActivityRepository({
    required int currentUserId,
    required WeComMessageRepository messages,
    required ContactRepository contacts,
  })  : _currentUserId = currentUserId,
        _messages = messages,
        _contacts = contacts;

  final int _currentUserId;
  final WeComMessageRepository _messages;
  final ContactRepository _contacts;

  @override
  Set<ActivityFeature> get features => const {ActivityFeature.calls};

  @override
  Future<List<OfflineNotification>> listNotifications() async => const [];

  @override
  Future<List<OfflineAnnouncement>> listAnnouncements() async => const [];

  @override
  Future<List<OfflineCallRecord>> listCallRecords() async {
    final contacts = await _contacts.listContacts();
    final contactsById = {
      for (final contact in contacts) contact.id: contact.displayName,
    };
    final messages = await _messages.listCallMessages();
    final calls = <_CallProjection>[];
    final missedNotices = <_MissedNotice>[];

    for (final message in messages) {
      final content = message.content;
      if (content == null) {
        continue;
      }
      try {
        switch (message.contentType) {
          case 40:
            final decoded = decodeWeComCall(content);
            final peerId = _peerId(message, decoded.userIds);
            calls.add(
              _CallProjection(
                message: message,
                peerId: peerId,
                peerName: _peerName(peerId, contactsById),
                type: switch (decoded.mediaCode) {
                  2 => 'voice',
                  4 => 'video',
                  _ => 'unknown',
                },
                direction: message.senderId == _currentUserId
                    ? 'outgoing'
                    : 'incoming',
                durationSeconds: decoded.durationSeconds,
                status: switch (decoded.callType) {
                  1 => 'cancelled_self',
                  2 => 'rejected',
                  3 => 'cancelled_peer',
                  5 => 'connected',
                  _ => 'unknown',
                },
              ),
            );
          case 503:
            final decoded = decodeWeComStatusNotice(content);
            if (decoded.isMissedVoice) {
              missedNotices.add(
                _MissedNotice(
                  message: message,
                  peerId: decoded.peerUserId,
                  peerName: _peerNameFromNotice(
                    decoded.peerUserId,
                    decoded.title,
                    contactsById,
                  ),
                  sendTime: decoded.sendTime ?? message.sendTime,
                ),
              );
            }
          case 1018:
            final decoded = decodeWeComGroupCallNotice(content);
            calls.add(
              _CallProjection(
                message: message,
                peerId: null,
                peerName: '群语音通话',
                type: 'voice',
                direction: 'group',
                durationSeconds: decoded.durationSeconds,
                status: decoded.isMissed ? 'missed' : 'connected',
              ),
            );
        }
      } on FormatException {
        // Keep malformed rows out of the read-only projection.
      }
    }

    for (final notice in missedNotices) {
      final matchIndex = calls.indexWhere(
        (call) =>
            call.message.sendTime == notice.sendTime &&
            call.direction == 'incoming' &&
            call.status == 'cancelled_peer' &&
            (notice.peerId == null || call.peerId == notice.peerId),
      );
      if (matchIndex >= 0) {
        calls[matchIndex] = calls[matchIndex].copyWith(
          peerName: notice.peerName,
          status: 'missed',
        );
      } else {
        calls.add(
          _CallProjection(
            message: notice.message,
            peerId: notice.peerId,
            peerName: notice.peerName,
            type: 'voice',
            direction: 'incoming',
            durationSeconds: 0,
            status: 'missed',
          ),
        );
      }
    }

    calls.sort((left, right) {
      final time = right.message.sendTime.compareTo(left.message.sendTime);
      return time != 0
          ? time
          : right.message.messageId.compareTo(left.message.messageId);
    });
    return calls
        .map(
          (call) => OfflineCallRecord(
            id: call.message.messageId.toString(),
            peerName: call.peerName,
            type: call.type,
            direction: call.direction,
            startedAt: DateTime.fromMillisecondsSinceEpoch(
              call.message.sendTime * 1000,
              isUtc: true,
            ),
            durationSeconds: call.durationSeconds,
            status: call.status,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> markNotificationRead(String notificationId) {
    return Future.error(
      UnsupportedError('WeCom notification write-back is not authorized.'),
    );
  }

  int? _peerId(WeComMessageRecord message, List<int> participantIds) {
    if (message.conversationId.startsWith('S:')) {
      final ids = message.conversationId.substring(2).split('_');
      if (ids.length == 2) {
        for (final value in ids) {
          final id = int.tryParse(value);
          if (id != null && id != _currentUserId) {
            return id;
          }
        }
      }
    }
    for (final id in participantIds) {
      if (id != _currentUserId) {
        return id;
      }
    }
    return message.senderId == _currentUserId ? null : message.senderId;
  }

  String _peerName(int? peerId, Map<String, String> contactsById) {
    if (peerId == null) {
      return '未知联系人';
    }
    return contactsById[peerId.toString()] ?? peerId.toString();
  }

  String _peerNameFromNotice(
    int? peerId,
    String title,
    Map<String, String> contactsById,
  ) {
    if (peerId != null && contactsById[peerId.toString()] != null) {
      return contactsById[peerId.toString()]!;
    }
    final match = RegExp(r'^来自(.+)的未接语音通话$').firstMatch(title);
    return match?.group(1) ?? _peerName(peerId, contactsById);
  }
}

class _CallProjection {
  const _CallProjection({
    required this.message,
    required this.peerId,
    required this.peerName,
    required this.type,
    required this.direction,
    required this.durationSeconds,
    required this.status,
  });

  final WeComMessageRecord message;
  final int? peerId;
  final String peerName;
  final String type;
  final String direction;
  final int durationSeconds;
  final String status;

  _CallProjection copyWith({String? peerName, String? status}) {
    return _CallProjection(
      message: message,
      peerId: peerId,
      peerName: peerName ?? this.peerName,
      type: type,
      direction: direction,
      durationSeconds: durationSeconds,
      status: status ?? this.status,
    );
  }
}

class _MissedNotice {
  const _MissedNotice({
    required this.message,
    required this.peerId,
    required this.peerName,
    required this.sendTime,
  });

  final WeComMessageRecord message;
  final int? peerId;
  final String peerName;
  final int sendTime;
}
