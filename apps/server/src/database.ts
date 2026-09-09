import { Pool, type PoolClient } from 'pg';
import { PROTOCOL_VERSION, RULES_VERSION } from '@island/protocol';
import type { AppConfig } from './config.js';

export class Database {
  readonly pool: Pool;
  constructor(config: Pick<AppConfig, 'databaseUrl' | 'databaseTls'>) {
    this.pool = new Pool({ connectionString: config.databaseUrl, max: 5,
      connectionTimeoutMillis: 3000, idleTimeoutMillis: 10000,
      statement_timeout: 3000, query_timeout: 4000,
      ssl: config.databaseTls ? { rejectUnauthorized: true } : false });
    this.pool.on('error', () => { console.error('Database connection unavailable'); });
  }
  async ready(): Promise<void> {
    const result = await this.pool.query('SELECT version, protocol_version, rules_version, current_user AS role FROM app.schema_migrations ORDER BY version DESC LIMIT 1');
    const row = result.rows[0];
    if (!row || row.version !== 1 || row.protocol_version !== PROTOCOL_VERSION || row.rules_version !== RULES_VERSION || row.role !== 'island_runtime') {
      throw new Error('Database schema or runtime role incompatible');
    }
  }
  async transaction<T>(work: (client: PoolClient) => Promise<T>): Promise<T> {
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      await client.query("SET LOCAL idle_in_transaction_session_timeout = '5s'");
      const result = await work(client);
      await client.query('COMMIT');
      return result;
    } catch (error) {
      await client.query('ROLLBACK').catch(() => undefined);
      throw error;
    } finally { client.release(); }
  }
  async onApplicationShutdown(): Promise<void> { await this.pool.end(); }
}
