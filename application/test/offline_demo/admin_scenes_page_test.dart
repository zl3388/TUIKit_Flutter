import 'package:application/src/offline_demo/data/wecom_scene_service.dart';
import 'package:application/src/offline_demo/presentation/admin_scenes_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _Scenes scenes;
  var reloads = 0;
  setUp(() {
    scenes = _Scenes();
    reloads = 0;
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      return Scaffold(
          body: TextButton(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => AdminScenesPage(
            scenes: scenes,
            onEnvironmentReload: () async {
              reloads++;
            },
          ),
        )),
        child: const Text('Open'),
      ));
    })));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('snapshot requires a name and stays on the narrow-screen list',
      (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('save-scene-snapshot')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-scene-name')));
    await tester.pumpAndSettle();
    expect(find.text('请输入名称'), findsOneWidget);
    expect(scenes.savedNames, isEmpty);
    await tester.enterText(find.byKey(const Key('scene-name')), '演示前');
    await tester.tap(find.byKey(const Key('confirm-scene-name')));
    await tester.pumpAndSettle();
    expect(scenes.savedNames, ['演示前']);
    expect(find.text('演示前'), findsOneWidget);
    expect(reloads, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('restoring a snapshot creates an editable scene and reloads',
      (tester) async {
    await scenes.saveSnapshot('Saved');
    await open(tester);
    await tester.tap(find.descendant(
      of: find.byKey(const Key('scene-snapshot-1')),
      matching: find.byType(PopupMenuButton<String>),
    ));
    await tester.pumpAndSettle();
    expect(find.text('切换到此场景'), findsNothing);
    await tester.tap(find.text('恢复为新场景'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('scene-name')), 'Restored');
    await tester.tap(find.byKey(const Key('confirm-scene-name')));
    await tester.pumpAndSettle();
    expect(scenes.copies, ['snapshot-1']);
    expect(reloads, 1);
    expect(find.text('Open'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reset cancellation and service errors preserve the current page',
      (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('reset-scene')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(scenes.resetCount, 0);
    scenes.allow = false;
    await tester.tap(find.byKey(const Key('create-scene')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('scene-name')), 'Denied');
    await tester.tap(find.byKey(const Key('confirm-scene-name')));
    await tester.pumpAndSettle();
    expect(reloads, 0);
    expect(find.textContaining('操作失败'), findsOneWidget);
    expect(find.text('场景与快照'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _Scenes implements WeComSceneService {
  final savedNames = <String>[];
  final copies = <String?>[];
  var resetCount = 0;
  var allow = true;
  final items = <WeComOverlayScene>[
    _item('default', 'Default'),
  ];

  static WeComOverlayScene _item(String id, String name,
          {bool snapshot = false}) =>
      WeComOverlayScene(
          id: id,
          name: name,
          datasetId: 'a' * 64,
          isSnapshot: snapshot,
          createdAt: DateTime.utc(2026));
  @override
  String get activeSceneId => 'default';
  @override
  Future<List<WeComOverlayScene>> list() async => List.of(items);
  @override
  Future<WeComOverlayScene> saveSnapshot(String name) async {
    savedNames.add(name);
    final snapshot =
        _item('snapshot-${savedNames.length}', name, snapshot: true);
    items.add(snapshot);
    return snapshot;
  }

  @override
  Future<WeComOverlayScene> create(String name,
      {String? copyFromSceneId}) async {
    if (!allow) throw StateError('Admin expired');
    copies.add(copyFromSceneId);
    return _item('created', name);
  }

  @override
  Future<void> reset(String name) async {
    resetCount++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
