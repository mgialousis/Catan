import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:island_table/preview.dart';

void main() {
  test('practice transport rejects hosted endpoints', () {
    expect(
      () => PreviewPort('setup', url: 'https://example.com'),
      throwsArgumentError,
    );
    expect(
      () => PreviewPort('setup', url: 'http://192.168.1.3:3001'),
      throwsArgumentError,
    );
  });
  test('practice entry is excluded from the shipped app', () {
    expect(
      File('lib/main.dart').readAsStringSync(),
      isNot(contains('preview')),
    );
  });
  test('all manual practice phases are listed', () {
    expect(
      practiceScenarios,
      containsAll([
        'setup',
        'action',
        'discard',
        'robber',
        'free-roads',
        'waiting',
        'paused',
        'results',
        'victory',
      ]),
    );
  });
}
