import '../core/protocol.dart';

typedef JsonMap = Map<String, dynamic>;
const resourceTypes = ['brick', 'lumber', 'wool', 'grain', 'ore'];
JsonMap object(Object? value) => Map<String, dynamic>.from(value as Map);
Map<String, int> resources([Object? value]) => {
  for (final r in resourceTypes)
    r: value == null ? 0 : (value as Map)[r] as int,
};
String words(String value) => value
    .toLowerCase()
    .split('_')
    .map((s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}')
    .join(' ');
const costs = <String, Map<String, int>>{
  'BUILD_ROAD': {'brick': 1, 'lumber': 1},
  'BUILD_SETTLEMENT': {'brick': 1, 'lumber': 1, 'wool': 1, 'grain': 1},
  'BUILD_CITY': {'grain': 2, 'ore': 3},
  'BUY_DEVELOPMENT_CARD': {'wool': 1, 'grain': 1, 'ore': 1},
};
String resourceSummary(Map value) => resourceTypes
    .where((r) => (value[r] ?? 0) > 0)
    .map((r) => '${value[r]} $r')
    .join(' · ');

/// Reads the optional public resource detail on a log entry. Top level because
/// `ActivityEntry.resources` would otherwise shadow the `resources` helper.
Map<String, int>? detailResources(Object? value) =>
    value is Map ? resources(value) : null;

/// One entry of the public log. The server sends ids rather than prose, because
/// it has no nicknames and the log is durable, so the sentence is composed here
/// where names can still be resolved.
class ActivityEntry {
  const ActivityEntry({
    required this.sequence,
    required this.type,
    required this.message,
    this.actorPlayerId,
    this.subjectPlayerId,
    this.resources,
    this.give,
    this.receive,
  });

  /// Tolerant about the optional detail on purpose: entries written before
  /// those fields existed are still in app.move_logs and must keep rendering.
  factory ActivityEntry.parse(int sequence, Map entry) {
    return ActivityEntry(
      sequence: sequence,
      type: entry['type'] as String,
      message: entry['message'] as String,
      actorPlayerId: entry['actorPlayerId'] as String?,
      subjectPlayerId: entry['subjectPlayerId'] as String?,
      resources: detailResources(entry['resources']),
      give: detailResources(entry['give']),
      receive: detailResources(entry['receive']),
    );
  }

  final int sequence;
  final String type, message;
  final String? actorPlayerId, subjectPlayerId;
  final Map<String, int>? resources;

  /// Trade terms, always stated from [actorPlayerId]'s own side.
  final Map<String, int>? give, receive;

  String _terms(Map<String, int>? value) {
    final summary = value == null ? '' : resourceSummary(value);
    return summary.isEmpty ? 'nothing' : summary;
  }

  /// Types whose message the engine writes as a verb phrase about the actor,
  /// so it reads as `<name> <phrase>`. Kept as an allow-list rather than
  /// inferred, because the alternatives are written as whole sentences and
  /// would otherwise render as "Mira the host abandoned this game."; an
  /// unlisted type still keeps its attribution through the dashed fallback.
  static const _verbPhrase = {
    'SETTLEMENT_BUILT',
    'ROAD_BUILT',
    'CITY_BUILT',
    'DICE_ROLLED',
    'ROBBER_MOVED',
    'TRADE_CANCELLED',
    'DEVELOPMENT_BOUGHT',
    'DEVELOPMENT_PLAYED',
    'TURN_ENDED',
    'GAME_FINISHED',
  };

  /// Session events the server already phrases as complete sentences.
  static const _wholeSentence = {
    'ABANDON_GAME',
    'PAUSE_GAME',
    'RESUME_GAME',
    'RECOVER_GAME',
    'PRESENCE_PAUSE',
  };

  String _name(GameSnapshot s, String? id) =>
      id == null ? 'A player' : (id == s.playerId ? 'You' : s.name(id));

  /// The sentence shown in the log and in the matching notification.
  String describe(GameSnapshot s) {
    final who = _name(s, actorPlayerId);
    switch (type) {
      case 'RESOURCES_COLLECTED':
        return '$who collected ${_terms(resources)} from the roll.';
      case 'RESOURCES_DISCARDED':
        final summary = resources == null ? '' : resourceSummary(resources!);
        return summary.isEmpty
            ? '$who discarded the required resource cards.'
            : '$who discarded $summary.';
      case 'RESOURCE_STOLEN':
        return subjectPlayerId == null
            ? '$who stole one resource card.'
            : '$who stole one resource card from ${_name(s, subjectPlayerId)}.';
      case 'TRADE_PROPOSED':
        if (give == null || receive == null) return '$who — $message';
        final to = subjectPlayerId == null
            ? 'the table'
            : _name(s, subjectPlayerId);
        return '$who offered $to ${_terms(give)} for ${_terms(receive)}.';
      case 'TRADE_ACCEPTED':
        if (give == null || receive == null) return '$who — $message';
        final from = subjectPlayerId == null
            ? 'another player'
            : _name(s, subjectPlayerId);
        return '$who traded ${_terms(give)} to $from for ${_terms(receive)}.';
      case 'TRADE_DECLINED':
        return subjectPlayerId == null
            ? '$who declined a trade offer.'
            : '$who declined the trade offer from '
                  '${_name(s, subjectPlayerId)}.';
      case 'BANK_TRADE':
        if (give == null || receive == null) return '$who — $message';
        return '$who traded ${_terms(give)} to the bank for ${_terms(receive)}.';
      default:
        if (actorPlayerId == null || _wholeSentence.contains(type)) {
          return message;
        }
        if (!_verbPhrase.contains(type)) return '$who — $message';
        return '$who ${message[0].toLowerCase()}${message.substring(1)}';
    }
  }
}

/// Only a validated recipient snapshot enters this model; never a canonical state.
class GameSnapshot {
  GameSnapshot._(this.json);
  factory GameSnapshot.parse(Object? value, Protocol protocol) {
    if (!protocol.accepts('gameSnapshot', value)) {
      throw const FormatException('Incompatible game snapshot');
    }
    return GameSnapshot._(_freeze(value) as JsonMap);
  }
  final JsonMap json;
  JsonMap get public => json['publicState'] as JsonMap;
  JsonMap get hand => json['privateState'] as JsonMap;
  JsonMap get board => public['board'] as JsonMap;
  JsonMap get players => public['players'] as JsonMap;
  JsonMap get buildings => public['buildings'] as JsonMap;
  JsonMap get roads => public['roads'] as JsonMap;
  JsonMap get vertices => board['vertices'] as JsonMap;
  JsonMap get edges => board['edges'] as JsonMap;
  JsonMap get hexes => board['hexes'] as JsonMap;
  String get playerId => hand['playerId'] as String;
  String get roomId => json['roomId'] as String;
  int get version => json['version'] as int;
  String get phase => public['phase'] as String;
  String get phaseId => public['phaseId'] as String;
  bool get active => public['activePlayerId'] == playerId;
  bool get paused => (public['pauseReasons'] as List).isNotEmpty;
  bool get complete => phase == 'COMPLETE';
  JsonMap get own => players[playerId] as JsonMap;
  Map<String, int> get stock => resources(hand['resources']);
  List<JsonMap> get cards => (hand['developmentCards'] as List).cast<JsonMap>();
  List<JsonMap> get orderedPlayers => players.values.cast<JsonMap>().toList()
    ..sort((a, b) => (a['seatIndex'] as int).compareTo(b['seatIndex'] as int));
  String name(String id) => players[id]?['nickname'] as String? ?? 'Player';

  /// Automated seats are labelled everywhere a name is shown, so a practice
  /// game never leaves you guessing which opponents are people.
  bool isBot(String? id) => id != null && players[id]?['kind'] == 'BOT';

  /// Hexes the last roll paid out from: their number came up, they grow
  /// something, and the robber is not sitting on them. Empty until a roll.
  Set<String> get producingHexes {
    final roll = public['dice'] as List?;
    if (roll == null || public['hasRolled'] != true) return const {};
    final total = (roll[0] as int) + (roll[1] as int);
    if (total == 7) return const {};
    return {
      for (final entry in hexes.entries)
        if (entry.value['number'] == total &&
            entry.value['terrain'] != 'DESERT' &&
            entry.key != public['robberHexId'])
          entry.key,
    };
  }

  /// How a player's visible points add up. Hidden victory-point cards are only
  /// ever counted for yourself, since nobody else may see them.
  List<(String, int)> pointsBreakdown(String id) {
    var settlements = 0, cities = 0;
    for (final building in buildings.values.cast<JsonMap>()) {
      if (building['ownerPlayerId'] != id) continue;
      if (building['type'] == 'CITY') {
        cities++;
      } else {
        settlements++;
      }
    }
    final rows = <(String, int)>[
      if (settlements > 0)
        ('$settlements settlement${settlements == 1 ? '' : 's'}', settlements),
      if (cities > 0) ('$cities cit${cities == 1 ? 'y' : 'ies'}', cities * 2),
      if (public['longestRoad']['holderPlayerId'] == id) ('Longest road', 2),
      if (public['largestArmy']['holderPlayerId'] == id) ('Largest army', 2),
    ];
    if (id == playerId) {
      final hidden = cards.where((c) => c['type'] == 'VICTORY_POINT').length;
      if (hidden > 0) {
        rows.add((
          '$hidden victory point card${hidden == 1 ? '' : 's'}',
          hidden,
        ));
      }
    }
    return rows;
  }

  /// A table where every other seat is automated, so leaving it affects nobody.
  /// Not the same as "has bots": a shared game gains bots when someone walks
  /// out and the rest carry on without them.
  bool get soloPractice => players.values.cast<JsonMap>().every(
    (p) => p['id'] == playerId || p['kind'] == 'BOT',
  );

  /// Seats whose player left and which nobody has filled yet.
  List<JsonMap> get vacantSeats => players.values
      .cast<JsonMap>()
      .where((p) => p['kind'] == 'VACANT')
      .toList();
  bool get hasBots => players.values.any((p) => (p as Map)['kind'] == 'BOT');
  List<JsonMap> get incomingTrades => (public['trades'] as Map).values
      .cast<JsonMap>()
      .where(
        (offer) =>
            phase == 'ACTION' &&
            offer['status'] == 'OPEN' &&
            offer['proposerPlayerId'] != playerId &&
            (offer['targetPlayerId'] == null ||
                offer['targetPlayerId'] == playerId) &&
            !(offer['declinedBy'] as List).contains(playerId) &&
            (active || offer['proposerPlayerId'] == public['activePlayerId']),
      )
      .toList();

  /// Offers this player proposed, in seat order of their decliners' arrival.
  /// Used to notice a decline coming back, which the proposer otherwise has no
  /// way to see: a declined offer stays OPEN for everyone else.
  List<JsonMap> get ownTrades => (public['trades'] as Map).values
      .cast<JsonMap>()
      .where((offer) => offer['proposerPlayerId'] == playerId)
      .toList();

  /// Who could still accept [offer]: its target, or every opponent when it was
  /// offered to the table.
  Set<String> eligibleFor(JsonMap offer) => offer['targetPlayerId'] == null
      ? players.keys.where((id) => id != playerId).toSet()
      : {offer['targetPlayerId'] as String};

  bool canAfford(String command) =>
      (costs[command] ?? {}).entries.every((e) => stock[e.key]! >= e.value);
  int bankRate(String resource) {
    var rate = 4;
    for (final port in (board['ports'] as Map).values.cast<Map>()) {
      if (!(port['vertexIds'] as List).any(
        (v) => buildings[v]?['ownerPlayerId'] == playerId,
      )) {
        continue;
      }
      if (port['resourceType'] == resource) rate = 2;
      if (port['resourceType'] == null && rate > 3) rate = 3;
    }
    return rate;
  }

  Set<String> neighbours(String v) => {
    for (final e in vertices[v]['edgeIds'] as List)
      for (final n in edges[e]['vertexIds'] as List)
        if (n != v) n as String,
  };
  bool canRoad(String e) {
    if (roads.containsKey(e) || (own['remainingPieces']['roads'] as int) == 0) {
      return false;
    }
    return (edges[e]['vertexIds'] as List).any((v) {
      if (buildings[v] != null) {
        return buildings[v]['ownerPlayerId'] == playerId;
      }
      return (vertices[v]['edgeIds'] as List).any(
        (n) => roads[n]?['ownerPlayerId'] == playerId,
      );
    });
  }

  bool canSettle(String v, {bool setup = false}) =>
      !buildings.containsKey(v) &&
      !neighbours(v).any(buildings.containsKey) &&
      (own['remainingPieces']['settlements'] as int) > 0 &&
      (setup ||
          (vertices[v]['edgeIds'] as List).any(
            (e) => roads[e]?['ownerPlayerId'] == playerId,
          ));

  /// Advisory public-information previews. The server remains the final authority.
  Set<String> targets(String command, {String? pendingSetupVertex}) {
    if (!active || paused || complete) return {};
    switch (command) {
      case 'PLACE_SETUP_SETTLEMENT':
        return phase == 'SETUP_SETTLEMENT'
            ? vertices.keys.where((v) => canSettle(v, setup: true)).toSet()
            : {};
      case 'PLACE_SETUP_ROAD':
        if (phase != 'SETUP_ROAD') return {};
        // A fresh snapshot lacks the private setup cursor. Every roadless own
        // settlement is a valid candidate; the engine checks its exact pending vertex.
        final candidates = buildings.keys.where(
          (v) =>
              buildings[v]['ownerPlayerId'] == playerId &&
              (pendingSetupVertex == null || v == pendingSetupVertex) &&
              !(vertices[v]['edgeIds'] as List).any(
                (e) => roads[e]?['ownerPlayerId'] == playerId,
              ),
        );
        return {
          for (final v in candidates)
            for (final e in vertices[v]['edgeIds'] as List)
              if (canRoad(e as String)) e,
        };
      case 'BUILD_ROAD':
        return phase == 'ACTION' && canAfford(command)
            ? edges.keys.where(canRoad).toSet()
            : {};
      case 'PLACE_FREE_ROAD':
        return phase == 'ROAD_BUILDING'
            ? edges.keys.where(canRoad).toSet()
            : {};
      case 'BUILD_SETTLEMENT':
        return phase == 'ACTION' && canAfford(command)
            ? vertices.keys.where((v) => canSettle(v)).toSet()
            : {};
      case 'BUILD_CITY':
        return phase == 'ACTION' &&
                canAfford(command) &&
                (own['remainingPieces']['cities'] as int) > 0
            ? buildings.keys
                  .where(
                    (v) =>
                        buildings[v]['ownerPlayerId'] == playerId &&
                        buildings[v]['type'] == 'SETTLEMENT',
                  )
                  .toSet()
            : {};
      case 'MOVE_ROBBER':
        return phase == 'ROBBER_MOVE'
            ? hexes.keys.where((h) => h != public['robberHexId']).toSet()
            : {};
      default:
        return {};
    }
  }

  Set<String> get victims => {
    for (final v in hexes[public['robberHexId']]['vertexIds'] as List)
      if (buildings[v] != null &&
          buildings[v]['ownerPlayerId'] != playerId &&
          (players[buildings[v]['ownerPlayerId']]['resourceCardCount'] as int) >
              0)
        buildings[v]['ownerPlayerId'] as String,
  };
  String? cardUnavailable(JsonMap card) {
    if (!active) return 'Wait for your turn';
    if (!['AWAIT_ROLL', 'ACTION'].contains(phase)) {
      return 'Finish the current decision first';
    }
    if (card['type'] == 'VICTORY_POINT') {
      return 'Counts automatically toward your score';
    }
    if (public['developmentCardPlayedThisTurn'] == true) {
      return 'One development card per turn';
    }
    if ((card['purchasedOnTurn'] as int) >= (public['turnNumber'] as int)) {
      return 'Available on your next turn';
    }
    if (card['type'] == 'ROAD_BUILDING' && !edges.keys.any(canRoad)) {
      return 'No legal road placement';
    }
    return null;
  }
}

Object? _freeze(Object? value) => value is Map
    ? Map<String, dynamic>.unmodifiable(
        value.map((k, v) => MapEntry(k as String, _freeze(v))),
      )
    : value is List
    ? List<Object?>.unmodifiable(value.map(_freeze))
    : value;
