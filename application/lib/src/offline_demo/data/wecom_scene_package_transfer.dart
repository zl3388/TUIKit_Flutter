import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import 'wecom_restricted_export_service.dart';
import 'wecom_scene_package.dart';
import 'wecom_scene_service.dart';

class WeComScenePackageTransfer {
  const WeComScenePackageTransfer({
    required WeComSceneService scenes,
    required Directory baseDirectory,
    required String overlayPath,
    required Directory scratchRoot,
    WeComExportFileAccess fileAccess = const PlatformWeComExportFileAccess(),
    Future<File?> Function() pickImport = _pickImport,
  })  : _scenes = scenes,
        _baseDirectory = baseDirectory,
        _overlayPath = overlayPath,
        _scratchRoot = scratchRoot,
        _fileAccess = fileAccess,
        _pickFile = pickImport;

  final WeComSceneService _scenes;
  final Directory _baseDirectory;
  final String _overlayPath;
  final Directory _scratchRoot;
  final WeComExportFileAccess _fileAccess;
  final Future<File?> Function() _pickFile;

  Future<bool> export() async {
    final text = await _scenes.exportPackage();
    await _scratchRoot.create(recursive: true);
    final scratch = await _scratchRoot.createTemp('scene-');
    String? destination;
    var published = false;
    try {
      final file = File(p.join(scratch.path, 'scene.json'));
      await file.writeAsString(text, flush: true);
      await _scenes.validateAccess();
      destination = await _fileAccess
          .choose('tui-scene-${_scenes.datasetId.substring(0, 8)}.json');
      if (destination == null) return false;
      await _scenes.validateAccess();
      validateWeComExportDestination(destination,
          baseDirectory: _baseDirectory,
          overlayPath: _overlayPath,
          extension: '.json');
      await _fileAccess.write(file, destination);
      published = true;
      return true;
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

  Future<WeComOverlayScene?> import() async {
    await _scenes.validateAccess();
    final file = await _pickFile();
    if (file == null) return null;
    await _scenes.validateAccess();
    if (await file.length() > WeComScenePackage.maxBytes) {
      throw const WeComScenePackageException(WeComScenePackageIssue.invalid);
    }
    final bytes = await file
        .openRead(0, WeComScenePackage.maxBytes + 1)
        .fold<BytesBuilder>(
            BytesBuilder(copy: false), (buffer, chunk) => buffer..add(chunk));
    if (bytes.length > WeComScenePackage.maxBytes) {
      throw const WeComScenePackageException(WeComScenePackageIssue.invalid);
    }
    String text;
    try {
      text = utf8.decode(bytes.takeBytes());
    } on FormatException {
      throw const WeComScenePackageException(WeComScenePackageIssue.invalid);
    }
    return _scenes.importPackage(text);
  }

  static Future<File?> _pickImport() async {
    final result = await FilePicker.platform.pickFiles(
        dialogTitle: '导入项目场景包',
        type: FileType.custom,
        allowedExtensions: ['json']);
    if (result == null) return null;
    final path = result.files.single.path;
    if (path == null) {
      throw const FileSystemException('No readable scene package');
    }
    return File(path);
  }
}
