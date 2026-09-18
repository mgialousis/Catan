import { Pool, type PoolClient } from 'pg';
import { PROTOCOL_VERSION, RULES_VERSION } from '@island/protocol';
import type { AppConfig } from './config.js';

/**
 * Schema versions this build understands, newest last.
 *
 * A build accepting more than one exists so a migration is not a lockstep with
 * its deploy. Pinning to a single version means the API crash-loops in either
 * order: migrate first and the running build rejects the new schema, deploy
 * first and the new build rejects the old one. Accepting both lets the code go
 * out ahead of the migration. Drop the older entry once every environment has
 * moved past it.
 */
const SUPPORTED_SCHEMA_VERSIONS = [1, 2];

export class Database {
  readonly pool: Pool;
  onUnavailable?: () => void;
  constructor(config: Pick<AppConfig, 'databaseUrl' | 'databaseTls'>) {
    this.pool = new Pool({ connectionString: config.databaseUrl, max: 5,
      connectionTimeoutMillis: 3000, idleTimeoutMillis: 10000,
      statement_timeout: 3000, query_timeout: 4000,
      ssl: config.databaseTls ? { rejectUnauthorized: true } : false });
    this.pool.on('error', () => { this.onUnavailable?.(); console.error('Database connection unavailable'); });
  }
  async ready(): Promise<void> {
    const result = await this.pool.query('SELECT version, protocol_version, rules_version, current_user AS role FROM app.schema_migrations ORDER BY version DESC LIMIT 1');
    const row = result.rows[0];
    if (!row || !SUPPORTED_SCHEMA_VERSIONS.includes(row.version) || row.protocol_version !== PROTOCOL_VERSION || row.rules_version !== RULES_VERSION || row.role !== 'island_runtime') {
      throw new Error('Database schema or runtime role incompatible');
    }
  }
  async transaction<T>(work: (client: PoolClient) => Promise<T>): Promise<T> {
    let client: PoolClient;
    try { client = await this.pool.connect(); } catch (error) { this.onUnavailable?.(); throw error; }
    // pg emits errors on checked-out clients as well as rejecting their queries.
    // Handle both paths, and never return a broken connection to the pool.
    let connectionError: Error | undefined;
    const lost = (error: Error) => { connectionError = error; this.onUnavailable?.(); };
    client.on('error', lost);
    try {
      await client.query('BEGIN');
      await client.query("SET LOCAL idle_in_transaction_session_timeout = '5s'");
      const result = await work(client);
      await client.query('COMMIT');
      return result;
    } catch (error) {
      const code = (error as {code?:string}).code ?? '';
      if (/^(08|53|57P0)/.test(code) || ['ECONNRESET','ECONNREFUSED','ETIMEDOUT','EPIPE'].includes(code) || /connection.*(closed|terminated)|query read timeout/i.test((error as Error).message)) this.onUnavailable?.();
      await client.query('ROLLBACK').catch(() => undefined);
      throw error;
    } finally { client.release(connectionError); client.removeListener('error', lost); }
  }
  async onApplicationShutdown(): Promise<void> { await this.pool.end(); }
}
