import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'wecom_database_package.dart';
import 'wecom_database_package_exporter.dart';
import 'wecom_identity_repository.dart';
import 'wecom_overlay_database.dart';
import 'wecom_overlay_schema.dart';

abstract interface class WeComExportFileAccess {
  Future<String?> choose(String fileName);
  Future<void> write(File archive, String destination);
  Future<void> discard(String destination);
}

class PlatformWeComExportFileAccess implements WeComExportFileAccess {
  const PlatformWeComExportFileAccess();

  static const _channel = MethodChannel('offline_demo/export_file');

  @override
  Future<String?> choose(String fileName) => Platform.isAndroid
      ? _channel.invokeMethod<String>('choose', {'fileName': fileName})
      : FilePicker.platform.saveFile(
          dialogTitle: '保存受限数据库副本',
          fileName: fileName,
          type: FileType.custom,
          allowedExtensions: ['zip'],
        );

  @override
  Future<void> write(File archive, String destination) async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('write', {
        'path': archive.path,
        'uri': destination,
      });
    } else {
      await archive.copy(destination);
    }
  }

  @override
  Future<void> discard(String destination) async {
    // Android CREATE_DOCUMENT creates an empty file before returning the URI.
    // Desktop save dialogs do not create files; never remove an existing one.
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('discard', {'uri': destination});
    }
  }
}

class WeComRestrictedExportService {
  const WeComRestrictedExportService({
    required WeComDatabasePackageExporter exporter,
    required WeComImportedPackage basePackage,
    required WeComOverlayDatabase overlayDatabase,
    required WeComIdentityScope identityScope,
    required Directory scratchRoot,
    required bool Function() canExport,
    WeComExportFileAccess fileAccess = const PlatformWeComExportFileAccess(),
  })  : _exporter = exporter,
        _base = basePackage,
        _overlay = overlayDatabase,
        _scope = identityScope,
        _scratchRoot = scratchRoot,
        _canExport = canExport,
        _fileAccess = fileAccess;

  final WeComDatabasePackageExporter _exporter;
  final WeComImportedPackage _base;
  final WeComOverlayDatabase _overlay;
  final WeComIdentityScope _scope;
  final Directory _scratchRoot;
  final bool Function() _canExport;
  final WeComExportFileAccess _fileAccess;

  /// Returns the applied revision count, or null when the save dialog is cancelled.
  Future<int?> export() async {
    await _requireCurrent();
    await _scratchRoot.create(recursive: true);
    final scratch = await _scratchRoot.createTemp('export-');
    String? destination;
    var published = false;
    try {
      final copy = await _exporter.export(
        basePackage: _base,
        overlayDatabase: _overlay,
        identityScope: _scope,
        destinationDirectory: Directory(p.join(scratch.path, 'Data')),
      );
      final archive = File(p.join(scratch.path, 'restricted-copy.zip'));
      await _createArchive(
          copy.directory.path, archive.path, copy.files.keys.toList()..sort());
      await _requireCurrent();
      destination = await _fileAccess.choose(
        'wecom-copy-${copy.datasetId.substring(0, 8)}.zip',
      );
      if (destination == null) return null;
      await _requireCurrent();
      if (!destination.startsWith('content://')) {
        final path = p.normalize(p.absolute(destination));
        final basePath = p.normalize(p.absolute(_base.directory.path));
        if (p.isWithin(basePath, path) ||
            p.equals(basePath, path) ||
            p.equals(path, p.normalize(p.absolute(_overlay.path)))) {
          throw const WeComExportException(
            WeComExportIssueCode.overlappingPaths,
            'Export destination overlaps private application data',
          );
        }
        if (p.extension(path).toLowerCase() != '.zip') {
          throw const FormatException('Choose a ZIP destination');
        }
      }
      await _fileAccess.write(archive, destination);
      published = true;
      return copy.appliedRevisionCount;
    } finally {
      try {
        if (destination != null && !published) {
          await _fileAccess.discard(destination);
        }
      } finally {
        await scratch.delete(recursive: true);
      }
    }
  }

  Future<void> _requireCurrent() async {
    if (!_canExport()) {
      throw StateError('An active management session is required.');
    }
    final rows = await _overlay.connection.query(
      WeComOverlaySchema.datasetActivationsTable,
      orderBy: 'activation_id DESC',
      limit: 1,
    );
    final active = rows.firstOrNull;
    if (active == null ||
        active['dataset_id'] != _base.datasetId ||
        active['scene_id'] != _overlay.sceneId ||
        active['current_corp_id'] != _scope.corporationId ||
        active['current_user_id'] != _scope.userId) {
      throw StateError('The active dataset, identity or scene changed.');
    }
    if (!_canExport()) {
      throw StateError('The management session ended during export.');
    }
  }
}

Future<void> _createArchive(
        String dataPath, String archivePath, List<String> names) =>
    Isolate.run(() async {
      final encoder = ZipFileEncoder();
      encoder.create(archivePath);
      try {
        for (final name in names) {
          await encoder.addFile(File(p.join(dataPath, name)), 'Data/$name');
        }
      } finally {
        await encoder.close();
      }
    });
