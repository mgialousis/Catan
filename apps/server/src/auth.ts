import { createRemoteJWKSet, errors, jwtVerify, type JWTVerifyGetKey } from 'jose';
import type { AppConfig } from './config.js';

export class AuthFailure extends Error {
  constructor(readonly code: 'UNAUTHENTICATED' | 'TOKEN_EXPIRED' = 'UNAUTHENTICATED') { super(code); }
}
export interface Identity { readonly userId: string; readonly expiresAt: number }
export class TokenVerifier {
  private readonly key: Uint8Array | JWTVerifyGetKey;
  constructor(private readonly config: Pick<AppConfig, 'issuer' | 'jwksUrl' | 'localJwtSecret'>, key?: JWTVerifyGetKey) {
    this.key = key ?? (config.localJwtSecret
      ? new TextEncoder().encode(config.localJwtSecret)
      : createRemoteJWKSet(new URL(config.jwksUrl), { timeoutDuration: 3000, cooldownDuration: 30000 }));
  }
  async verify(token: unknown): Promise<Identity> {
    if (typeof token !== 'string' || token.length === 0 || token.length > 8192) throw new AuthFailure();
    try {
      const options = {
        issuer: this.config.issuer, audience: 'authenticated',
        algorithms: this.config.localJwtSecret ? ['HS256'] : ['ES256', 'RS256'],
        requiredClaims: ['sub', 'exp', 'iat', 'iss', 'aud'], clockTolerance: 2,
      };
      const { payload } = this.key instanceof Uint8Array
        ? await jwtVerify(token, this.key, options)
        : await jwtVerify(token, this.key, options);
      if (!payload.sub || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(payload.sub)
        || payload.role !== 'authenticated' || !payload.exp || payload.exp * 1000 <= Date.now()) throw new AuthFailure();
      return { userId: payload.sub, expiresAt: payload.exp * 1000 };
    } catch (error) {
      if (error instanceof errors.JWTExpired) throw new AuthFailure('TOKEN_EXPIRED');
      if (error instanceof AuthFailure) throw error;
      throw new AuthFailure();
    }
  }
}
