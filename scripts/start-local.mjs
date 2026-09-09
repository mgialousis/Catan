import { spawn } from 'node:child_process';
import { mkdirSync, openSync, closeSync } from 'node:fs';
mkdirSync('.local', { recursive: true });
const log = openSync('.local/supabase-start.log', 'w', 0o600);
const child = spawn('node_modules/.bin/supabase', ['start'], { stdio: ['inherit', log, log] });
child.on('error', () => { closeSync(log); console.error('Unable to launch the local Supabase CLI.'); process.exitCode = 1; });
child.on('exit', code => {
  closeSync(log);
  if (code === 0) console.log('Local Supabase started. Run npm run local:configure next.');
  else { console.error('Local Supabase did not start. Inspect .local/supabase-start.log.'); process.exitCode = code ?? 1; }
});
