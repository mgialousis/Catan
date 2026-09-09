import { mkdir, copyFile } from 'node:fs/promises';
const root = new URL('../', import.meta.url);
const target = new URL('apps/mobile/assets/protocol/', root);
await mkdir(target, { recursive: true });
await copyFile(new URL('packages/protocol/schemas/v1.json', root), new URL('v1.json', target));
await copyFile(new URL('packages/protocol/events.json', root), new URL('events.json', target));
console.log('Flutter protocol assets synchronized from packages/protocol.');
