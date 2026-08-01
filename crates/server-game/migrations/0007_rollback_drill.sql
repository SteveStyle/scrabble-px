-- A table that exists in order to be rolled back.
--
-- Rolling production back across a schema change is the one path in the
-- deploy tooling that had never actually run: `scripts/rollback.sh` restores
-- a pre-deploy snapshot and retags the previous images, and `deploy.sh`
-- refuses an image the live database has already moved past. Both were
-- reasoned about and unit-tested against mocks. Neither had met a real
-- database. This migration is the vehicle for proving them, on the real VM,
-- without inventing a fault or standing up a second environment — see
-- docs/3.3's "Rollback drill".
--
-- Why a table nothing references, rather than a change we actually want:
--
--   * It is inert. No code reads or writes it, so applying it cannot change
--     behaviour. An index would have been almost as harmless but still
--     perturbs query plans; a column on a live table less so again.
--   * Its presence is unambiguous, and `/health`'s `schema_version` moves
--     from 6 to 7, which is the observable the drill actually checks.
--   * Nothing here is speculative. Inventing a table for a feature not yet
--     built — the take-back log, say — would have been worse: migrations
--     can never be edited or removed once applied, so a guessed shape is
--     permanent, and guessing it under no design pressure is how you get a
--     shape you have to work around later.
--
-- It can be dropped by a later migration once the drill has served its
-- purpose. That drop is itself additive-and-safe, so it doubles as the
-- vehicle for a second drill if one is ever wanted.
create table rollback_drill (
    id integer primary key,
    created_at integer not null,
    note text not null
);
