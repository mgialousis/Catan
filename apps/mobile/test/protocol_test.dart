import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:island_table/core/protocol.dart';

void main() {
  final protocol = Protocol(
    jsonDecode(
          File('../../packages/protocol/schemas/v1.json').readAsStringSync(),
        )
        as Map<String, dynamic>,
  );
  final fixtures =
      jsonDecode(
            File(
              '../../packages/protocol/fixtures/contracts.json',
            ).readAsStringSync(),
          )
          as List;
  for (final fixture in fixtures.cast<Map>()) {
    test(fixture['name'] as String, () {
      expect(
        protocol.accepts(fixture['schema'] as String, fixture['value']),
        fixture['valid'],
      );
    });
  }
  test('bundled schema equals the canonical shared schema', () {
    expect(
      File('assets/protocol/v1.json').readAsStringSync(),
      File('../../packages/protocol/schemas/v1.json').readAsStringSync(),
    );
  });
}
