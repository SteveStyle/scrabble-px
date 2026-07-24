import { test, expect } from '@playwright/test';
import { register, logIn, logOut, expectSignedIn, uniqueName } from './helpers';

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
