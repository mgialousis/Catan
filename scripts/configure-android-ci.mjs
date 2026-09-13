import { writeFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { publicConfig } from './public-config.mjs';

// Run only on the ephemeral CI runner; preserve developers' local signing files.
if (process.env.GITHUB_ACTIONS !== 'true' || !process.env.RUNNER_TEMP) {
  throw Error('This signing setup is for GitHub Actions only');
}
const config = publicConfig(process.env);
const propertiesPath = 'apps/mobile/android/key.properties';
const configPath = 'apps/mobile/config/ci.json';
const keystorePath = resolve(process.env.RUNNER_TEMP, 'island-release.jks');
if ([propertiesPath, configPath, keystorePath].some(existsSync)) {
  throw Error('Refusing to overwrite existing signing or CI configuration');
}
for (const name of ['ANDROID_KEYSTORE_BASE64', 'ANDROID_STORE_PASSWORD', 'ANDROID_KEY_PASSWORD', 'ANDROID_KEY_ALIAS']) {
  if (!process.env[name]) throw Error(`Missing GitHub secret: ${name}`);
}
const property = value => value.replaceAll('\\', '\\\\').replaceAll('\r', '\\r').replaceAll('\n', '\\n').replaceAll(' ', '\\ ');
writeFileSync(keystorePath, Buffer.from(process.env.ANDROID_KEYSTORE_BASE64, 'base64'), { mode: 0o600, flag: 'wx' });
writeFileSync(propertiesPath, [
  `storeFile=${property(keystorePath)}`,
  `storePassword=${property(process.env.ANDROID_STORE_PASSWORD)}`,
  `keyPassword=${property(process.env.ANDROID_KEY_PASSWORD)}`,
  `keyAlias=${property(process.env.ANDROID_KEY_ALIAS)}`,
  '',
].join('\n'), { mode: 0o600, flag: 'wx' });
writeFileSync(configPath, JSON.stringify(config), { mode: 0o600, flag: 'wx' });
console.log('Prepared temporary release signing and validated public app configuration.');
