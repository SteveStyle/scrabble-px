# The process on one page

This page owns the rules. The numbered documents own the procedures and the
reasons, and issues own the arguments. If this page and a document disagree,
one of them has a defect: fix it, don't work around it.

## The work

- Something that should be true and is not becomes a Requirement issue. Raise
  it quickly. Discussion happens in the comments; the conclusions go in the
  body, which is edited to stay current.
- Triage is done jointly with the owner, never alone. Minimum: clear short
  description, workstream, priority, type of change. Then scope (options,
  dependencies, effort), then project planning. Outcomes: solo project,
  grouped project, straight to main, on hold, cancelled.
- A project owns its requirements: sources are folded and closed. Its issue
  carries six headings: requirements, design, impacted artefacts, test
  approach, dependencies and related work, deliveries.
- A project moves through the Phase field. The wording is the field's own
  stage descriptions:

  | phase | done when |
  | --- | --- |
  | Scope | What the project does. Technical option chosen where it affects dependencies. |
  | Q3, Q2, Q1 | The queue. Q1 is next off the blocks. |
  | Design and Test Approach | Design option chosen. Design completed. Test Approach defined. |
  | Development | Being built on its project delivery branch |
  | User testing | On Preview for user functional testing. On Rehearsal for technical testing. |
  | Deployment | Image: Prev->Reh->Prod. Repo-only: merge. Non-repo: by hand. |
  | Post-deployment | Check it is working and giving the benefit expected. |
  | Project Closedown | Lessons learnt completed. |

  The post-deployment check has one row per requirement.

## Changes

- A branch exists to hold a change back. Branch only when the old version is
  needed while the work is in progress; otherwise commit straight to main,
  which is what pre-approved means. One branch per project, and everything
  the project touches goes on it, documentation included.
- The pull request body is the review surface. Add the owner as reviewer at
  creation. He ticks, labels the PR approved, Claude merges by rebase and
  fast-forward.
- Commits say `Refs #N`, or `Closes #N` only when the change never leaves the
  repository. Every subject starts `app X.Y.Z api M.N: `.
- Push immediately after committing. Until pushed, a change does not exist.
  Run an unpushed script to test it, never to use it.
- Every issue and PR comment ends `Typed by Claude` or `Typed by Steve`.

## Releases

- A milestone is a release and a shipping list. The deploy settles everything
  in it, so move out what is not shipping before deploying.
- Deploys build a fresh worktree at the target commit, never the working
  tree. The image goes Preview, then Rehearsal, then Production.
- After deploying, run verify.sh and trust exit status, not read output.
- Bump dev to the next patch straight after each production deploy; dev leads
  production by one.
- Rehearsal is closed. scripts/rehearsal-access.sh grants access by QR code.

## Tests, checks and decisions

- Test conditions derive from stated rules, not from the code. The game rules
  are docs/1.0.
- A gate refuses and work stops; a check reports and a person decides. A new
  check is shown to fail before it ships.
- A decision is applied in the same commit that marks it answered, or an
  issue is raised and named in the decision.

## Documentation

- One fact, one home. The rule lives in its owning document, the argument in
  the issue, and every other mention is a link.
- docs/N.N numbering: 1.x product, 2.x design, 3.x lifecycle, 4.x reference.
  A change document lives in its issue's folder under docs/changes/.

## Where the detail is

| for | read |
| --- | --- |
| what to type: release, rollback, emergency | docs/3.3 |
| the lifecycle in full, and why | docs/3.6 |
| workstreams and what each owns | docs/3.7 |
| artefacts, and the strings tooling matches | docs/4.8 |
| daily state | scripts/inbox.sh, scripts/status.sh, scripts/actions.py |
