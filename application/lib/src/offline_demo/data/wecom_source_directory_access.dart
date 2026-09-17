import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

class WeComSelectedSourceDirectory {
  const WeComSelectedSourceDirectory({
    required this.locator,
    required this.directory,
  });

  final String locator;
  final Directory directory;
}

abstract interface class WeComSourceDirectoryResolver {
  Future<Directory> resolve(String locator);
}

abstract interface class WeComSourceDirectoryAccess
    implements WeComSourceDirectoryResolver {
  Future<WeComSelectedSourceDirectory?> choose();
}

class FileSystemWeComSourceDirectoryResolver
    implements WeComSourceDirectoryResolver {
  const FileSystemWeComSourceDirectoryResolver();

  @override
  Future<Directory> resolve(String locator) async => Directory(locator);
}

class PlatformWeComSourceDirectoryAccess implements WeComSourceDirectoryAccess {
  const PlatformWeComSourceDirectoryAccess({
    MethodChannel channel = const MethodChannel(_channelName),
  }) : _channel = channel;

  static const _channelName = 'offline_demo/source_directory';
  final MethodChannel _channel;

  @override
  Future<WeComSelectedSourceDirectory?> choose() async {
    final String? locator;
    if (Platform.isAndroid) {
      locator = await _channel.invokeMethod<String>('pickDirectory');
    } else {
      locator = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择账号目录或 Data 目录',
      );
    }
    if (locator == null) {
      return null;
    }
    return WeComSelectedSourceDirectory(
      locator: locator,
      directory: await resolve(locator),
    );
  }

  @override
  Future<Directory> resolve(String locator) async {
    if (!locator.startsWith('content://')) {
      return Directory(locator);
    }
    if (!Platform.isAndroid) {
      throw FileSystemException(
          'Android document tree is unavailable', locator);
    }
    final path = await _channel.invokeMethod<String>(
      'materializeDirectory',
      {'uri': locator},
    );
    if (path == null || path.isEmpty) {
      throw FileSystemException('Failed to materialize document tree', locator);
    }
    return Directory(path);
  }
}
