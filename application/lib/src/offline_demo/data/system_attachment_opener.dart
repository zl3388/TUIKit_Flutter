import 'dart:io';

import 'package:open_file/open_file.dart';

import '../domain/models.dart';
import '../domain/repositories.dart';

class SystemAttachmentOpener implements AttachmentOpener {
  const SystemAttachmentOpener();

  @override
  Future<void> open(OfflineAttachment attachment) async {
    final path = attachment.localPath;
    if (!attachment.isAvailable || path == null || !await File(path).exists()) {
      throw StateError('The attachment is not available offline.');
    }
    final result = await OpenFile.open(path);
    if (result.type != ResultType.done) {
      throw StateError(result.message);
    }
  }
}
