import 'reflect-metadata';
import { Controller, Get, Inject, Module, Param, Query, Headers, HttpException, ServiceUnavailableException, type INestApplication } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import { IoAdapter } from '@nestjs/platform-socket.io';
import { Server, type ServerOptions } from 'socket.io';
import { isValid, PROTOCOL_VERSION, RULES_VERSION, MAX_COMMAND_BYTES } from '@island/protocol';
import { TokenVerifier } from './auth.js';
import { clientAddress } from './client-address.js';
import { Games, type GameFaults } from './games.js';
import { safeError } from './errors.js';
import { Rooms } from './rooms.js';
import { Database } from './database.js';
import { GameGateway, WindowLimiter } from './gateway.js';
import type { AppConfig } from './config.js';

@Controller()
class HealthController {
  constructor(@Inject(Database) private readonly database: Database, @Inject(Rooms) private readonly rooms: Rooms) {}
  @Get('health/live') live() { return { status: 'ok' }; }
  @Get('health/ready') async ready() {
    try { await this.database.ready(); await this.rooms.ready(); return { status: 'ready' }; }
    catch { throw new ServiceUnavailableException('Service is not ready'); }
  }
  @Get('api/v1/version') version() { return { protocolVersion: PROTOCOL_VERSION, rulesVersion: RULES_VERSION, implementationPhase: 6 }; }
}

@Controller()
class ActivityController {
  constructor(@Inject(TokenVerifier) private readonly auth: TokenVerifier, @Inject(Games) private readonly games: Games) {}
  @Get('api/v1/rooms/:roomId/activity')
  async activity(@Param('roomId') roomId: string, @Query('before') beforeText: string | undefined, @Query('limit') limitText: string | undefined, @Headers('authorization') authorization?: string) {
    let userId: string;
    try { if (!authorization?.startsWith('Bearer ')) throw new Error(); userId = (await this.auth.verify(authorization.slice(7))).userId; }
    catch { throw new HttpException(safeError('UNAUTHENTICATED'), 401); }
    const before = beforeText === undefined ? 2147483647 : Number(beforeText), limit = limitText === undefined ? 30 : Number(limitText);
    if (!isValid('uuid', roomId) || !Number.isInteger(before) || before < 0 || before > 2147483647 || !Number.isInteger(limit) || limit < 1 || limit > 50) throw new HttpException(safeError('INVALID_PAYLOAD'), 400);
    try { return await this.games.activity(userId, roomId, before, limit); }
    catch (error) { const forbidden = (error as { code?: string }).code === 'FORBIDDEN'; throw new HttpException(safeError(forbidden ? 'FORBIDDEN' : 'SERVICE_UNAVAILABLE'), forbidden ? 403 : 503); }
  }
}

class GameAdapter extends IoAdapter {
  private readonly connections = new WindowLimiter(120);
  constructor(app: INestApplication, private readonly config: AppConfig) { super(app); }
  override createIOServer(port: number, options?: ServerOptions): Server {
    return super.createIOServer(port, {
      ...options, path: '/socket.io', transports: ['websocket'],
      maxHttpBufferSize: MAX_COMMAND_BYTES, pingInterval: 25000, pingTimeout: 20000,
      cors: { origin: this.config.origins, credentials: false },
      allowRequest: (request: { headers: { origin?: string; 'x-forwarded-for'?: string | string[] }; socket: { remoteAddress?: string } }, callback: (error: string | null, allowed: boolean) => void) => {
        const origin = request.headers.origin;
        const allowed = (!origin || this.config.origins.includes(origin)) && this.connections.allow(clientAddress(request.socket.remoteAddress, request.headers['x-forwarded-for'], this.config.trustedProxyHops));
        callback(allowed ? null : 'Connection rejected', allowed);
      },
    });
  }
}
export async function createApp(config: AppConfig, testHooks?: { gameFaults: GameFaults }): Promise<INestApplication> {
  if (testHooks && (process.env.NODE_ENV === 'production' || !['localhost', '127.0.0.1'].includes(new URL(config.databaseUrl).hostname))) throw new Error('Test hooks require local non-production construction');
  const database = new Database(config);
  try { await database.ready(); } catch { await database.pool.end(); throw new Error('Database is not ready or compatible'); }
  const rooms = new Rooms(database);
  const games = new Games(database, rooms, testHooks?.gameFaults); rooms.games = games;
  try { await rooms.initialize(); } catch { await database.pool.end(); throw new Error('Lobby initialization failed'); }
  @Module({
    controllers: [HealthController, ActivityController],
    providers: [GameGateway, { provide: Games, useValue: games }, { provide: 'APP_CONFIG', useValue: config }, { provide: Rooms, useValue: rooms }, { provide: Database, useValue: database }, { provide: TokenVerifier, useValue: new TokenVerifier(config) }],
  })
  class AppModule {}
  const app = await NestFactory.create(AppModule, { logger: ['warn', 'error'], bodyParser: false });
  app.enableCors({ origin: config.origins });
  app.useWebSocketAdapter(new GameAdapter(app, config));
  app.enableShutdownHooks();
  games.wake();
  return app;
}
