import { readFileSync } from 'node:fs';
import { Client } from 'pg';
import { pathToFileURL } from 'node:url';

/** Operator-only compaction. Receipt identities/hashes/statuses are retained indefinitely. */
export async function retain(db, { apply = false, roomIds = null, actorKeys = null } = {}) {
  await db.query('BEGIN');
  try {
    // Exclusive runtime lock prevents concurrent commands while terminal rows are removed.
    await db.query('SELECT id FROM app.runtime_control WHERE id=1 FOR UPDATE');
    const terminal = (await db.query("SELECT id FROM app.rooms WHERE active_slot IS NULL AND ended_at < clock_timestamp()-interval '30 days' AND ($1::uuid[] IS NULL OR id=ANY($1)) ORDER BY id FOR UPDATE", [roomIds])).rows.map(row => row.id);
    const eligible = `($1::text[] IS NULL OR actor_key=ANY($1)) AND created_at < clock_timestamp()-interval '30 days' AND response IS NOT NULL
      AND (room_id IS NULL OR room_id IN (SELECT id FROM app.rooms WHERE active_slot IS NULL AND ended_at < clock_timestamp()-interval '30 days'))`;
    const compact = (await db.query(`SELECT count(*)::int AS n FROM app.command_receipts WHERE ${eligible}`, [actorKeys])).rows[0].n;
    if (apply) {
      await db.query(`UPDATE app.command_receipts SET response=null WHERE ${eligible}`, [actorKeys]);
      for (const id of terminal) {
        // All receipts linked to a purged room become compact tombstones, even recent retries.
        await db.query('UPDATE app.command_receipts SET response=null,room_id=null WHERE room_id=$1', [id]);
        await db.query('DELETE FROM app.outbox_events WHERE room_id=$1', [id]);
        await db.query('DELETE FROM app.move_logs WHERE room_id=$1', [id]);
        await db.query('DELETE FROM app.game_states WHERE room_id=$1', [id]);
        await db.query('DELETE FROM app.players WHERE room_id=$1', [id]);
        await db.query('DELETE FROM app.rooms WHERE id=$1', [id]);
      }
    }
    await db.query(apply ? 'COMMIT' : 'ROLLBACK');
    return { applied: apply, terminalRooms: terminal.length, receiptBodies: compact };
  } catch (error) { await db.query('ROLLBACK'); throw error; }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const local = JSON.parse(readFileSync('.local/test-env.json', 'utf8'));
  if (!['127.0.0.1', 'localhost'].includes(new URL(local.adminDatabaseUrl).hostname)) throw new Error('This operator helper supports local databases only');
  const db = new Client({ connectionString: local.adminDatabaseUrl, connectionTimeoutMillis: 3000, statement_timeout: 10000 });
  try { await db.connect(); console.log(await retain(db, { apply: process.argv.includes('--apply') })); }
  finally { await db.end(); }
}
