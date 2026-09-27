import { test } from 'node:test';
import assert from 'node:assert/strict';
import { classify, describeIngress, hopsSelecting, IngressProbe } from '../dist/ingress.js';
import { clientAddress } from '../dist/client-address.js';

test('addresses are classified by kind, including the ranges proxies live in', () => {
  for (const address of ['203.0.113.7', '8.8.8.8', '172.15.0.1', '172.32.0.1', '100.63.0.1', '100.128.0.1', '2001:db8::1'])
    assert.equal(classify(address), 'public', address);
  for (const address of ['10.0.0.1', '172.16.0.1', '172.31.255.255', '192.168.1.1', '100.64.0.1', '100.127.255.255', '169.254.1.1', 'fc00::1', 'fd12::1', 'fe80::1'])
    assert.equal(classify(address), 'private', address);
  assert.equal(classify('127.0.0.1'), 'loopback');
  assert.equal(classify('::1'), 'loopback');
  // Node reports IPv4 peers on dual-stack sockets as IPv4-mapped IPv6.
  assert.equal(classify('::ffff:10.1.2.3'), 'private');
  assert.equal(classify('::ffff:203.0.113.7'), 'public');
  for (const bad of [undefined, '', 'unknown', 'not an address', '999.1.1.1']) assert.equal(classify(bad), 'invalid', String(bad));
});

test('a chain is described by shape, with the edge client located in it', () => {
  const shape = describeIngress('10.0.0.5', {
    'x-forwarded-for': '203.0.113.7, 198.51.100.9',
    'cf-connecting-ip': '203.0.113.7',
  });
  assert.deepEqual(shape.chain, ['public', 'public', 'private']);
  assert.equal(shape.edgeClientAt['cf-connecting-ip'], 0);
  // An edge header naming an address the chain does not contain is reported, not guessed at.
  assert.equal(describeIngress('10.0.0.5', { 'cf-connecting-ip': '203.0.113.7' }).edgeClientAt['cf-connecting-ip'], -1);
  assert.deepEqual(describeIngress('127.0.0.1', {}).chain, ['loopback']);
  // A client prepending its own address must not move the measured position:
  // the entry the proxy appended is the rightmost one.
  const spoofed = describeIngress('10.0.0.5', { 'x-forwarded-for': '203.0.113.7, 203.0.113.7, 198.51.100.9', 'cf-connecting-ip': '203.0.113.7' });
  assert.equal(spoofed.edgeClientAt['cf-connecting-ip'], 1);
  assert.equal(hopsSelecting(spoofed.chain.length, 1), 2, 'still two hops, exactly as without the prepended entry');
});

// The number the probe reports has to be the number that works: feeding it to
// clientAddress must select exactly the hop the edge said was the client.
test('the reported hop count makes clientAddress select that hop', () => {
  const chains = [
    ['203.0.113.7', '10.0.0.5'],
    ['203.0.113.7', '198.51.100.9', '10.0.0.5'],
    ['192.0.2.1', '203.0.113.7', '198.51.100.9', '10.0.0.5'],
  ];
  for (const chain of chains) {
    const peer = chain.at(-1), forwarded = chain.slice(0, -1).join(', ');
    for (let index = 0; index < chain.length - 1; index++) {
      const hops = hopsSelecting(chain.length, index);
      assert.equal(clientAddress(peer, forwarded, hops), chain[index], `${chain} at ${index} with ${hops} hops`);
    }
  }
});

test('the probe logs each shape once, bounded, and never an address', () => {
  const lines = [];
  const probe = new IngressProbe(0, line => lines.push(line));
  const request = ['10.0.0.5', { 'x-forwarded-for': '203.0.113.7, 198.51.100.9', 'cf-connecting-ip': '203.0.113.7' }];
  probe.observe(...request);
  probe.observe(...request);
  assert.equal(lines.filter(l => l.startsWith('Ingress shape')).length, 1, 'a repeated shape is logged once');
  assert.match(lines[0], /cf-connecting-ip at hop 0 => TRUSTED_PROXY_HOPS=2/);
  assert.match(lines.join('\n'), /Ingress warning: TRUSTED_PROXY_HOPS=0 keys per-IP limits on a private hop/,
    'zero hops behind a proxy is exactly the misconfiguration this exists to surface');
  // Distinct shapes are bounded, so a flood of odd headers cannot fill the log.
  for (let i = 0; i < 40; i++) probe.observe('10.0.0.5', { 'x-forwarded-for': Array(i + 1).fill('203.0.113.7').join(', ') });
  assert.ok(lines.filter(l => l.startsWith('Ingress shape')).length <= 16);
  for (const line of lines) assert.doesNotMatch(line, /\d+\.\d+\.\d+\.\d+|::/, `an address reached the log: ${line}`);
});

// Measured on Render, 27 September: its proxy reaches the app over loopback
// and appends the client, so zero hops keyed every player to 127.0.0.1.
test('a proxy arriving over loopback is warned about, and one hop fixes it', () => {
  const measured = ['127.0.0.1', { 'x-forwarded-for': '203.0.113.7', 'cf-connecting-ip': '203.0.113.7' }];
  const zero = [];
  new IngressProbe(0, line => zero.push(line)).observe(...measured);
  assert.match(zero.join('\n'), /Ingress warning: TRUSTED_PROXY_HOPS=0 keys per-IP limits on a loopback hop/);
  const one = [];
  new IngressProbe(1, line => one.push(line)).observe(...measured);
  assert.equal(one.filter(l => l.startsWith('Ingress warning')).length, 0);
  // A client forging its own entry is ignored: one hop takes the entry the proxy appended.
  assert.equal(clientAddress('127.0.0.1', '192.0.2.123, 203.0.113.7', 1), '203.0.113.7');
});

test('the right hop count raises no warning', () => {
  const lines = [];
  new IngressProbe(2, line => lines.push(line))
    .observe('10.0.0.5', { 'x-forwarded-for': '203.0.113.7, 198.51.100.9', 'cf-connecting-ip': '203.0.113.7' });
  assert.equal(lines.filter(l => l.startsWith('Ingress warning')).length, 0);
  const local = [];
  new IngressProbe(0, line => local.push(line)).observe('127.0.0.1', {});
  assert.equal(local.filter(l => l.startsWith('Ingress warning')).length, 0, 'local development has no proxy to warn about');
});
