import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as image_lib;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class LocalMediaAsset {
  const LocalMediaAsset({
    required this.relativePath,
    required this.fileName,
    required this.sizeBytes,
    this.thumbnailRelativePath,
    this.mimeType,
    this.width,
    this.height,
  });

  final String relativePath;
  final String? thumbnailRelativePath;
  final String fileName;
  final String? mimeType;
  final int sizeBytes;
  final int? width;
  final int? height;
}

class LocalMediaStore {
  LocalMediaStore._(this.rootDirectory);

  static const _thumbnailWidth = 320;

  final Directory rootDirectory;

  Directory get _filesDirectory =>
      Directory(p.join(rootDirectory.path, 'files'));

  Directory get _thumbnailsDirectory =>
      Directory(p.join(rootDirectory.path, 'thumbnails'));

  static Future<LocalMediaStore> initialize() async {
    final support = await getApplicationSupportDirectory();
    return forRoot(Directory(p.join(support.path, 'offline_demo_media')));
  }

  static Future<LocalMediaStore> forRoot(Directory root) async {
    final store = LocalMediaStore._(root);
    await store._filesDirectory.create(recursive: true);
    await store._thumbnailsDirectory.create(recursive: true);
    return store;
  }

  Future<LocalMediaAsset?> pickAndImport() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      withData: false,
      type: FileType.any,
    );
    final sourcePath = result?.files.single.path;
    if (sourcePath == null) {
      return null;
    }
    return importFile(File(sourcePath));
  }

  Future<LocalMediaAsset> importFile(File source) async {
    if (!await source.exists()) {
      throw ArgumentError.value(source.path, 'source', 'File does not exist.');
    }

    final sourceName = p.basename(source.path);
    final safeStem = _safeFileStem(p.basenameWithoutExtension(sourceName));
    final extension = p.extension(sourceName).toLowerCase();
    final token = DateTime.now().toUtc().microsecondsSinceEpoch;
    final storedName = '${token}_$safeStem$extension';
    final destination = File(p.join(_filesDirectory.path, storedName));
    await source.copy(destination.path);

    String? thumbnailRelativePath;
    int? width;
    int? height;
    if (_imageExtensions.contains(extension)) {
      final decoded = image_lib.decodeImage(await destination.readAsBytes());
      if (decoded != null) {
        width = decoded.width;
        height = decoded.height;
        final thumbnail = decoded.width > _thumbnailWidth
            ? image_lib.copyResize(decoded, width: _thumbnailWidth)
            : decoded;
        final thumbnailFile = File(
          p.join(_thumbnailsDirectory.path, '${token}_$safeStem.jpg'),
        );
        await thumbnailFile.writeAsBytes(
          image_lib.encodeJpg(thumbnail, quality: 82),
          flush: true,
        );
        thumbnailRelativePath = _relative(thumbnailFile.path);
      }
    }

    final stat = await destination.stat();
    return LocalMediaAsset(
      relativePath: _relative(destination.path),
      thumbnailRelativePath: thumbnailRelativePath,
      fileName: sourceName,
      mimeType: _mimeTypeFor(extension),
      sizeBytes: stat.size,
      width: width,
      height: height,
    );
  }

  File resolve(String relativePath) {
    final platformPath = relativePath.replaceAll('/', p.separator);
    final resolved = p.normalize(p.join(rootDirectory.path, platformPath));
    final root = p.normalize(rootDirectory.path);
    if (resolved != root && !p.isWithin(root, resolved)) {
      throw ArgumentError.value(
        relativePath,
        'relativePath',
        'Path escapes the local media directory.',
      );
    }
    return File(resolved);
  }

  Future<void> deleteAsset(LocalMediaAsset asset) async {
    await _deleteIfPresent(resolve(asset.relativePath));
    final thumbnail = asset.thumbnailRelativePath;
    if (thumbnail != null) {
      await _deleteIfPresent(resolve(thumbnail));
    }
  }

  Future<int> cleanupUnreferenced(Set<String> referencedRelativePaths) async {
    final normalizedReferences = referencedRelativePaths
        .map((path) => path.replaceAll('\\', '/'))
        .toSet();
    var deleted = 0;
    for (final directory in [_filesDirectory, _thumbnailsDirectory]) {
      await for (final entity in directory.list()) {
        if (entity is! File) {
          continue;
        }
        final relative = _relative(entity.path);
        if (!normalizedReferences.contains(relative)) {
          await entity.delete();
          deleted += 1;
        }
      }
    }
    return deleted;
  }

  String _relative(String absolutePath) =>
      p.relative(absolutePath, from: rootDirectory.path).replaceAll('\\', '/');

  static Future<void> _deleteIfPresent(File file) async {
    if (await file.exists()) {
      await file.delete();
    }
  }

  static String _safeFileStem(String value) {
    final sanitized = value
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    return sanitized.isEmpty ? 'media' : sanitized;
  }

  static String? _mimeTypeFor(String extension) => switch (extension) {
        '.jpg' || '.jpeg' => 'image/jpeg',
        '.png' => 'image/png',
        '.webp' => 'image/webp',
        '.gif' => 'image/gif',
        '.mp4' => 'video/mp4',
        '.mov' => 'video/quicktime',
        '.m4a' => 'audio/mp4',
        '.mp3' => 'audio/mpeg',
        '.pdf' => 'application/pdf',
        _ => null,
      };

  static const _imageExtensions = <String>{
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.gif',
  };
}
