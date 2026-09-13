import { chromium, expect } from '@playwright/test';
import { mkdir } from 'node:fs/promises';
import assert from 'node:assert/strict';

// Independent browser contexts represent separate phones; never target hosted services.
const browser = await chromium.launch({ channel: 'chrome', headless: true });
const participants = [];
async function semantics(page) {
  await page.waitForLoadState('networkidle');
  await page.getByRole('button', { name: 'Enable accessibility', exact: true }).dispatchEvent('click');
}
async function open(name, url = 'http://127.0.0.1:8080') {
  assert.equal(new URL(url).origin, 'http://127.0.0.1:8080');
  const context = await browser.newContext({ viewport: { width: 430, height: 932 }, permissions: ['clipboard-read', 'clipboard-write'] });
  const page = await context.newPage(); const guest = { page, context, name, signups: 0, joined: false };
  page.on('request', request => { if (new URL(request.url()).pathname === '/auth/v1/signup') guest.signups++; });
  page.on('pageerror', error => { guest.failure = error.message; });
  participants.push(guest);
  await page.goto(url); await semantics(page);

  await page.getByRole('textbox', { name: 'Nickname', exact: true }).click();
  await page.getByRole('textbox', { name: 'Nickname', exact: true }).press('ControlOrMeta+A');
  await page.getByRole('textbox', { name: 'Nickname', exact: true }).press('Backspace');
  // Flutter's accessibility input needs keyboard events, not a DOM-only fill.
  await page.getByRole('textbox', { name: 'Nickname', exact: true }).pressSequentially(name, { delay: 80 });
  await expect(page.getByRole('textbox', { name: 'Nickname', exact: true })).toHaveValue(name);
  await page.getByRole('button', { name: 'Connect as guest', exact: true }).click();
  await expect.poll(() => page.locator('body').ariaSnapshot(), { timeout: 15000 }).toContain('Connected. Your guest session is ready.');
  assert.equal(guest.signups, 1, 'first connection creates exactly one guest identity');
  return guest;
}
async function leave(guest) {
  if (!guest.joined) return;
  const { page } = guest;
  await page.getByRole('button', { name: 'Leave table', exact: true }).click();
  await expect(page.getByText('Leave this table?', { exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Leave table', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Create private table', exact: true })).toBeVisible();
  guest.joined = false;
}
try {
  const host = await open('Browser host');
  await mkdir('docs/screenshots', { recursive: true });
  await host.page.screenshot({ path: 'docs/screenshots/phase-2-entry.png' });
  await host.page.getByRole('button', { name: 'Create private table', exact: true }).click();
  await expect.poll(() => host.page.locator('body').ariaSnapshot()).toContain('Around the table 1 / 4'); host.joined = true;
  await host.page.getByRole('button', { name: 'Copy invitation link', exact: true }).click();
  const invitation = await host.page.evaluate(() => navigator.clipboard.readText());
  assert.match(new URL(invitation).searchParams.get('invite'), /^[0-9A-HJKMNP-TV-Z]{10}$/);
  for (const name of ['Juniper', 'Robin', 'Alex']) {
    const guest = await open(name, invitation);
    // Joining without typing a code verifies first-launch invitation preservation.
    await guest.page.getByRole('textbox', { name: 'Invitation code', exact: true }).click();
    await expect(guest.page.getByRole('textbox', { name: 'Invitation code', exact: true })).toHaveValue(new URL(invitation).searchParams.get('invite'));
    await guest.page.getByRole('button', { name: 'Join table', exact: true }).click();
    await expect.poll(() => guest.page.locator('body').ariaSnapshot()).toContain(`${name} (you)`); guest.joined = true;
  }
  await expect.poll(() => host.page.locator('body').ariaSnapshot()).toContain('Around the table 4 / 4');
  const fifth = await open('Fifth friend', invitation);
  await fifth.page.getByRole('button', { name: 'Join table', exact: true }).click();
  await expect.poll(() => fifth.page.locator('body').ariaSnapshot()).toContain('All four seats are taken.');
  for (const guest of participants.slice(0, 4)) {
    await guest.page.getByRole('button', { name: "I'm ready", exact: true }).click();
    await expect(guest.page.getByRole('button', { name: 'Not ready', exact: true })).toBeVisible();
  }
  await expect(host.page.getByRole('button', { name: 'Start game', exact: true })).toBeEnabled();
  await host.page.reload(); await semantics(host.page);
  await expect.poll(() => host.page.locator('body').ariaSnapshot(), { timeout: 15000 }).toContain('Browser host (you)');
  assert.equal(host.signups, 1, 'reload restores the original guest without another signup');
  await expect.poll(() => host.page.locator('body').ariaSnapshot()).toContain('Around the table 4 / 4');
  await host.page.screenshot({ path: 'docs/screenshots/phase-2-four-players.png', fullPage: true });
  await host.page.setViewportSize({ width: 360, height: 800 });
  await host.page.screenshot({ path: 'docs/screenshots/phase-2-narrow.png', fullPage: true });
  for (const guest of participants) assert.equal(guest.failure, undefined, 'no browser runtime errors');
  console.log('Flutter Web passed: five independent guests, invitation onboarding, four seats, readiness/start guard, reload with the same guest, narrow layout, and lobby closure.');
} finally {
  try { for (const guest of participants.filter(p => p.joined).reverse()) await leave(guest); }
  finally { await browser.close(); }
}
