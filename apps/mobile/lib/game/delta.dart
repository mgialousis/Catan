import 'dart:convert';
import '../core/protocol.dart';
import 'model.dart';

/// Validate both patches and the resulting view before publishing either half.
GameSnapshot applyDelta(GameSnapshot before, Object? value, Protocol protocol) {
  if (!protocol.accepts('gameDelta', value)) {
    throw const FormatException('Invalid delta');
  }
  final delta = object(value);
  if (delta['roomId'] != before.roomId ||
      delta['fromVersion'] != before.version ||
      delta['toVersion'] != before.version + 1) {
    throw const FormatException('Game version gap');
  }
  final next = object(jsonDecode(jsonEncode(before.json)));
  for (final scope in ['public', 'private']) {
    for (final raw in delta['${scope}Patch'] as List) {
      final patch = object(raw);
      final path = (patch['path'] as String).split('/').skip(1).toList();
      if (path.isEmpty ||
          path.any(
            (key) =>
                !RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(key) ||
                ['__proto__', 'constructor', 'prototype'].contains(key),
          )) {
        throw const FormatException('Unsafe patch');
      }
      Map target = next['${scope}State'] as Map;
      for (final key in path.take(path.length - 1)) {
        if (target[key] is! Map) throw const FormatException('Missing parent');
        target = target[key] as Map;
      }
      final key = path.last, exists = target.containsKey(key);
      switch (patch['op']) {
        case 'remove':
          if (!exists) throw const FormatException('Missing field');
          target.remove(key);
        case 'replace':
          if (!exists) throw const FormatException('Missing field');
          target[key] = patch['value'];
        case 'add':
          target[key] = patch['value'];
        default:
          throw const FormatException('Unsupported patch');
      }
    }
  }
  next['version'] = delta['toVersion'];
  next['serverTime'] = delta['serverTime'];
  final result = GameSnapshot.parse(next, protocol);
  if (result.playerId != before.playerId) {
    throw const FormatException('Owner changed');
  }
  return result;
}
