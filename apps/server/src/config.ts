export interface AppConfig {
  port: number; databaseUrl: string; databaseTls: boolean; origins: string[];
  issuer: string; jwksUrl: string; localJwtSecret?: string;
}
export function loadConfig(env: NodeJS.ProcessEnv = process.env): AppConfig {
  const required = (name: string): string => {
    const value = env[name];
    if (!value) throw new Error(`Missing configuration: ${name}`);
    return value;
  };
  const production = env.NODE_ENV === 'production';
  const issuer = required('SUPABASE_JWT_ISSUER');
  const jwksUrl = env.SUPABASE_JWKS_URL ?? `${issuer}/.well-known/jwks.json`;
  const database = new URL(required('DATABASE_URL'));
  if (!['postgres:', 'postgresql:'].includes(database.protocol)) throw new Error('Invalid database URL');
  // pg connection-string SSL flags can override the explicit verified-TLS setting.
  // One configuration source owns TLS; do not allow a URL to silently disable it.
  for (const key of ['sslmode', 'sslcert', 'sslkey', 'sslrootcert']) database.searchParams.delete(key);
  const databaseUrl = database.toString();
  const origins = required('WEB_ORIGINS').split(',').map(value => value.trim());
  for (const origin of origins) {
    const url = new URL(origin);
    if (url.origin !== origin || (production && url.protocol !== 'https:')) throw new Error('Invalid web origin');
  }
  if (production && (!issuer.startsWith('https://') || !jwksUrl.startsWith('https://') || env.LOCAL_JWT_SECRET)) {
    throw new Error('Production requires HTTPS JWKS authentication');
  }
  const databaseTls = env.DATABASE_TLS === 'true';
  if (production && !databaseTls) throw new Error('Production requires database TLS');
  const port = Number(env.PORT ?? 3000);
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error('Invalid port');
  return { port, databaseUrl, databaseTls, origins, issuer, jwksUrl, localJwtSecret: env.LOCAL_JWT_SECRET };
}
