import { createApp } from './app.js';
import { loadConfig } from './config.js';
try {
  const config = loadConfig();
  const app = await createApp(config);
  await app.listen(config.port, '0.0.0.0');
  console.log(`Island Table API ready on port ${config.port}`);
} catch {
  console.error('API startup failed. Check local configuration, database role and migrations.');
  process.exitCode = 1;
}
