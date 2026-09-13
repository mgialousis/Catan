import test from 'node:test';
import assert from 'node:assert/strict';
import { longestRoad, award } from '../dist/index.js';

function graph(pairs, blocked = [], own = []) {
  const board = { edges: {} }, roads = {}, buildings = {};
  pairs.forEach(([a, b], i) => { board.edges[`e-${i}`] = { vertexIds: [`v-${a}`, `v-${b}`] }; roads[`e-${i}`] = { ownerPlayerId: 'A' }; });
  for (const v of blocked) buildings[`v-${v}`] = { ownerPlayerId: 'B' };
  for (const v of own) buildings[`v-${v}`] = { ownerPlayerId: 'A' };
  return { board, roads, buildings };
}
const fixtures = [
  ['empty', [], [], [], 0],
  ['line at threshold', [[0,1],[1,2],[2,3],[3,4],[4,5]], [], [], 5],
  ['branch excludes a third arm', [[0,1],[1,2],[2,3],[2,4],[4,5]], [], [], 4],
  ['hexagonal loop', [[0,1],[1,2],[2,3],[3,4],[4,5],[5,0]], [], [], 6],
  ['loop with tail', [[0,1],[1,2],[2,3],[3,4],[4,5],[5,0],[0,6],[6,7]], [], [], 8],
  ['figure eight', [[0,1],[1,2],[2,3],[3,4],[4,5],[5,0],[0,6],[6,7],[7,8],[8,9],[9,10],[10,0]], [], [], 12],
  ['opponent splits a line', [[0,1],[1,2],[2,3],[3,4],[4,5]], [2], [], 3],
  ['own building does not split', [[0,1],[1,2],[2,3],[3,4],[4,5]], [], [2], 5],
  ['opponent cuts loop passage but permits two endpoints', [[0,1],[1,2],[2,3],[3,4],[4,5],[5,0]], [0], [], 6],
  ['full supply', Array.from({length:15}, (_,i)=>[i,i+1]), [], [], 15],
];
for (const [name, pairs, blocked, own, expected] of fixtures) test(`longest road: ${name}`, () => assert.equal(longestRoad(graph(pairs, blocked, own), 'A'), expected));

// Independent small-graph oracle: enumerate edge permutations and orient each entire sequence.
// It has no DFS-by-vertex cache or bit masks in common with the production algorithm.
function oracle(pairs, blocked) {
  function walkable(order) {
    for (const start of pairs[order[0]]) {
      let at = start, valid = true;
      for (let i = 0; i < order.length; i++) {
        if (i && blocked.includes(at)) { valid = false; break; }
        const [a,b] = pairs[order[i]];
        if (at === a) at = b; else if (at === b) at = a; else { valid = false; break; }
      }
      if (valid) return true;
    }
    return false;
  }
  let best = 0;
  function permutations(order, remaining) {
    if (order.length && walkable(order)) best = Math.max(best, order.length);
    for (const edge of remaining) permutations([...order, edge], remaining.filter(i => i !== edge));
  }
  permutations([], pairs.map((_,i)=>i)); return best;
}
test('road lengths match an independent edge-permutation oracle for small networks', () => {
  const all = [[0,1],[1,2],[2,0],[2,3],[3,4],[4,0]];
  for (let mask = 1; mask < 64; mask++) for (const blocked of [[], [2]]) {
    const pairs = all.filter((_, i) => mask & (1 << i));
    assert.equal(longestRoad(graph(pairs, blocked), 'A'), oracle(pairs, blocked), `mask=${mask}, blocked=${blocked}`);
  }
});
test('award thresholds, tie retention, transfer and losing eligibility', () => {
  assert.deepEqual(award({a:4,b:3},null,5), {holderPlayerId:null,size:0});
  assert.equal(award({a:5,b:5},'a',5).holderPlayerId, 'a');
  assert.equal(award({a:5,b:6},'a',5).holderPlayerId, 'b');
  assert.equal(award({a:4,b:5,c:5},'a',5).holderPlayerId, null);
  assert.equal(award({a:3,b:2},null,3).holderPlayerId, 'a');
  assert.equal(award({a:3,b:3},'a',3).holderPlayerId, 'a');
});
