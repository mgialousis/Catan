import { isIP } from 'node:net';

/** Ignore forwarding headers unless the operator has verified the ingress hop count. */
export function clientAddress(peer: string | undefined, forwarded: string | string[] | undefined, trustedHops = 0): string {
  if (!trustedHops || typeof forwarded !== 'string') return peer ?? 'unknown';
  const chain = [...forwarded.split(',').map(value => value.trim()), peer ?? ''];
  const address = chain[chain.length - 1 - trustedHops];
  return address && isIP(address) ? address : peer ?? 'unknown';
}
