import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { applyCommand, projectGame } from '@island/game-engine';
import { isValid } from '@island/protocol';
import { scenario, scenarios } from './table.mjs';
import { command, seeded, now } from '../../packages/game-engine/test/helpers.mjs';
export function previewFixtures() {
  return scenarios.map(name => {
    const { state, viewer } = scenario(name), snapshot = projectGame(state, viewer, now), targets = {};
    if (!isValid('gameSnapshot', snapshot)) throw new Error(`Invalid snapshot: ${name}`);
    for (const type of ['PLACE_SETUP_SETTLEMENT', 'PLACE_SETUP_ROAD', 'BUILD_ROAD', 'BUILD_SETTLEMENT', 'BUILD_CITY', 'PLACE_FREE_ROAD', 'MOVE_ROBBER']) {
      const key = type === 'MOVE_ROBBER' ? 'hexId' : type.includes('ROAD') ? 'edgeId' : 'vertexId';
      const ids = Object.keys(state.publicState.board[key === 'hexId' ? 'hexes' : key === 'edgeId' ? 'edges' : 'vertices']);
      targets[type] = ids.filter(id => {
        try { applyCommand(state, viewer, command(state, type, { [key]: id }), { now, random: seeded(999) }); return true; }
        catch (error) { if (!error.code) throw error; return false; }
      });
    }
    return { name, snapshot, targets };
  });
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  // One record per line keeps this generated file compact; no copies are embedded in Dart.
  writeFileSync(new URL('../../packages/protocol/fixtures/ui-previews.json', import.meta.url), '[\n' + previewFixtures().map(f => JSON.stringify(f)).join(',\n') + '\n]\n');
  console.log('Updated engine-derived UI scenarios and legal-target expectations.');
}
