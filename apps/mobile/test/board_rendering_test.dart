import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:island_table/game/board.dart';
import 'package:island_table/game/model.dart';

import 'game_model_test.dart' show uiProtocol, uiSnapshot;

// Inspect actual retained display lists, rather than just shouldRepaint's
// return value: ancestor scrolling and animation can also trigger painting.
List<ui.Picture?> boardPictures(WidgetTester tester) => find
    .descendant(
      of: find.byType(IslandBoard),
      matching: find.byType(RepaintBoundary),
    )
    .evaluate()
    .map((element) {
      final boundary = element.renderObject! as RenderRepaintBoundary;
      return (boundary.debugLayer!.firstChild! as PictureLayer).picture;
    })
    .toList();

void main() {
  testWidgets('scrolling, zooming and feedback reuse the island artwork', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final snapshot = GameSnapshot.parse(uiSnapshot('action'), uiProtocol);
    var targets = <String>{};
    String? selected;
    String? tapped;
    late StateSetter update;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return SingleChildScrollView(
                controller: scroll,
                child: Column(
                  children: [
                    SizedBox(
                      width: 400,
                      child: IslandBoard(
                        snapshot: snapshot,
                        targets: targets,
                        selected: selected,
                        onTarget: (id) => tapped = id,
                      ),
                    ),
                    const SizedBox(height: 1000),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final initial = boardPictures(tester);
    expect(initial, hasLength(3));

    scroll.jumpTo(30);
    await tester.pump();
    expect(boardPictures(tester), orderedEquals(initial));
    scroll.jumpTo(0);
    await tester.pump();

    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pumpAndSettle();
    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    expect(
      viewer.transformationController!.value.getMaxScaleOnAxis(),
      greaterThan(1),
    );
    expect(boardPictures(tester), orderedEquals(initial));
    await tester.tap(find.byTooltip('Fit island'));
    await tester.pumpAndSettle();
    expect(viewer.transformationController!.value.getMaxScaleOnAxis(), 1);
    expect(boardPictures(tester), orderedEquals(initial));

    final target = snapshot.vertices.keys.first;
    update(() => targets = {target});
    await tester.pump();
    final start = boardPictures(tester);
    await tester.pump(const Duration(milliseconds: 100));
    final animated = boardPictures(tester);
    expect(animated.take(2), orderedEquals(initial.take(2)));
    expect(animated.last, isNot(same(start.last)));
    await tester.pumpAndSettle();

    // Tap in board coordinates after the transforms have been reset.
    final canvas = tester.renderObject<RenderBox>(
      find
          .descendant(
            of: find.byType(IslandBoard),
            matching: find.byType(CustomPaint),
          )
          .last,
    );
    await tester.tapAt(canvas.localToGlobal(centreOf(snapshot, target)));
    expect(tapped, target);
    update(() => selected = target);
    await tester.pumpAndSettle();
    expect(boardPictures(tester).take(2), orderedEquals(initial.take(2)));
    expect(tester.takeException(), isNull);
  });

  testWidgets('snapshots invalidate only the artwork that actually changes', (
    tester,
  ) async {
    final json = uiSnapshot('action');
    var snapshot = GameSnapshot.parse(json, uiProtocol);
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return SizedBox(
                width: 400,
                child: IslandBoard(snapshot: snapshot, onTarget: (_) {}),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    var previous = boardPictures(tester);

    Future<void> refresh() async {
      json['version'] = (json['version'] as int) + 1;
      update(() => snapshot = GameSnapshot.parse(json, uiProtocol));
      await tester.pumpAndSettle();
    }

    json['privateState']['resources']['brick'] = 3;
    await refresh();
    expect(boardPictures(tester), orderedEquals(previous));

    final public = json['publicState'] as Map;
    public['roads'][snapshot.edges.keys.firstWhere(
      (id) => !snapshot.roads.containsKey(id),
    )] = {
      'ownerPlayerId': snapshot.playerId,
    };
    await refresh();
    var current = boardPictures(tester);
    expect(current.first, same(previous.first));
    expect(current[1], isNot(same(previous[1])));
    previous = current;

    public['buildings'][snapshot.buildings.keys.first]['type'] = 'CITY';
    await refresh();
    current = boardPictures(tester);
    expect(current.first, same(previous.first));
    expect(current[1], isNot(same(previous[1])));
    previous = current;

    public['robberHexId'] = snapshot.hexes.keys.firstWhere(
      (id) => id != public['robberHexId'],
    );
    await refresh();
    current = boardPictures(tester);
    expect(current.first, same(previous.first));
    expect(current[1], isNot(same(previous[1])));
    previous = current;

    // A different board (e.g. a rematch) must replace the retained terrain.
    public['board']['hexes'][snapshot.hexes.keys.first]['terrain'] =
        snapshot.hexes.values.first['terrain'] == 'FOREST'
        ? 'PASTURE'
        : 'FOREST';
    await refresh();
    expect(boardPictures(tester).first, isNot(same(previous.first)));
    expect(tester.takeException(), isNull);
  });
}
