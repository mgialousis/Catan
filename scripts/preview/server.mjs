import { createServer } from 'node:http';
import { Server } from 'socket.io';
import { PracticeTable, scenarios } from './table.mjs';
import { UUID } from '@island/game-engine';

// Separate developer process, loopback only, no credentials, no database. Not deployable as the API.
export async function startPracticeServer(port = 3001) {
  const http = createServer((req, res) => { res.writeHead(200, { 'Content-Type': 'text/plain' }); res.end('Island Table local practice engine\n'); });
  const io = new Server(http, { transports: ['websocket'], maxHttpBufferSize: 16384,
    allowRequest: (req, callback) => { const origin = req.headers.origin; let allowed = !origin;
      try { const url = new URL(origin); allowed = url.protocol === 'http:' && ['localhost', '127.0.0.1'].includes(url.hostname); } catch { /* Native client */ }
      callback(allowed ? null : 'Local browser only', allowed);
    },
  });
  const tables = new Map();
  io.on('connection', socket => {
    const name = socket.handshake.auth.scenario ?? 'setup';
    const token = socket.handshake.auth.clientToken;
    if (!scenarios.includes(name) || !UUID.test(token ?? '') || (!tables.has(token) && tables.size >= 64)) return socket.disconnect(true);
    if (!tables.has(token)) tables.set(token, { table: new PracticeTable(name), sockets: new Set(), timer: null });
    const entry = tables.get(token), table = entry.table;
    clearTimeout(entry.timer); entry.sockets.add(socket.id);
    socket.on('disconnect', () => {
      entry.sockets.delete(socket.id);
      if (!entry.sockets.size) entry.timer = setTimeout(() => tables.delete(token), 5 * 60_000).unref();
    });
    socket.on('practice.sync', () => socket.emit('game.snapshot', table.snapshot()));
    socket.on('practice.command', (cmd, ack) => {
      if (typeof ack !== 'function') return;
      try {
        const reply = table.submit(cmd);
        socket.emit('game.snapshot', table.snapshot());
        socket.emit('practice.effects', { activity: reply.activity ?? [], draws: reply.draws ?? [] });
        ack(reply);
      } catch { ack({ commandId: cmd?.commandId, status: 'REJECTED', error: { code: 'SERVICE_UNAVAILABLE', retryable: true } }); }
    });
    socket.emit('game.snapshot', table.snapshot());
  });
  await new Promise(resolve => http.listen(port, '127.0.0.1', resolve));
  return { io, port: http.address().port, close: () => new Promise(resolve => io.close(() => { for (const entry of tables.values()) clearTimeout(entry.timer); resolve(); })) };
}
if (process.argv[1] && import.meta.url === new URL(process.argv[1], 'file:').href) {
  const server = await startPracticeServer();
  console.log(`Local practice engine on 127.0.0.1:${server.port}; no database or production rooms.`);
  for (const signal of ['SIGTERM', 'SIGINT']) process.once(signal, async () => { await server.close(); process.exit(0); });
}
