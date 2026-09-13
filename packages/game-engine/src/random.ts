/** Entropy is provided by the caller. The engine never reads system randomness. */
export interface RandomSource { int(upperExclusive: number): number; id(): string }
export type RandomDraw = { kind: 'INT'; label: string; upperExclusive: number; value: number } | { kind: 'ID'; label: string; value: string };
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export class RecordedRandom {
  readonly draws: RandomDraw[] = [];
  constructor(private readonly source: RandomSource) {}
  int(upperExclusive: number, label: string): number {
    const value = this.source.int(upperExclusive);
    if (!Number.isInteger(value) || value < 0 || value >= upperExclusive) throw new Error('Invalid entropy result');
    this.draws.push({ kind: 'INT', label, upperExclusive, value }); return value;
  }
  id(label: string): string {
    const value = this.source.id();
    if (!UUID.test(value)) throw new Error('Invalid generated identifier');
    this.draws.push({ kind: 'ID', label, value }); return value;
  }
  shuffle<T>(values: readonly T[], label: string): T[] {
    const result = [...values];
    for (let i = result.length - 1; i > 0; i--) {
      const j = this.int(i + 1, label); [result[i], result[j]] = [result[j]!, result[i]!];
    }
    return result;
  }
}
/** Fails if replay requests a different kind/range or leaves any original draws unused. */
export function replayRandom(draws: readonly RandomDraw[]): RandomSource & { assertConsumed(): void } {
  let position = 0;
  return {
    int(upperExclusive) { const draw = draws[position++]; if (draw?.kind !== 'INT' || draw.upperExclusive !== upperExclusive) throw new Error('Replay entropy mismatch'); return draw.value; },
    id() { const draw = draws[position++]; if (draw?.kind !== 'ID') throw new Error('Replay identifier mismatch'); return draw.value; },
    assertConsumed() { if (position !== draws.length) throw new Error('Unused replay entropy'); },
  };
}
