import { test, expect } from '@playwright/test';
import { register, logIn, logOut, expectSignedIn, expectSignedOut, uniqueName } from './helpers';

// A signed-out user is shown a blocking auth modal; everything else needs a
// signed-in player. Each test registers its own e2e-* player so tests stay
// independent (cleanup happens in global teardown / scripts/e2e-clean.sh).

test('registers a new player and lands signed in', async ({ page }) => {
  await register(page, uniqueName('reg'));
  await expectSignedIn(page);
});

test('logs out and back in with the same credentials', async ({ page }) => {
  const name = uniqueName('login');
  await register(page, name);
  await logOut(page);
  await logIn(page, name);
  await expectSignedIn(page);
});

test('"Stay logged in" survives a reload', async ({ page }) => {
  await register(page, uniqueName('stay'), { stayLoggedIn: true });
  await page.reload();
  // No re-login prompt: the persisted token is re-validated on boot.
  await expectSignedIn(page);
});

// The two storage lifetimes, pinned from both sides. "Stay logged in"
// chooses between localStorage (survives the browser closing) and
// sessionStorage (survives a reload, dies with the tab) — so a test that
// only checked "still signed in after reload" would pass just as well if
// the token were wrongly made permanent. The new-tab cases are what tell
// the two stores apart.
test('a reload keeps you signed in even without "Stay logged in"', async ({ page }) => {
  await register(page, uniqueName('reload'), { stayLoggedIn: false });
  await page.reload();
  // Regression: the token used to live only in memory when the box was
  // unchecked, so any refresh — including the client's own auto-reload on
  // api skew after a deploy — dropped you back to the login screen
  // mid-game.
  await expectSignedIn(page);
});

test('without "Stay logged in", a new tab starts signed out', async ({ context, page }) => {
  await register(page, uniqueName('newtab'), { stayLoggedIn: false });
  await expectSignedIn(page);

  // Same browser context, so localStorage is shared but sessionStorage is
  // not. Signed out here is what proves the token went to the per-tab
  // store rather than the persistent one.
  const other = await context.newPage();
  await other.goto('/');
  await expectSignedOut(other);
  await other.close();
});

test('with "Stay logged in", a new tab is already signed in', async ({ context, page }) => {
  await register(page, uniqueName('newtabstay'), { stayLoggedIn: true });

  const other = await context.newPage();
  await other.goto('/');
  await expectSignedIn(other);
  await other.close();
});

test('Play Greedy Bot starts a game and renders the board', async ({ page }) => {
  await register(page, uniqueName('bot'));

  // "Play Greedy Bot" opens the game draft (creator + engine seat); the draft's
  // submit is "Start" once every seat is filled (no invitations needed).
  await page.getByRole('button', { name: 'Play Greedy Bot' }).click();
  await page.getByRole('button', { name: 'Start', exact: true }).click();

  // The in-game view rendered: board grid + the player's rack with tiles.
  // The rack having tiles is the reliable "this is a real, playable game for
  // me" signal — unlike the turn-indicator text, which is timing-sensitive and
  // ambiguous (the words "Your turn" also appear as a games-list section
  // heading in the sidebar).
  await expect(page.locator('.board-panel')).toBeVisible();
  await expect(page.locator('.rack-panel')).toBeVisible();
  await expect(page.locator('.board-cell').first()).toBeVisible();
  await expect(page.locator('.rack-tile').first()).toBeVisible();
});
