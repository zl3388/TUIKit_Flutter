import 'dart:io';

import 'package:application/src/offline_demo/state/admin_access_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('persists a salted digest and authenticates after reload', () async {
    final root = await Directory.systemTemp.createTemp('tui_admin_access_');
    addTearDown(() => root.delete(recursive: true));
    final file = File(p.join(root.path, 'admin_access.json'));
    final first = AdminAccessController(
      credentialStore: FileAdminCredentialStore(file),
    );
    await first.initialize();

    expect(first.requiresPinSetup, isTrue);
    expect(
      await first.setupPin('2468'),
      AdminAuthenticationResult.granted,
    );
    final persisted = await file.readAsString();
    expect(persisted, isNot(contains('2468')));
    expect(persisted, contains('"salt"'));
    expect(persisted, contains('"digest"'));
    first.dispose();

    final reloaded = AdminAccessController(
      credentialStore: FileAdminCredentialStore(file),
    );
    addTearDown(reloaded.dispose);
    await reloaded.initialize();
    expect(reloaded.requiresPinSetup, isFalse);
    expect(
      await reloaded.authenticate('2468'),
      AdminAuthenticationResult.granted,
    );
  });

  test('locks for sixty seconds after five failed attempts', () async {
    var now = DateTime(2026, 9, 16, 12);
    final store = _MemoryAdminCredentialStore();
    final controller = AdminAccessController(
      credentialStore: store,
      now: () => now,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.setupPin('2468');
    controller.exitAdminMode();

    for (var attempt = 0; attempt < 4; attempt += 1) {
      expect(
        await controller.authenticate('0000'),
        AdminAuthenticationResult.invalid,
      );
    }
    expect(
      await controller.authenticate('0000'),
      AdminAuthenticationResult.locked,
    );
    expect(controller.lockoutRemaining, const Duration(seconds: 60));
    expect(
      await controller.authenticate('2468'),
      AdminAuthenticationResult.locked,
    );

    now = now.add(const Duration(seconds: 60));
    expect(
      await controller.authenticate('2468'),
      AdminAuthenticationResult.granted,
    );
  });

  test('expires admin mode after ten minutes in the background', () async {
    var now = DateTime(2026, 9, 16, 12);
    final controller = AdminAccessController(
      credentialStore: _MemoryAdminCredentialStore(),
      buildPin: '1357',
      now: () => now,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    expect(controller.requiresPinSetup, isFalse);
    expect(
      await controller.authenticate('1357'),
      AdminAuthenticationResult.granted,
    );
    controller.recordBackgrounded();
    now = now.add(const Duration(minutes: 9, seconds: 59));
    controller.resumeFromBackground();
    expect(controller.isAdmin, isTrue);

    controller.recordBackgrounded();
    now = now.add(const Duration(minutes: 10));
    controller.resumeFromBackground();
    expect(controller.isAdmin, isFalse);
  });
}

class _MemoryAdminCredentialStore implements AdminCredentialStore {
  AdminPinCredential? credential;

  @override
  Future<AdminPinCredential?> load() async => credential;

  @override
  Future<void> save(AdminPinCredential credential) async {
    this.credential = credential;
  }
}
