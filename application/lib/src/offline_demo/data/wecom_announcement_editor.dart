import 'wecom_announcement_repository.dart';
import 'wecom_overlay_command_service.dart';

class WeComAnnouncementEdit {
  WeComAnnouncementEdit._({
    required this.revisionId,
    required this.announcementId,
    required this.previousTitle,
    required this.previousSummary,
  });

  final int revisionId;
  final int announcementId;
  final String previousTitle;
  final String previousSummary;
  bool _undone = false;
}

class WeComAnnouncementEditor {
  const WeComAnnouncementEditor({
    required this.datasetId,
    required WeComAnnouncementRepository announcements,
    required WeComOverlayCommandService commands,
  })  : _announcements = announcements,
        _commands = commands;

  final String datasetId;
  final WeComAnnouncementRepository _announcements;
  final WeComOverlayCommandService _commands;

  Future<WeComAnnouncementEdit> updateContent({
    required String announcementId,
    required String title,
    required String summary,
  }) async {
    final numericId = int.tryParse(announcementId);
    if (numericId == null) {
      throw ArgumentError.value(
        announcementId,
        'announcementId',
        'Must be an integer',
      );
    }
    final announcements = await _announcements.listAnnouncements();
    final current =
        announcements.where((item) => item.id == announcementId).firstOrNull;
    if (current == null) {
      throw StateError('Announcement does not exist: $announcementId');
    }
    if (current.title == title && current.summary == summary) {
      throw const WeComAnnouncementNoChangesException();
    }
    final revisionId = await _commands.upsert(
      datasetId: datasetId,
      databaseName: WeComAnnouncementRepository.databaseName,
      tableName: WeComAnnouncementRepository.tableName,
      rowKey: {'id': numericId},
      values: {'subject': title, 'summary': summary},
    );
    return WeComAnnouncementEdit._(
      revisionId: revisionId,
      announcementId: numericId,
      previousTitle: current.title,
      previousSummary: current.summary,
    );
  }

  Future<void> undo(WeComAnnouncementEdit edit) async {
    if (edit._undone) {
      throw StateError('This announcement edit was already undone.');
    }
    await _commands.upsert(
      datasetId: datasetId,
      databaseName: WeComAnnouncementRepository.databaseName,
      tableName: WeComAnnouncementRepository.tableName,
      rowKey: {'id': edit.announcementId},
      values: {
        'subject': edit.previousTitle,
        'summary': edit.previousSummary,
      },
      revertsRevisionId: edit.revisionId,
    );
    edit._undone = true;
  }
}

class WeComAnnouncementNoChangesException implements Exception {
  const WeComAnnouncementNoChangesException();
}
