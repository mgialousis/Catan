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
