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

/// A piece another player just placed, so the table can show where it went.
/// Derived by comparing consecutive snapshots: the public activity records that
/// something was built but not where, and the board geometry is already local.
class PlacedPiece {
  const PlacedPiece(this.locationId, this.playerId, this.what);
  final String locationId, playerId, what;
}

PlacedPiece? newPiece(GameSnapshot before, GameSnapshot after) {
  if (before.roomId != after.roomId ||
      after.version != before.version + 1 ||
      after.public['activePlayerId'] == after.playerId) {
    return null;
  }
  for (final (collection, previous, what) in [
    (after.buildings, before.buildings, 'settlement'),
    (after.roads, before.roads, 'road'),
  ]) {
    for (final entry in collection.entries) {
      final owner = (entry.value as Map)['ownerPlayerId'] as String?;
      if (owner == null || owner == after.playerId) continue;
      final was = previous[entry.key] as Map?;
      if (was == null) return PlacedPiece(entry.key, owner, what);
      // An upgrade replaces a settlement in place, so the key already existed.
      if (was['type'] != (entry.value as Map)['type'] &&
          (entry.value as Map)['type'] == 'CITY') {
        return PlacedPiece(entry.key, owner, 'city');
      }
    }
  }
  return null;
}
