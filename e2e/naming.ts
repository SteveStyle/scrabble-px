// How a test account is named (#252 R1). One definition, imported by the
// helpers that create accounts, the setup that announces the run, and the
// teardown that deletes them.
//
// **It was three copies for about an hour, and that is why this exists.** The
// format changed from underscores to hyphens; two of the three were updated and
// the teardown's was not, so it searched `T-e2e-<run>_` for accounts named
// `T-e2e-<run>-…` and reported *"nothing matching"* — a clean, plausible line
// that means an account was left behind. Cleanup that silently stops cleaning is
// how sixteen stray accounts sat in preview unnoticed (#128).
//
// **Hyphens, not underscores.** The suite registers through the same public API
// a player uses, so any rule on display names applies to it too — *"the API
// cannot special-case the suite"*. An earlier version used `T_e2e_…` on the
// grounds that excluding the underscore from display names (#332) would put the
// shape out of a player's reach. It would have put it out of the suite's reach
// as well, and the server would have refused every account the tests create.

export const TEST_MARKER = 'T-';
export const SUITE = 'e2e';

/** The prefix identifying one run's accounts — what cleanup deletes. */
export function runPrefixFor(runId: string): string {
  return `${TEST_MARKER}${SUITE}-${runId}-`;
}

/** Every account this suite has ever created, across runs. */
export const SUITE_PREFIX = `${TEST_MARKER}${SUITE}-`;
