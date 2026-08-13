import { test, expect } from '@playwright/test';
import {
  register,
  logIn,
  logOut,
  expectSignedIn,
  expectSignedOut,
  uniqueName,
  authTab,
  TEST_PASSWORD,
  startTwoPlayerGame,
} from './helpers';

// A signed-out user is shown a blocking auth modal; everything else needs a
// signed-in player. Each test registers its own e2e-* player so tests stay
// independent (cleanup happens in global teardown / scripts/e2e-clean.sh).

test('registers a new player and lands signed in', async ({ page }) => {
  await register(page, uniqueName('reg'));
  await expectSignedIn(page);
});

test('unread chat survives being off screen, and clears once watched', async ({ browser }) => {
  // #86. The watermark used to advance the instant a message arrived into an
  // open game — "watching the panel counts as reading it" — so a message
  // landing in a background tab, or in a panel scrolled off a phone, was marked
  // read by nobody. The whole issue is that visible is not the same as seen.
  //
  // Two accounts, because the rework also stopped marking *your own* messages
  // unread, which is what a single player in a bot game can only ever produce.
  const { host, guest, hostContext, guestContext } = await startTwoPlayerGame(browser);

  await guest.getByPlaceholder('Say something...').fill('does anyone read these');
  await guest.getByRole('button', { name: 'Send', exact: true }).click();

  // Marked unread in both places, from one signal. (There was a third, an
  // envelope above the messages; it was removed during the rework because the
  // game already carries one and its appearing and disappearing made
  // everything below it jump.)
  await expect(host.locator('.chat-message-unread')).toHaveCount(1);
  await expect(host.locator('.rack-scores-unread')).toHaveCount(1);

  // Scroll the chat out of view for longer than the ten seconds. Nothing may
  // clear: the clock only runs while somebody could actually be looking, and on
  // a phone this is the ordinary case — the panel is simply off the bottom.
  //
  // Scrolling rather than backgrounding the tab because Playwright's
  // `bringToFront` does not flip `document.hidden` here (checked), so that test
  // would have passed against a broken implementation. The hidden-tab half is
  // `document.hidden` in `chat_messages_are_visible`, covered by SeenClock's
  // own tests; this covers the wiring.
  await host.setViewportSize({ width: 900, height: 400 });
  await host.evaluate(() => {
    document.querySelector('.board-panel')?.scrollIntoView({ block: 'start' });
    window.scrollTo(0, 0);
  });
  // Read the *pseudo-element*: the rework moved the fade to an `::after`
  // overlay driven by an inline `--chat-fade-state`, so asserting
  // `animation-play-state` on the message itself inspects an element that no
  // longer animates and passes whatever the implementation does.
  await expect
    .poll(
      () =>
        host.evaluate(() => {
          const message = document.querySelector('.chat-message-unread');
          return message ? getComputedStyle(message, '::after').animationPlayState : null;
        }),
      { message: 'the fade must be paused while the messages are off screen', timeout: 5_000 },
    )
    .toBe('paused');

  await host.waitForTimeout(12_000);
  await expect(
    host.locator('.chat-message-unread'),
    'messages nobody can see must not be marked read',
  ).toHaveCount(1);

  // Back in view, and the clock resumes.
  await host.setViewportSize({ width: 1280, height: 900 });
  await host.evaluate(() => document.querySelector('.chat-messages')?.scrollIntoView());

  // Now watched, so it clears — and both clear together.
  await expect(host.locator('.chat-message-unread')).toHaveCount(0, { timeout: 20_000 });
  await expect(host.locator('.rack-scores-unread')).toHaveCount(0);

  await hostContext.close();
  await guestContext.close();
});

test('the invite-by-name dropdown is visible, not merely rendered', async ({ page }) => {
  // #76. The suggestion list is absolutely positioned, so it lives outside its
  // cell's box — and the pre-creation builder lays seats out in a table whose
  // cells set `overflow: hidden` to ellipsis long names. The list rendered,
  // sized and positioned correctly, and was clipped to nothing.
  //
  // So this asserts what a person can *see*. Counting nodes, or asking whether
  // the element exists, passes against the clipped version — which is exactly
  // how this was missed three times while the DOM said everything was fine.
  const me = uniqueName('dd');
  await register(page, me);
  await page.getByRole('button', { name: 'Play Friend' }).click();

  const field = page.locator('.name-autocomplete input').first();
  await field.click();
  // Their own name is guaranteed to match, so the suite does not depend on
  // whatever other players happen to exist.
  await field.type(me.slice(0, 6), { delay: 60 });

  const item = page.locator('.name-autocomplete-item').first();
  await expect(item).toBeVisible();

  // Hit-test, not `toBeVisible`. Playwright calls a clipped element visible —
  // it checks visibility styles and a non-empty box, neither of which an
  // ancestor's `overflow: hidden` changes. Asking the browser what is actually
  // painted at the suggestion's own centre is the only assertion here that
  // fails against the clipped version; every cheaper one passed against it.
  const box = await item.boundingBox();
  expect(box).not.toBeNull();
  const hit = await page.evaluate(
    ({ x, y }) => {
      const el = document.elementFromPoint(x, y);
      return el ? !!el.closest('.name-autocomplete-dropdown') : false;
    },
    { x: box!.x + box!.width / 2, y: box!.y + box!.height / 2 },
  );
  expect(hit, 'the suggestion is painted where it claims to be, not clipped away').toBe(true);
});

