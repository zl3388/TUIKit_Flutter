import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

enum AdminMode { user, admin }

enum AdminAuthenticationResult {
  granted,
  invalid,
  locked,
  requiresSetup,
  invalidInput,
}

class AdminPinCredential {
  const AdminPinCredential({
    required this.saltHex,
    required this.digestHex,
  });

  final String saltHex;
  final String digestHex;

  Map<String, Object> toJson() => {
        'version': 1,
        'salt': saltHex,
        'digest': digestHex,
      };

  factory AdminPinCredential.fromJson(Map<String, Object?> json) {
    final version = json['version'];
    final salt = json['salt'];
    final digest = json['digest'];
    if (version != 1 ||
        salt is! String ||
        !_isLowerHex(salt, 32) ||
        digest is! String ||
        !_isLowerHex(digest, 64)) {
      throw const FormatException('Admin PIN credential is malformed');
    }
    return AdminPinCredential(saltHex: salt, digestHex: digest);
  }
}

abstract interface class AdminCredentialStore {
  Future<AdminPinCredential?> load();

  Future<void> save(AdminPinCredential credential);
}

class FileAdminCredentialStore implements AdminCredentialStore {
  const FileAdminCredentialStore(this.file);

  final File file;

  @override
  Future<AdminPinCredential?> load() async {
    if (!await file.exists()) {
      return null;
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Admin PIN credential must be an object');
    }
    return AdminPinCredential.fromJson(decoded);
  }

  @override
  Future<void> save(AdminPinCredential credential) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(credential.toJson()), flush: true);
  }
}

class AdminAccessController extends ChangeNotifier {
  AdminAccessController({
    required AdminCredentialStore credentialStore,
    String buildPin = '',
    DateTime Function()? now,
    Duration lockoutDuration = const Duration(seconds: 60),
    Duration backgroundTimeout = const Duration(minutes: 10),
  })  : _credentialStore = credentialStore,
        _buildPin = buildPin,
        _now = now ?? DateTime.now,
        _lockoutDuration = lockoutDuration,
        _backgroundTimeout = backgroundTimeout;

  static const maxFailedAttempts = 5;

  final AdminCredentialStore _credentialStore;
  final String _buildPin;
  final DateTime Function() _now;
  final Duration _lockoutDuration;
  final Duration _backgroundTimeout;

  AdminPinCredential? _credential;
  AdminMode _mode = AdminMode.user;
  DateTime? _lockedUntil;
  DateTime? _backgroundedAt;
  var _failedAttempts = 0;
  var _initialized = false;

  AdminMode get mode => _mode;
  bool get isAdmin => _mode == AdminMode.admin;
  bool get isInitialized => _initialized;
  bool get requiresPinSetup =>
      _initialized && _credential == null && _buildPin.isEmpty;
  int get failedAttempts => _failedAttempts;

  Duration get lockoutRemaining {
    final until = _lockedUntil;
    if (until == null) {
      return Duration.zero;
    }
    final remaining = until.difference(_now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _credential = await _credentialStore.load();
    _initialized = true;
    notifyListeners();
  }

  Future<AdminAuthenticationResult> setupPin(String pin) async {
    _requireInitialized();
    if (!requiresPinSetup) {
      throw StateError('An admin PIN is already configured');
    }
    if (pin.isEmpty) {
      return AdminAuthenticationResult.invalidInput;
    }
    final credential = _createCredential(pin);
    await _credentialStore.save(credential);
    _credential = credential;
    _grantAccess();
    return AdminAuthenticationResult.granted;
  }

  Future<AdminAuthenticationResult> authenticate(String pin) async {
    _requireInitialized();
    _refreshExpiredLockout();
    if (_lockedUntil != null) {
      return AdminAuthenticationResult.locked;
    }
    if (requiresPinSetup) {
      return AdminAuthenticationResult.requiresSetup;
    }
    if (pin.isEmpty) {
      return AdminAuthenticationResult.invalidInput;
    }
    final credential = _credential;
    final valid = credential == null
        ? _constantTimeEquals(_digestText(pin), _digestText(_buildPin))
        : _constantTimeEquals(
            _digestPin(pin, credential.saltHex),
            credential.digestHex,
          );
    if (valid) {
      _grantAccess();
      return AdminAuthenticationResult.granted;
    }
    _failedAttempts += 1;
    if (_failedAttempts >= maxFailedAttempts) {
      _lockedUntil = _now().add(_lockoutDuration);
      _failedAttempts = 0;
    }
    notifyListeners();
    return _lockedUntil == null
        ? AdminAuthenticationResult.invalid
        : AdminAuthenticationResult.locked;
  }

  void exitAdminMode() {
    if (!isAdmin) {
      return;
    }
    _mode = AdminMode.user;
    _backgroundedAt = null;
    notifyListeners();
  }

  void recordBackgrounded() {
    if (isAdmin) {
      _backgroundedAt ??= _now();
    }
  }

  void resumeFromBackground() {
    final backgroundedAt = _backgroundedAt;
    _backgroundedAt = null;
    if (!isAdmin || backgroundedAt == null) {
      return;
    }
    if (_now().difference(backgroundedAt) >= _backgroundTimeout) {
      exitAdminMode();
    }
  }

  void _grantAccess() {
    _failedAttempts = 0;
    _lockedUntil = null;
    _backgroundedAt = null;
    _mode = AdminMode.admin;
    notifyListeners();
  }

  void _refreshExpiredLockout() {
    final lockedUntil = _lockedUntil;
    if (lockedUntil != null && !_now().isBefore(lockedUntil)) {
      _lockedUntil = null;
      _failedAttempts = 0;
      notifyListeners();
    }
  }

  void _requireInitialized() {
    if (!_initialized) {
      throw StateError('Admin access has not been initialized');
    }
  }
}

AdminPinCredential _createCredential(String pin) {
  final random = Random.secure();
  final salt = List<int>.generate(16, (_) => random.nextInt(256));
  final saltHex = _hex(salt);
  return AdminPinCredential(
    saltHex: saltHex,
    digestHex: _digestPin(pin, saltHex),
  );
}

String _digestPin(String pin, String saltHex) {
  return sha256
      .convert([..._decodeHex(saltHex), ...utf8.encode(pin)]).toString();
}

String _digestText(String value) =>
    sha256.convert(utf8.encode(value)).toString();

bool _constantTimeEquals(String left, String right) {
  if (left.length != right.length) {
    return false;
  }
  var difference = 0;
  for (var index = 0; index < left.length; index += 1) {
    difference |= left.codeUnitAt(index) ^ right.codeUnitAt(index);
  }
  return difference == 0;
}

String _hex(List<int> bytes) =>
    bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();

List<int> _decodeHex(String value) => [
      for (var index = 0; index < value.length; index += 2)
        int.parse(value.substring(index, index + 2), radix: 16),
    ];

bool _isLowerHex(String value, int length) {
  return value.length == length && RegExp(r'^[0-9a-f]+$').hasMatch(value);
}
