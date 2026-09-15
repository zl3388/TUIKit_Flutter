import 'dart:io';

import 'package:application/src/offline_demo/data/wecom_identity_repository.dart';
import 'package:application/src/offline_demo/data/wecom_local_simulation_repository.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_database.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory temporaryDirectory;
  late WeComOverlayDatabase database;
  var now = DateTime.utc(2026, 9, 15, 8);

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'tui_wecom_local_simulation_',
    );
    database = await WeComOverlayDatabase.open(
      factory: databaseFactoryFfi,
      databasePath: p.join(temporaryDirectory.path, 'overlay.db'),
    );
    now = DateTime.utc(2026, 9, 15, 8);
  });

  tearDown(() async {
    await database.close();
    await temporaryDirectory.delete(recursive: true);
  });

  test('persists a deterministic text exchange schedule', () async {
    final repository = _repository(database, () => now);

    final exchange = await repository.enqueueTextExchange(
      conversationId: 'S:1_2',
      senderProfileId: '1',
      peerProfileId: '2',
      text: '  hello  ',
    );
    final reopened = _repository(database, () => now);
    final restored = (await reopened.listExchanges()).single;

    expect(exchange.text, 'hello');
    expect(restored.eventKey, exchange.eventKey);
    expect(restored.conversationId, 'S:1_2');
    expect(restored.senderProfileId, '1');
    expect(restored.peerProfileId, '2');
    expect(restored.automaticReplyText, '收到');
    expect(
      restored.serverAcknowledgedAt.difference(restored.createdAt),
      const Duration(milliseconds: 800),
    );
    expect(
      restored.peerReadAt.difference(restored.createdAt),
      const Duration(milliseconds: 1800),
    );
    expect(
      restored.automaticReplyAt.difference(restored.createdAt),
      const Duration(milliseconds: 3000),
    );
  });

  test('filters events by exact identity without using a dataset path',
      () async {
    final first = _repository(database, () => now);
    final second = WeComLocalSimulationRepository(
      overlayDatabase: database,
      identityScope: const WeComIdentityScope(
        corporationId: 200,
        userId: 2,
      ),
      now: () => now,
    );
    await first.enqueueTextExchange(
      conversationId: 'S:1_2',
      senderProfileId: '1',
      text: 'first identity',
    );
    await second.enqueueTextExchange(
      conversationId: 'S:2_3',
      senderProfileId: '2',
      text: 'second identity',
    );

    expect(
      (await first.listExchanges()).map((item) => item.text),
      ['first identity'],
    );
    expect(
      (await second.listExchanges()).map((item) => item.text),
      ['second identity'],
    );
    expect(
      await database.connection.query(
        WeComOverlaySchema.operationsTable,
      ),
      isEmpty,
    );
  });

  test('reports only future transitions and omits auto reply without a peer',
      () async {
    final repository = _repository(database, () => now);
    final exchange = await repository.enqueueTextExchange(
      conversationId: 'R:room',
      senderProfileId: '1',
      text: 'group message',
    );

    expect(exchange.nextTransitionAfter(now), exchange.serverAcknowledgedAt);
    now = now.add(const Duration(milliseconds: 900));
    expect(exchange.nextTransitionAfter(now), isNull);
  });

  test('cancels an exchange with an append-only identity-scoped event',
      () async {
    final repository = _repository(database, () => now);
    final exchange = await repository.enqueueTextExchange(
      conversationId: 'S:1_2',
      senderProfileId: '1',
      peerProfileId: '2',
      text: 'undo me',
    );
    final otherIdentity = WeComLocalSimulationRepository(
      overlayDatabase: database,
      identityScope: const WeComIdentityScope(
        corporationId: 200,
        userId: 2,
      ),
      now: () => now,
    );

    await expectLater(
      otherIdentity.cancelTextExchange(exchange.eventKey),
      throwsStateError,
    );
    await repository.cancelTextExchange(exchange.eventKey);

    expect(await repository.listExchanges(), isEmpty);
    expect(
      await database.connection.query(
        WeComOverlaySchema.simulationEventsTable,
      ),
      hasLength(2),
    );
    await expectLater(
      repository.cancelTextExchange(exchange.eventKey),
      throwsA(isA<DatabaseException>()),
    );
  });
}

WeComLocalSimulationRepository _repository(
  WeComOverlayDatabase database,
  DateTime Function() now,
) {
  return WeComLocalSimulationRepository(
    overlayDatabase: database,
    identityScope: const WeComIdentityScope(corporationId: 100, userId: 1),
    now: now,
  );
}
