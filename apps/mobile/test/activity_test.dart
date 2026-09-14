import 'package:flutter_test/flutter_test.dart';
import 'package:island_table/game/model.dart';
import 'game_model_test.dart' show uiProtocol, uiSnapshot;

ActivityEntry parse(Map<String, dynamic> entry) =>
    ActivityEntry.parse(1, entry);

Map<String, dynamic> bundle([Map<String, int> amounts = const {}]) => {
  for (final r in resourceTypes) r: amounts[r] ?? 0,
};

void main() {
  final snapshot = GameSnapshot.parse(uiSnapshot('action'), uiProtocol);
  final me = snapshot.playerId;
  final others = snapshot.orderedPlayers
      .map((p) => p['id'] as String)
      .where((id) => id != me)
      .toList();
  final a = others[0], b = others[1];
  String name(String id) => snapshot.name(id);

  test('an entry written before the detail fields existed still reads', () {
    final entry = parse({
      'type': 'ROAD_BUILT',
      'actorPlayerId': a,
      'message': 'Built a road.',
    });
    expect(entry.resources, isNull);
    expect(entry.subjectPlayerId, isNull);
    expect(entry.describe(snapshot), '${name(a)} built a road.');
  });

  test('building and upgrading name the player', () {
    for (final (type, message, expected) in [
      ('SETTLEMENT_BUILT', 'Built a settlement.', 'built a settlement.'),
      (
        'CITY_BUILT',
        'Upgraded a settlement to a city.',
        'upgraded a settlement to a city.',
      ),
      ('DICE_ROLLED', 'Rolled 8.', 'rolled 8.'),
      ('ROBBER_MOVED', 'Moved the robber.', 'moved the robber.'),
      (
        'DEVELOPMENT_BOUGHT',
        'Bought a development card.',
        'bought a development card.',
      ),
      ('DEVELOPMENT_PLAYED', 'Played knight.', 'played knight.'),
      ('TURN_ENDED', 'Ended the turn.', 'ended the turn.'),
    ]) {
      expect(
        parse({
          'type': type,
          'actorPlayerId': a,
          'message': message,
        }).describe(snapshot),
        '${name(a)} $expected',
        reason: type,
      );
    }
    expect(
      parse({
        'type': 'CITY_BUILT',
        'actorPlayerId': me,
        'message': 'Upgraded a settlement to a city.',
      }).describe(snapshot),
      'You upgraded a settlement to a city.',
    );
  });

  test('session notices keep the sentence the server wrote', () {
    // Prefixing a name here would read "Mira the host abandoned this game."
    expect(
      parse({
        'type': 'ABANDON_GAME',
        'actorPlayerId': a,
        'message': 'The host abandoned this game.',
      }).describe(snapshot),
      'The host abandoned this game.',
    );
  });

  test('an unrecognised type still shows who did it', () {
    expect(
      parse({
        'type': 'SOMETHING_NEW',
        'actorPlayerId': a,
        'message': 'Did something new.',
      }).describe(snapshot),
      '${name(a)} — Did something new.',
    );
  });

  test('a discard names the player and the cards they put back', () {
    final entry = parse({
      'type': 'RESOURCES_DISCARDED',
      'actorPlayerId': a,
      'message': 'Discarded the required resource cards.',
      'resources': bundle({'brick': 2, 'ore': 1}),
    });
    expect(entry.describe(snapshot), '${name(a)} discarded 2 brick · 1 ore.');
  });

  test('your own discard is addressed to you', () {
    final entry = parse({
      'type': 'RESOURCES_DISCARDED',
      'actorPlayerId': me,
      'message': 'Discarded the required resource cards.',
      'resources': bundle({'wool': 3}),
    });
    expect(entry.describe(snapshot), 'You discarded 3 wool.');
  });

  test(
    'a discard without detail falls back rather than reading as nothing',
    () {
      final entry = parse({
        'type': 'RESOURCES_DISCARDED',
        'actorPlayerId': a,
        'message': 'Discarded the required resource cards.',
      });
      expect(
        entry.describe(snapshot),
        '${name(a)} discarded the required resource cards.',
      );
    },
  );

  test('a theft names both players and never the card taken', () {
    final entry = parse({
      'type': 'RESOURCE_STOLEN',
      'actorPlayerId': a,
      'message': 'Stole one resource card.',
      'subjectPlayerId': b,
    });
    final text = entry.describe(snapshot);
    expect(text, '${name(a)} stole one resource card from ${name(b)}.');
    for (final resource in resourceTypes) {
      expect(text.toLowerCase(), isNot(contains(resource)));
    }
  });

  test('a proposal states its terms and who it was aimed at', () {
    expect(
      parse({
        'type': 'TRADE_PROPOSED',
        'actorPlayerId': a,
        'message': 'Proposed a resource trade.',
        'subjectPlayerId': b,
        'give': bundle({'brick': 1}),
        'receive': bundle({'ore': 2}),
      }).describe(snapshot),
      '${name(a)} offered ${name(b)} 1 brick for 2 ore.',
    );
    expect(
      parse({
        'type': 'TRADE_PROPOSED',
        'actorPlayerId': a,
        'message': 'Proposed a resource trade.',
        'subjectPlayerId': null,
        'give': bundle({'grain': 1}),
        'receive': bundle({'wool': 1}),
      }).describe(snapshot),
      '${name(a)} offered the table 1 grain for 1 wool.',
    );
  });

  test('an accepted trade reads from the accepting player', () {
    expect(
      parse({
        'type': 'TRADE_ACCEPTED',
        'actorPlayerId': b,
        'message': 'Completed a player trade.',
        'subjectPlayerId': a,
        'give': bundle({'ore': 2}),
        'receive': bundle({'brick': 1}),
      }).describe(snapshot),
      '${name(b)} traded 2 ore to ${name(a)} for 1 brick.',
    );
  });

  test('declines and bank trades are attributed too', () {
    expect(
      parse({
        'type': 'TRADE_DECLINED',
        'actorPlayerId': b,
        'message': 'Declined a trade offer.',
        'subjectPlayerId': a,
      }).describe(snapshot),
      '${name(b)} declined the trade offer from ${name(a)}.',
    );
    expect(
      parse({
        'type': 'BANK_TRADE',
        'actorPlayerId': a,
        'message': 'Completed a bank trade.',
        'give': bundle({'brick': 4}),
        'receive': bundle({'ore': 1}),
      }).describe(snapshot),
      '${name(a)} traded 4 brick to the bank for 1 ore.',
    );
  });

  test('an unattributed entry still reads as a sentence', () {
    // A null actor is a system event; the log must not render a bare name gap.
    expect(
      parse({
        'type': 'RESOURCE_STOLEN',
        'actorPlayerId': null,
        'message': 'Stole one resource card.',
      }).describe(snapshot),
      'A player stole one resource card.',
    );
    expect(
      parse({
        'type': 'GAME_CREATED',
        'actorPlayerId': null,
        'message': 'The island is ready for initial placement.',
      }).describe(snapshot),
      'The island is ready for initial placement.',
    );
  });
}
