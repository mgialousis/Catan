import type { Board, VertexId, EdgeId, HexId, ResourceType } from '@island/protocol/contracts';
import { RecordedRandom } from './random.js';

type Mutable<T> = { -readonly [K in keyof T]: T[K] extends object ? Mutable<T[K]> : T[K] };
type Terrain = Board['hexes'][HexId]['terrain'];
export const TERRAIN_RESOURCE: Readonly<Record<Terrain, ResourceType | null>> = { HILLS: 'brick', FOREST: 'lumber', PASTURE: 'wool', FIELDS: 'grain', MOUNTAINS: 'ore', DESERT: null };
export const TERRAINS: readonly Terrain[] = ['HILLS', 'HILLS', 'HILLS', 'FOREST', 'FOREST', 'FOREST', 'FOREST', 'PASTURE', 'PASTURE', 'PASTURE', 'PASTURE', 'FIELDS', 'FIELDS', 'FIELDS', 'FIELDS', 'MOUNTAINS', 'MOUNTAINS', 'MOUNTAINS', 'DESERT'];
export const TOKENS = [2, 3, 3, 4, 4, 5, 5, 6, 6, 8, 8, 9, 9, 10, 10, 11, 11, 12] as const;
const corners = [[0, 2], [1, 1], [1, -1], [0, -2], [-1, -1], [-1, 1]] as const;
const key = (x: number, y: number) => `${x},${y}`;
const compare = (a: readonly number[], b: readonly number[]) => a[0]! - b[0]! || a[1]! - b[1]!;

/** Pointy hexes, integer-lattice vertices and canonical numeric ordering. */
export function topology(): Board {
  const centers: [number, number][] = [];
  for (let q = -2; q <= 2; q++) for (let r = -2; r <= 2; r++) if (Math.abs(q + r) <= 2) centers.push([q, r]);
  const points = new Map<string, [number, number]>();
  for (const [q, r] of centers) for (const [dx, dy] of corners) { const x = 2 * q + r + dx, y = 3 * r + dy; points.set(key(x, y), [x, y]); }
  const vertexIds = new Map<string, VertexId>();
  const board: Mutable<Board> = { topologyVersion: 1, hexes: {}, vertices: {}, edges: {}, ports: {} };
  [...points.values()].sort(compare).forEach(([x, y], i) => { const id: VertexId = `v-${i}`; vertexIds.set(key(x, y), id); board.vertices[id] = { x, y, hexIds: [], edgeIds: [] }; });
  const edgeHexes = new Map<string, { ends: [VertexId, VertexId]; hexes: HexId[] }>();
  centers.forEach(([q, r], i) => {
    const id: HexId = `h-${i}`;
    const vertices = corners.map(([dx, dy]) => vertexIds.get(key(2 * q + r + dx, 3 * r + dy))!);
    board.hexes[id] = { q, r, terrain: 'DESERT', number: null, vertexIds: vertices };
    vertices.forEach((v, j) => {
      board.vertices[v]!.hexIds.push(id);
      const ends = [v, vertices[(j + 1) % 6]!].sort((a, b) => Number(a.slice(2)) - Number(b.slice(2))) as [VertexId, VertexId];
      const k = ends.join(':');
      if (!edgeHexes.has(k)) edgeHexes.set(k, { ends, hexes: [] });
      edgeHexes.get(k)!.hexes.push(id);
    });
  });
  [...edgeHexes.values()].sort((a, b) => compare(a.ends.map(v => Number(v.slice(2))), b.ends.map(v => Number(v.slice(2))))).forEach(({ ends, hexes }, i) => {
    const id: EdgeId = `e-${i}`; board.edges[id] = { vertexIds: ends, hexIds: hexes };
    for (const v of ends) board.vertices[v]!.edgeIds.push(id);
  });
  // Walk the 30-edge coast; nine ports, separated by at least one unused edge.
  const coast = Object.entries(board.edges).filter(([, e]) => e.hexIds.length === 1) as [EdgeId, Mutable<Board>['edges'][EdgeId]][];
  let vertex = coast.flatMap(([, e]) => e.vertexIds).sort((a, b) => Number(a.slice(2)) - Number(b.slice(2)))[0]!;
  const walked = new Set<EdgeId>(), cycle: EdgeId[] = [];
  while (cycle.length < coast.length) {
    const [id, edge] = coast.find(([id, edge]) => !walked.has(id) && edge.vertexIds.includes(vertex))!;
    walked.add(id); cycle.push(id); vertex = edge.vertexIds.find(v => v !== vertex)!;
  }
  [0, 3, 6, 10, 13, 16, 20, 23, 26].forEach((index, i) => { board.ports[`p-${i}`] = { vertexIds: [...board.edges[cycle[index]!]!.vertexIds], resourceType: null, ratio: 3 }; });
  return board;
}

export function adjacentHexes(board: Board, a: HexId, b: HexId): boolean {
  const first = board.hexes[a]!, second = board.hexes[b]!;
  const dq = first.q - second.q, dr = first.r - second.r;
  return Math.max(Math.abs(dq), Math.abs(dr), Math.abs(dq + dr)) === 1;
}
export function validRedNumbers(board: Board): boolean {
  const red = (Object.keys(board.hexes) as HexId[]).filter(h => [6, 8].includes(board.hexes[h]!.number ?? 0));
  return red.every((a, i) => red.slice(i + 1).every(b => !adjacentHexes(board, a, b)));
}

export function generateBoard(random: RecordedRandom, attempts = 64): Board {
  const board = topology() as Mutable<Board>, ids = Object.keys(board.hexes) as HexId[];
  const terrain = random.shuffle(TERRAINS, 'terrain-layout');
  ids.forEach((id, i) => { board.hexes[id]!.terrain = terrain[i]!; });
  const fertile = ids.filter(id => board.hexes[id]!.terrain !== 'DESERT');
  let placed = false;
  for (let attempt = 0; attempt < Math.max(0, Math.min(attempts, 64)); attempt++) {
    const tokens = random.shuffle(TOKENS, 'number-layout');
    fertile.forEach((id, i) => { board.hexes[id]!.number = tokens[i]!; });
    if (validRedNumbers(board)) { placed = true; break; }
  }
  if (!placed) {
    // Bounded fallback: exhaustively find the first independent four fertile hexes (< 4,000 sets).
    const choose = (start: number, selected: HexId[]): HexId[] | undefined => {
      if (selected.length === 4) return selected;
      for (let i = start; i < fertile.length; i++) {
        const id = fertile[i]!;
        if (selected.every(other => !adjacentHexes(board, id, other))) { const result = choose(i + 1, [...selected, id]); if (result) return result; }
      }
      return undefined;
    };
    const red = choose(0, []);
    if (!red) throw new Error('Invalid topology for fallback layout');
    const ordinary = TOKENS.filter(n => n !== 6 && n !== 8);
    fertile.forEach(id => { const i = red.indexOf(id); board.hexes[id]!.number = i >= 0 ? (i < 2 ? 6 : 8) : ordinary.shift()!; });
  }
  const ports = random.shuffle<ResourceType | null>([null, null, null, null, 'brick', 'lumber', 'wool', 'grain', 'ore'], 'port-layout');
  Object.values(board.ports).forEach((port, i) => { port.resourceType = ports[i]!; port.ratio = port.resourceType === null ? 3 : 2; });
  return board;
}
