import 'reflect-metadata';
import { Controller, Get, Inject, Module, ServiceUnavailableException, type INestApplication } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import { IoAdapter } from '@nestjs/platform-socket.io';
import { Server, type ServerOptions } from 'socket.io';
import { PROTOCOL_VERSION, RULES_VERSION, MAX_COMMAND_BYTES } from '@island/protocol';
import { TokenVerifier } from './auth.js';
import { Database } from './database.js';
import { GameGateway, WindowLimiter } from './gateway.js';
import type { AppConfig } from './config.js';

@Controller()
class HealthController {
  constructor(@Inject(Database) private readonly database: Database) {}
  @Get('health/live') live() { return { status: 'ok' }; }
  @Get('health/ready') async ready() {
    try { await this.database.ready(); return { status: 'ready' }; }
    catch { throw new ServiceUnavailableException('Service is not ready'); }
  }
  @Get('api/v1/version') version() { return { protocolVersion: PROTOCOL_VERSION, rulesVersion: RULES_VERSION, implementationPhase: 1 }; }
}

class GameAdapter extends IoAdapter {
  private readonly connections = new WindowLimiter(120);
  constructor(app: INestApplication, private readonly config: AppConfig) { super(app); }
  override createIOServer(port: number, options?: ServerOptions): Server {
    return super.createIOServer(port, {
      ...options, path: '/socket.io', transports: ['websocket'],
      maxHttpBufferSize: MAX_COMMAND_BYTES, pingInterval: 25000, pingTimeout: 20000,
      cors: { origin: this.config.origins, credentials: false },
      allowRequest: (request: { headers: { origin?: string }; socket: { remoteAddress?: string } }, callback: (error: string | null, allowed: boolean) => void) => {
        const origin = request.headers.origin;
        const allowed = (!origin || this.config.origins.includes(origin)) && this.connections.allow(request.socket.remoteAddress ?? 'unknown');
        callback(allowed ? null : 'Connection rejected', allowed);
      },
    });
  }
}
export async function createApp(config: AppConfig): Promise<INestApplication> {
  const database = new Database(config);
  try { await database.ready(); } catch { await database.pool.end(); throw new Error('Database is not ready or compatible'); }
  @Module({
    controllers: [HealthController],
    providers: [GameGateway, { provide: Database, useValue: database }, { provide: TokenVerifier, useValue: new TokenVerifier(config) }],
  })
  class AppModule {}
  const app = await NestFactory.create(AppModule, { logger: ['warn', 'error'], bodyParser: false });
  app.enableCors({ origin: config.origins });
  app.useWebSocketAdapter(new GameAdapter(app, config));
  app.enableShutdownHooks();
  return app;
}
