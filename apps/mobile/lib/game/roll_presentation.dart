import 'model.dart';

class ResourceFlight {
  const ResourceFlight(this.hexId, this.playerId, this.resource);
  final String hexId, playerId, resource;
}

const terrainResources = {
  'FOREST': 'lumber',
  'HILLS': 'brick',
  'PASTURE': 'wool',
  'FIELDS': 'grain',
  'MOUNTAINS': 'ore',
};

bool isNewRoll(GameSnapshot before, GameSnapshot after) =>
    before.roomId == after.roomId &&
    after.version == before.version + 1 &&
    before.public['turnNumber'] == after.public['turnNumber'] &&
    before.public['hasRolled'] == false &&
    after.public['hasRolled'] == true;

/// The public payout is authoritative; board geometry only locates its source.
/// Never infer an opponent's payout from their hand or replay history on join.
List<ResourceFlight> resourceFlights(
  GameSnapshot roll,
  List<ActivityEntry> activity,
) {
  final result = <ResourceFlight>[];
  final seen = <String>{};
  for (final entry in activity) {
    final player = entry.actorPlayerId;
    if (entry.sequence != roll.version ||
        entry.type != 'RESOURCES_COLLECTED' ||
        player == null ||
        entry.resources == null ||
        !seen.add(player)) {
      continue;
    }
    final remaining = {...entry.resources!};
    for (final hexId in roll.producingHexes) {
      final hex = roll.hexes[hexId] as Map;
      final resource = terrainResources[hex['terrain']];
      if (resource == null) continue;
      for (final vertex in hex['vertexIds'] as List) {
        final building = roll.buildings[vertex] as Map?;
        if (building?['ownerPlayerId'] != player) continue;
        final count = building!['type'] == 'CITY' ? 2 : 1;
        for (var card = 0; card < count && remaining[resource]! > 0; card++) {
          result.add(ResourceFlight(hexId, player, resource));
          remaining[resource] = remaining[resource]! - 1;
        }
      }
    }
  }
  return result;
}
