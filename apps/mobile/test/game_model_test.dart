import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:island_table/core/protocol.dart';
import 'package:island_table/game/model.dart';

final uiFixtures =
    (jsonDecode(
              File(
                '../../packages/protocol/fixtures/ui-previews.json',
              ).readAsStringSync(),
            )
            as List)
        .cast<Map>();
final uiProtocol = Protocol(
  object(
    jsonDecode(
      File('../../packages/protocol/schemas/v1.json').readAsStringSync(),
    ),
  ),
);
JsonMap uiSnapshot(String name) => object(
  jsonDecode(
    jsonEncode(uiFixtures.firstWhere((f) => f['name'] == name)['snapshot']),
  ),
);
void main() {
  for (final fixture in uiFixtures) {
    test(
      'Flutter targets agree with accepted engine moves: ${fixture['name']}',
      () {
        final s = GameSnapshot.parse(fixture['snapshot'], uiProtocol);
        for (final entry in (fixture['targets'] as Map).entries) {
          expect(
            s.targets(entry.key as String),
            unorderedEquals(entry.value as List),
            reason: '${fixture['name']} ${entry.key}',
          );
        }
      },
    );
  }
}
