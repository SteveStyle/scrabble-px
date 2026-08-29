import { execFileSync } from 'node:child_process';
import path from 'node:path';

// Purge the e2e-* players/games this run created (see scripts/e2e-clean.sh).
// Best-effort: a cleanup failure (e.g. the script isn't reachable in CI)
// must never fail an otherwise-green suite.
//
// **The target is passed explicitly.** It used to be left to the script, which
// defaulted to dev's sqlite file — so a run against preview created accounts
// there, cleaned dev, and reported "removed 0", which reads as success (#128).
// The same default lives in playwright.config.ts, and both must agree.
const baseURL = process.env.PLAYWRIGHT_BASE_URL || 'http://localhost:8080';

export default async function globalTeardown() {
  try {
    execFileSync(path.join(__dirname, '..', 'scripts', 'e2e-clean.sh'), {
      stdio: 'inherit',
      env: { ...process.env, E2E_TARGET: baseURL },
    });
  } catch (err) {
    // Loud, because a cleanup that silently stopped cleaning is how sixteen
    // stray accounts sat in preview unnoticed. Still not a suite failure: the
    // tests passed, and the litter is a separate problem from the result.
    console.warn(
      `\n[e2e] CLEANUP FAILED against ${baseURL} — accounts may have been left behind.\n` +
        `      ${(err as Error).message}\n`,
    );
  }
}
