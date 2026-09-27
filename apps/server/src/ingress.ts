import { isIP } from 'node:net';
import { clientAddress } from './client-address.js';

/**
 * What kind of address a hop is, never which one. The probe below reports the
 * shape of a forwarding chain so the proxy hop count can be measured rather
 * than guessed, without an address ever reaching the log.
 */
export type HopKind = 'public' | 'private' | 'loopback' | 'invalid';

const unmapped = (address: string) => address.trim().replace(/^::ffff:(?=\d+\.\d+\.\d+\.\d+$)/i, '');

export function classify(raw: string | undefined): HopKind {
  if (!raw) return 'invalid';
  const address = unmapped(raw);
  const family = isIP(address);
  if (family === 4) {
    const [a, b] = address.split('.').map(Number) as [number, number];
    if (a === 127) return 'loopback';
    // RFC 1918, carrier-grade NAT (cloud-internal networks use it) and link-local.
    if (a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127) || (a === 169 && b === 254)) return 'private';
    return 'public';
  }
  if (family === 6) {
    const lower = address.toLowerCase();
    if (lower === '::1') return 'loopback';
    if (/^f[cd]/.test(lower) || /^fe[89ab]/.test(lower)) return 'private';
    return 'public';
  }
  return 'invalid';
}

/** Headers an edge may set to name the real client. Cloudflare sets the first. */
const EDGE_HEADERS = ['cf-connecting-ip', 'true-client-ip', 'x-real-ip'] as const;
type Headers = Readonly<Record<string, string | string[] | undefined>>;

export interface IngressShape {
  /** Every hop in arrival order: the X-Forwarded-For entries, then the socket peer. */
  chain: HopKind[];
  /** For each edge header that arrived, where its address sits in `chain`; -1 when it is not in the chain at all. */
  edgeClientAt: Partial<Record<(typeof EDGE_HEADERS)[number], number>>;
}

export function describeIngress(peer: string | undefined, headers: Headers): IngressShape {
  const forwarded = typeof headers['x-forwarded-for'] === 'string' ? headers['x-forwarded-for'].split(',').map(unmapped) : [];
  const hops = [...forwarded, unmapped(peer ?? '')];
  const edgeClientAt: IngressShape['edgeClientAt'] = {};
  for (const name of EDGE_HEADERS) {
    const value = headers[name];
    // The rightmost match is the entry a proxy appended. A client can prepend
    // anything it likes to X-Forwarded-For, including its own address.
    if (typeof value === 'string' && value.trim()) edgeClientAt[name] = hops.lastIndexOf(unmapped(value));
  }
  return { chain: hops.map(classify), edgeClientAt };
}

/** The TRUSTED_PROXY_HOPS value that makes clientAddress() select position `index` of a chain. */
export function hopsSelecting(chainLength: number, index: number): number { return chainLength - 1 - index; }

/**
 * Logs each distinct forwarding shape once, and warns when the configured hop
 * count keys per-IP limits on a proxy rather than a client -- in which case
 * every player shares one budget and one misbehaving client throttles them all.
 */
export class IngressProbe {
  private readonly seen = new Set<string>();
  constructor(private readonly configuredHops: number, private readonly log: (line: string) => void = line => console.log(line)) {}

  observe(peer: string | undefined, headers: Headers): void {
    const shape = describeIngress(peer, headers);
    const key = JSON.stringify(shape);
    // Bounded: a flood of odd shapes cannot grow memory or the log.
    if (this.seen.has(key) || this.seen.size >= 16) return;
    this.seen.add(key);
    const measured = Object.entries(shape.edgeClientAt)
      .map(([name, at]) => at < 0 ? `${name} not in chain` : `${name} at hop ${at} => TRUSTED_PROXY_HOPS=${hopsSelecting(shape.chain.length, at)}`);
    this.log(`Ingress shape [${shape.chain.join(', ')}]${measured.length ? `; ${measured.join('; ')}` : ''} (configured ${this.configuredHops}).`);
    // Exactly the address the limiters use, so the warning cannot disagree with
    // them. A loopback peer is not exempt: on Render the proxy itself arrives
    // over loopback. Local development carries no public hop, so stays quiet.
    const keyed = classify(clientAddress(peer, headers['x-forwarded-for'], this.configuredHops));
    if (keyed !== 'public' && shape.chain.includes('public')) {
      this.log(`Ingress warning: TRUSTED_PROXY_HOPS=${this.configuredHops} keys per-IP limits on a ${keyed} hop, so every client behind it shares one budget.`);
    }
  }
}