test('logs out and back in with the same credentials', async ({ page }) => {
  const name = uniqueName('login');
  await register(page, name);
  await logOut(page);
  await logIn(page, name);
  await expectSignedIn(page);
});

// The credentials must not survive the session that used them (#50): the modal
// is emptied when it is hidden, so every later session end finds it empty.
//
// **This guards the behaviour; it does not reproduce the bug.** It passes
// against the unfixed code too, because ending the session this way clears the
// fields for some reason not yet understood — where a session ending by
// *expiry* did not, which is how the bug was found (by hand, forcing
// `expires_at = 0` in the database). Reaching expiry from a browser needs a
// write to the server's database, which couples the test to one environment,
// so it is not attempted here. Worth revisiting: a test that cannot fail is
// worth less than it looks.
test('the auth modal comes back empty when a session ends', async ({ page }) => {
  const name = uniqueName('empty');
  await register(page, name);

  await page.getByRole('button', { name: 'Edit user details' }).click();
  await page.getByPlaceholder('Current password').fill(TEST_PASSWORD);
  await page.getByPlaceholder('New password', { exact: true }).fill(`${TEST_PASSWORD}-2`);
  await page.getByPlaceholder('Confirm new password').fill(`${TEST_PASSWORD}-2`);
  await page.getByRole('button', { name: 'Update password' }).click();

  // A password change invalidates every session for the player, this one
  // included, so the modal returns.
  await expect(page.locator('.auth-panel')).toBeVisible();

  await expect(page.getByPlaceholder('Password', { exact: true })).toHaveValue('');
  // "Remember me" was never ticked, so nothing is asking the name to stay.
  await expect(page.getByPlaceholder('Display name')).toHaveValue('');
  // Email exists only on the Register tab, which the reset also returns from.
  await authTab(page, 'Register').click();
  await expect(page.getByPlaceholder('Email')).toHaveValue('');
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

/// Layout must survive phones narrower than the one it was designed on.
///
/// The scores row, the offline pill and the rack were all sized against a
/// single handset (~393 CSS px). A narrower screen is where a fixed width or
/// a non-shrinking flex item stops fitting — and the failure is horizontal
/// scrolling, which is far worse on a phone than a wrapped line.
///
/// 320px is the narrowest in common use (iPhone SE and similar). Asserting
/// "the document is no wider than the viewport" catches the whole class
/// rather than the one element that happened to break.
for (const width of [320, 360, 414]) {
  test(`no horizontal overflow at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 720 });
    await register(page, uniqueName(`w${width}`));

    await page.getByRole('button', { name: 'Play Greedy Bot' }).click();
    await page.getByRole('button', { name: 'Start', exact: true }).click();
    await expect(page.locator('.rack-panel')).toBeVisible();

    const { overflow, culprits } = await page.evaluate(() => {
      const viewport = document.documentElement.clientWidth;
      // Name what actually sticks out. A bare number says the page is too
      // wide; this says which element made it so, which is the difference
      // between a diagnosis and a puzzle — particularly on CI, where the
      // failure may not reproduce locally because font fallbacks differ.
      const culprits = Array.from(document.querySelectorAll('*'))
        .filter((el) => el.getBoundingClientRect().right > viewport + 1)
        .slice(0, 6)
        .map((el) => {
          const right = Math.round(el.getBoundingClientRect().right);
          const cls = typeof el.className === 'string' && el.className ? `.${el.className.trim().split(/\s+/).join('.')}` : '';
          return `${el.tagName.toLowerCase()}${cls} right=${right}`;
        });
      return {
        overflow: document.documentElement.scrollWidth - viewport,
        culprits,
      };
    });
    expect(
      overflow,
      `the page scrolls sideways by ${overflow}px at ${width}px wide.\n` +
        `Widest offenders:\n  ${culprits.join('\n  ')}`,
    ).toBeLessThanOrEqual(1);
  });
}
