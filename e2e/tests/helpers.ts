import { Browser, Page, expect } from '@playwright/test';

// Every player these tests create starts with this prefix, so
// scripts/e2e-clean.sh (and the global teardown) can find and remove them.
// A per-run suffix keeps repeated runs from colliding on the unique
// `players.display_name` constraint.
export const TEST_PREFIX = 'e2e-';
export const TEST_PASSWORD = 'e2e-playwright-password';

export function uniqueName(base: string): string {
  const rand = Math.random().toString(36).slice(2, 7);
  return `${TEST_PREFIX}${base}-${Date.now().toString(36)}-${rand}`;
}

// The signed-out app shows a blocking auth modal with "Log in" / "Register"
// tabs. These helpers drive it via visible text / placeholders rather than
// brittle structural selectors.
export function authTab(page: Page, name: 'Log in' | 'Register') {
  return page.locator('.auth-panel-tabs button', { hasText: name });
}
function authSubmit(page: Page, name: 'Log in' | 'Register') {
  return page.locator('form.auth-form').getByRole('button', { name, exact: true });
}

export async function register(
  page: Page,
  name: string,
  opts: { password?: string; stayLoggedIn?: boolean } = {},
) {
  const password = opts.password ?? TEST_PASSWORD;
  await page.goto('/');
  await authTab(page, 'Register').click();
  await page.getByPlaceholder('Display name').fill(name);
  // Register requires an email (client-side validation rejects a blank one).
  await page.getByPlaceholder('Email').fill(`${name}@e2e.test`);
  await page.getByPlaceholder('Password', { exact: true }).fill(password);
  if (opts.stayLoggedIn) {
    await page.getByText('Stay logged in').click();
  }
  await authSubmit(page, 'Register').click();
  await expectSignedIn(page);
}

export async function logIn(page: Page, name: string, password = TEST_PASSWORD) {
  await authTab(page, 'Log in').click();
  await page.getByPlaceholder('Display name').fill(name);
  await page.getByPlaceholder('Password', { exact: true }).fill(password);
  await authSubmit(page, 'Log in').click();
  await expectSignedIn(page);
}

export async function logOut(page: Page) {
  await page.getByRole('button', { name: 'Log out' }).click();
  // The blocking auth modal returns once signed out.
  await expect(page.locator('.auth-panel')).toBeVisible();
}

// "Signed in" is unambiguous: the auth modal is gone and the Log out control
// is present.
export async function expectSignedIn(page: Page) {
  await expect(page.getByRole('button', { name: 'Log out' })).toBeVisible();
  await expect(page.locator('.auth-panel')).toHaveCount(0);
}

// The blocking auth modal is what a signed-out visitor gets.
export async function expectSignedOut(page: Page) {
  await expect(page.locator('.auth-panel')).toBeVisible();
}

/// Two signed-in players in one started game, in separate browser contexts.
///
/// Needed because unread only counts messages you *received* — the #86 rework
/// stopped marking your own (`games.rs` filters the caller out of
/// `last_message_received_at`). A single player in a bot game cannot receive
/// anything, and Greedy Bot does not chat, so there is no cheaper rig than two
/// real accounts.
export async function startTwoPlayerGame(browser: Browser) {
  const hostContext = await browser.newContext();
  const guestContext = await browser.newContext();
  const host = await hostContext.newPage();
  const guest = await guestContext.newPage();

  const guestName = uniqueName('guest');
  await register(guest, guestName);
  await register(host, uniqueName('host'));

  await host.getByRole('button', { name: 'Play Friend' }).click();
  const field = host.locator('.name-autocomplete input').first();
  await field.click();
  await field.type(guestName.slice(0, 10), { delay: 40 });
  await expect(host.locator('.name-autocomplete-item').first()).toBeVisible();
  await host.locator('.name-autocomplete-item').first().click();
  await host.getByRole('button', { name: 'Invite', exact: true }).click();

  await guest.getByRole('button', { name: 'Refresh' }).click();
  await guest.getByRole('button', { name: 'Accept' }).click();
  await host.getByRole('button', { name: 'Start', exact: true }).click();
  await expect(host.locator('.rack-panel')).toBeVisible();

  // The guest has to have the game open to reach its chat composer.
  await guest.getByRole('button', { name: 'Refresh' }).click();
  await guest.locator('.game-row').first().click();

  return { host, guest, hostContext, guestContext };
}
