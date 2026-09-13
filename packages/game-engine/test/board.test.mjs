import test from 'node:test';
import assert from 'node:assert/strict';
import { topology, generateBoard, RecordedRandom, assertBoard, validRedNumbers } from '../dist/index.js';
import { seeded } from './helpers.mjs';

test('integer board topology has canonical counts and stable serialized IDs', () => {
  const board = topology();
  assert.deepEqual([board.hexes, board.vertices, board.edges, board.ports].map(v => Object.keys(v).length), [19, 54, 72, 9]);
  assert.equal(Object.values(board.edges).filter(e => e.hexIds.length === 1).length, 30);
  assert.deepEqual(topology(), JSON.parse(JSON.stringify(board)));
});
test('200 seeded layouts preserve inventory, adjacency, coast and nonadjacent red numbers', () => {
  for (let seed = 1; seed <= 200; seed++) assertBoard(generateBoard(new RecordedRandom(seeded(seed))));
});
test('bounded fallback handles every desert location even when shuffles never succeed', () => {
  const desertPositions = new Set();
  for (let seed = 1; seed <= 100; seed++) {
    const board = generateBoard(new RecordedRandom(seeded(seed)), 0);
    desertPositions.add(Object.keys(board.hexes).find(id => board.hexes[id].terrain === 'DESERT'));
    assert.equal(validRedNumbers(board), true); assertBoard(board);
  }
  assert.equal(desertPositions.size, 19);
});
