# Candidate changes to process

Proposals for `docs/3.x`, held here until they are agreed. **Nothing in this
document is decided**, and nothing in it is followed — it is where a change to
how we work waits to be argued about, so that 3.3 only ever describes what we
actually do.

Two so far:

1. **Vocabulary** (#155) — which of our terms to trade for the industry's.
2. **Workstreams** — a name for a group of issues sharing one design, and the
   rules that follow from letting one span releases.

Both are written up the same way: what it would change, what it costs, and what
is still open.

---

## Vocabulary: our terms and the industry's

Each entry gives the standard term, what it means in the literature, what we
call it, and a recommendation — because sometimes ours is better *for us* and
adopting a word adopts its baggage.

The point is not renaming for its own sake. It is that a reader who knows the
standard term can map what we do onto what they already know and go and read
more; and that `docs/3.x` is meant to be portable to a second project, where our
private vocabulary would travel badly.

Three possible outcomes per term: **adopt** it, **keep ours** and say why, or
**use both** — the standard term once so it is findable, ours thereafter.

### Where the standard term is simply better

#### release branch · release train

**Standard**: a branch cut for a release, with scope frozen at the cut; changes
merge into it, and it ships. A *train* is the scheduling variant — it departs on
time and unready features get off.

**Ours**: "version branch", "version-named branch".

**Recommend: adopt.** "Release branch" is universal and ours adds nothing. The
train metaphor is worth adopting too, because it names the de-scoping rule we do
not yet have (#135): the train leaves, the feature waits for the next one.

#### hermetic build

**Standard**: a build that depends only on declared inputs, so it can be
reproduced from source control alone.

**Ours**: "fresh-checkout principle" — deploys build a throwaway `git worktree`
at the target commit, never the working tree.

**Recommend: use both.** "Hermetic" is the findable term; our phrase says what we
actually do, which is narrower and clearer. Lead with hermetic, keep the
worktree sentence.

#### expand/contract  (also: parallel change)

**Standard**: schema changes made in two deployable steps so the old and new
code both work against the intermediate state.

**Ours**: unnamed — we describe migrations running as their own step before the
container swap.

**Recommend: adopt.** We have the practice and no word for it, which makes it
hard to reason about. Worth noting we currently do the *sequencing* half but not
the two-phase half — naming it makes that gap visible.

#### build metadata

**Standard**: semver §10 — the `+<anything>` suffix, ignored in precedence.

**Ours**: "the `+sha`", "build id".

**Recommend: adopt** for the version-number discussion, where the precedence
rule matters. "Build id" is fine everywhere else.

#### blast radius

**Standard**: how much breaks, and how visibly, if a change is wrong.

**Ours**: unnamed until 2026-08-15, when it went into `docs/3.4` as "grade by
blast radius, not by category".

**Recommend: adopt.** Already done.

---

### Where ours is better, and should stay

#### rehearsal  (vs staging)

**Standard**: *staging* — an environment resembling production, used before
release.

**Ours**: *rehearsal* — a production clone whose purpose is to prove the release
**mechanism** and to run anything needing production-like hardware.

**Recommend: keep ours, mention staging once.** "Staging" carries expectations we
deliberately do not meet: it is usually a permanent production mirror, and the
standing criticism of staging (Charity Majors: mirroring production is a fool's
errand) lands on that version and not on ours. Our word says what it is *for*,
which is the distinction that makes the preview/rehearsal split work. Say
"rehearsal (a staging environment, but see below)" once, then use ours.

#### lane  (merge · fasttrack · minor · major)

**Standard**: no clean equivalent. Closest are "release cadence" and Kanban
"classes of service", neither of which is widely used this way.

**Recommend: keep ours.** Nothing standard covers it, and inventing a match would
be worse than our own word. Worth defining once against classes of service, for
a reader who knows that term.

#### living document · standing issue

**Standard**: none in common use.

**Recommend: keep ours.** Coined here, defined in 3.3, and doing real work.

#### preview

**Standard**: "preview environment" / "review app" — close enough to be the same
thing, though usually per-branch and ephemeral where ours is one shared local
stack.

**Recommend: keep ours**, and note the difference: ours is not per-branch.

---

### Where the standard term names something we do not do

Worth naming anyway, because a considered rejection needs somewhere to live —
and 3.3's convention of "say what we do, not what we rejected" currently leaves
these looking like oversights.

| term | what it is | our position |
| --- | --- | --- |
| **canary release** | ship to a fraction of traffic first | not done — needs parallel infrastructure we do not have; automatic rollback on smoke-test failure is the substitute |
| **blue/green** | two production environments, switch between | same |
| **feature flag** | merge continuously, ship dark, flip when ready | not done, and the whole "when to merge, what to hold back" section is solving the problem flags solve. Defensible for one developer; the *absence of the word* is not |
| **artifact promotion** | build once, promote the same artifact through environments | **#134** — we currently rebuild, so rehearsal proves *a* build and production ships another |
| **SLSA provenance** | binding an artifact digest to a source revision | the formal version of #134; worth citing there |
| **trunk-based development** | short-lived branches off a trunk that is always releasable | mostly what we do; our release branches are TBD's "branch for release", explicitly *not* GitFlow's permanent `develop` |
| **dev/prod parity** | 12-factor X — keep environments similar | why preview keeps its volume, so migrations meet a non-empty database |
| **change enablement** | ITIL — normal / standard / emergency changes, with post-implementation review | we have this exactly, under our own words |
| **quality gate** | an automated check that blocks progress | our "gate" — same word, already aligned |

---

### Open questions on vocabulary

1. **How much to cite.** A named practice a reader can look up is worth more
   than a paragraph of our own reasoning — but 3.3 is already long, and #137 is
   about making it shorter to consult. Suggest: name the term in the *what*,
   cite the source once in the *notes*, and nowhere else.

2. **Whether "gate" needs qualifying.** We use it for both "a check that
   refuses" and "a check that warns and asks" — and the audit found 3.3
   describing the second as the first. Perhaps *gate* (refuses) and *check*
   (reports), used strictly.

3. **Whether to adopt "release train" fully.** It implies a schedule, and we
   release when a scope is ready rather than on a cadence. Adopting the word
   without the schedule may mislead.

---

## Workstreams: one design, several releases

**A workstream is a group of issues sharing one design.** It has a lead issue,
which is its identity and holds the design note; the rest are *chunks*, each
separately built and separately tested. A workstream may be split across
releases as part of release planning.

Proposed while planning #71, which is the first thing that needed it: in one
sitting it produced a bug belonging to a chunk (#157), a chunk belonging to a
workstream, and a finding from that chunk that changed the parent design. Three
things needing somewhere to go, and the existing vocabulary had room for none.

### The rule this is really about is ownership

It is framed as grouping, but the property that earns its keep is:

> **The workstream owns the design; a chunk owns only its own products and its
> own testing.**

That is what settles "too many choices of branch to put things in". Once a
document belongs to the workstream or to a chunk, "which branch?" has one
answer. The lead issue is the workstream's identity, not an administrative
convenience.

### Chunks go in milestones; workstreams never do

This one is forced, not chosen. `deploy.sh` closes every open issue in the
milestone it ships — so a workstream in a milestone is closed the first time
any part of it ships, which is exactly the thing spanning releases is for.

So: **chunks are milestoned, the lead issue is not.** It follows from tooling
that already exists, which makes it a rule rather than a preference.

### Then nothing closes the lead issue

Correct, and it has to be said out loud or the open-issue list quietly stops
meaning anything. Suggested: the lead closes by hand when the last chunk ships,
and the design note carries a status line saying which chunks have shipped, in
which release.

### The part that actually worries me

A workstream spanning releases means **a design note describing a state the
code is never in until the last chunk lands**. #71's note already says the turn
comes back as a state field while the server still has `move_number`. A reader
part-way through cannot tell what is built from what is designed, and a design
note that cannot be trusted about the present is worse than no note.

`71-impact.md`'s chunk list is doing that job informally today.
It probably deserves to be part of the scheme rather than something that
happened to get written.

### Open questions on workstreams

1. **Does a chunk need its own design note?** #71's chunks do not — the note
   covers them. A workstream whose chunks diverge might. Suggest: no by
   default, and if a chunk needs one, that is evidence it is a workstream.

2. **What does a workstream look like to `roadmap.sh`?** It already surfaces
   issues mentioned by two or more others, which is how #71 shows up now.
   Whether that should become an explicit relationship or stay inferred is
   open — inferred costs nothing and has been accurate so far.

3. **Is "workstream" the right word?** The industry's nearest are *epic*
   (Jira — a body of work broken into stories, but carries agile-ceremony
   baggage) and *tracking issue* (Rust, Kubernetes — a lead issue with a
   checklist of sub-issues, and much closer to what this is). *Tracking issue*
   names the lead; *workstream* names the group. We may need both words.
