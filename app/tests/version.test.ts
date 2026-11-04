import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { APP_VERSION, APP_VERSION_LABEL, BUILD_NUMBER } from '../src/lib/version.ts';

const cfg = JSON.parse(readFileSync(new URL('../app.json', import.meta.url), 'utf8')).expo;

test('versão do Expo, iOS e Android coerentes com version.ts', () => {
  assert.equal(cfg.version, APP_VERSION);
  assert.equal(cfg.ios.buildNumber, String(BUILD_NUMBER));
  assert.equal(cfg.android.versionCode, BUILD_NUMBER);
  assert.equal(APP_VERSION_LABEL, `V${APP_VERSION.split('.').slice(0, 2).join('.')}`);
});
