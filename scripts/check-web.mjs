import { chromium, expect } from '@playwright/test';
import { mkdir } from 'node:fs/promises';
import assert from 'node:assert/strict';

// Uses an existing Chrome installation; targets only the local static build.
const browser = await chromium.launch({ channel: 'chrome', headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 430, height: 900 } });
  await page.goto('http://127.0.0.1:8080');
  await page.waitForLoadState('networkidle');
  await page.getByRole('button', { name: 'Enable accessibility', exact: true }).dispatchEvent('click');
  await expect(page.getByRole('button', { name: 'Connect as guest', exact: true })).toBeVisible();
  await mkdir('docs/screenshots', { recursive: true });
  await page.screenshot({ path: 'docs/screenshots/web-initial.png' });
  let signups = 0;
  page.on('request', request => { if (new URL(request.url()).pathname === '/auth/v1/signup') signups++; });
  await page.getByRole('button', { name: 'Connect as guest', exact: true }).click();
  await expect.poll(() => page.locator('body').ariaSnapshot(), { timeout: 15000 }).toContain('Connected. Your guest session is ready.');
  assert.equal(signups, 1, 'first connection creates one anonymous identity');
  await page.screenshot({ path: 'docs/screenshots/web-connected.png' });
  await page.reload();
  await page.waitForLoadState('networkidle');
  await page.getByRole('button', { name: 'Enable accessibility', exact: true }).dispatchEvent('click');
  await page.getByRole('button', { name: 'Connect as guest', exact: true }).click();
  await expect.poll(() => page.locator('body').ariaSnapshot(), { timeout: 15000 }).toContain('Connected. Your guest session is ready.');
  assert.equal(signups, 1, 'reload reuses the persisted guest instead of creating another');
  console.log('Flutter Web: anonymous connection and reload/session restoration passed.');
} finally { await browser.close(); }
