import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PracticeTable, scenarios } from './table.mjs';
import { previewFixtures } from './fixtures.mjs';
import { command } from '../../packages/game-engine/test/helpers.mjs';
import { canSettle, canRoad } from '@island/game-engine';
import { isValid } from '@island/protocol';

for (const name of scenarios) test(`practice ${name} uses valid engine state and owner-only snapshot`, () => {
  const table = new PracticeTable(name), snapshot = table.snapshot();
  assert.equal(isValid('gameSnapshot', snapshot), true); assert.equal(snapshot.privateState.playerId, table.viewer);
  const output = JSON.stringify(snapshot);
  for (const [id, hand] of Object.entries(table.state.privateState)) if (id !== table.viewer) for (const card of hand.developmentCards) assert.ok(!output.includes(card.id));
  assert.ok(!output.includes('developmentDeck')); assert.ok(!output.includes('serverState'));
});
test('shared Dart preview fixtures still match the authoritative engine', () => {
  const saved = JSON.parse(readFileSync(new URL('../../packages/protocol/fixtures/ui-previews.json', import.meta.url), 'utf8'));
  const current = previewFixtures();
  // Scenario phase UUIDs arise from synthetic commands and need not be stable
  // across unrelated tests; previews and visible board/hand still must match.
  for (let i = 0; i < saved.length; i++) {
    assert.deepEqual(current[i].targets, saved[i].targets);
    assert.deepEqual(current[i].snapshot.publicState.board, saved[i].snapshot.publicState.board);
    assert.deepEqual(current[i].snapshot.privateState, saved[i].snapshot.privateState);
  }
});
test('practice plays both setup rounds through actual moves; duplicate IDs cannot place twice', () => {
  const table = new PracticeTable('setup');
  while (table.state.serverState.setup) {
    const p = table.state.publicState;
    const type = p.phase === 'SETUP_SETTLEMENT' ? 'PLACE_SETUP_SETTLEMENT' : 'PLACE_SETUP_ROAD';
    const payload = type === 'PLACE_SETUP_SETTLEMENT' ? { vertexId: Object.keys(p.board.vertices).find(v => canSettle(p, table.viewer, v, true)) } : { edgeId: p.board.vertices[table.state.serverState.setup.pendingVertexId].edgeIds.find(e => canRoad(p, table.viewer, e)) };
    const cmd = command(table.state, type, payload), first = table.submit(cmd), version = table.state.version;
    assert.equal(first.status, 'ACCEPTED'); assert.equal(table.submit(cmd).version, version); assert.equal(table.state.version, version);
    assert.equal(table.submit({ ...cmd, payload: {} }).status, 'REJECTED');
  }
  assert.equal(table.state.publicState.phase, 'AWAIT_ROLL');
});
test('practice winning purchase reaches real terminal state', () => {
  const table = new PracticeTable('victory'); const reply = table.submit(command(table.state, 'BUY_DEVELOPMENT_CARD'));
  assert.equal(reply.status, 'ACCEPTED'); assert.equal(table.state.publicState.phase, 'COMPLETE');
  assert.equal(table.snapshot().privateState.totalPoints, 10);
});
