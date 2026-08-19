#!/usr/bin/env python3
"""actions.py — every outstanding action and review, in one query, in workstream order.

Owner, 2026-08-19: *"We need to see: the workstream parent issue (if there is
one), child issues, child PRs, actions."* And, on whether the two are the same
thing: *"Are all actions on a PR? Then show the PR and action together."*

**They are not the same thing, and the distinction is the point.**

  - an **action** is an unchecked `- [ ]` in an *issue* body. It is the only
    surface we have that can carry state: an issue holds one bit, a comment is
    append-only, a pull request body freezes at merge. See #181.
  - a **review checklist** is the same syntax in a *pull request* body, and is
    not an action — it is the review itself, and it appears as the pull request
    rather than as a list of boxes.

So a pull request and the actions on its issue are shown together, under that
issue, which is what the request amounts to once the two are separated.

**Structure comes from GitHub, not from a convention we maintain.** Parent and
sub-issue links are real (`subIssues`, `parent`), so a workstream is read rather
than inferred — unlike `roadmap.sh`'s "mentioned by", which reads prose because
nothing better existed when it was written.

A pull request is attached to its issue by **branch name** (`issue-<n>-…`),
which is the convention `status.sh` already relies on, and listed separately
when the name does not follow it — a branch that cannot be placed is worth
seeing rather than hiding.

Read-only and derived: nothing is stored, so nothing can drift.
"""
import json
import re
import subprocess
import sys

BOLD, DIM, OFF = "\033[1m", "\033[2m", "\033[0m"

# `--mine` / `--claude` filter the actions, never the structure: a workstream
# with nothing of yours in it still shows its pull requests, because "what is
# waiting on me" includes a review.
WHO = {"--mine": "Steve", "--claude": "Claude"}.get(sys.argv[1] if len(sys.argv) > 1 else "", "")

QUERY = """
{ repository(owner: "%s", name: "%s") {
    issues(states: OPEN, first: 100) {
      nodes { number title body
              parent { number }
              subIssues(first: 50) { nodes { number title state } } } }
    pullRequests(states: OPEN, first: 50) {
      nodes { number title headRefName isDraft
              labels(first: 20) { nodes { name } }
              files(first: 30) { nodes { path additions deletions } } } } } }
"""


def branches() -> set[int]:
    """Issue numbers with a branch of their own, local or on the remote.

    The same signal `status.sh` uses: a branch named `issue-<n>-…` means somebody
    started. Without it "not started" and "in progress" look identical from the
    issue alone, and the difference is the whole point of the distinction.
    """
    out = subprocess.run(["git", "branch", "-a", "--format=%(refname:short)"],
                         capture_output=True, text=True).stdout
    return {int(m.group(1)) for m in re.finditer(r"issue-(\d+)-", out)}


def gh(*args: str) -> str:
    return subprocess.run(["gh", *args], capture_output=True, text=True).stdout


def actions_in(body: str) -> list[str]:
    """Unchecked items, with wrapped continuation lines joined.

    An item ends at a blank line, at the next item, or at anything not indented.
    Without the blank-line rule this swallowed the paragraph after the list —
    which it did, visibly, the first time it ran.
    """
    out: list[str] = []
    open_item = False
    for line in (body or "").split("\n"):
        if re.match(r"^\s*- \[[ x]\]", line):
            if re.match(r"^\s*- \[ \]", line):
                out.append(re.sub(r"^\s*- \[ \]\s*", "", line))
                open_item = True
            else:
                open_item = False
        elif open_item and line.strip() and re.match(r"^\s+\S", line):
            out[-1] += " " + line.strip()
        else:
            open_item = False
    return out


def main() -> int:
    repo = gh("repo", "view", "--json", "owner,name",
              "--jq", '"\\(.owner.login) \\(.name)"').split()
    if len(repo) != 2:
        print("actions.py: could not identify the repository", file=sys.stderr)
        return 1
    raw = gh("api", "graphql", "-f", "query=" + QUERY % (repo[0], repo[1]))
    if not raw:
        print("actions.py: no answer from GitHub", file=sys.stderr)
        return 1
    data = json.loads(raw)["data"]["repository"]

    issues = {n["number"]: n for n in data["issues"]["nodes"]}
    prs = data["pullRequests"]["nodes"]

    pr_for: dict[int, list[dict]] = {}
    homeless: list[dict] = []
    for pr in prs:
        m = re.match(r"issue-(\d+)-", pr["headRefName"])
        (pr_for.setdefault(int(m.group(1)), []).append(pr) if m else homeless.append(pr))

    started = branches()

    def status(num: int, state: str) -> tuple[str, str]:
        """completed · in progress · not started — derived, never recorded."""
        if state != "OPEN":
            return "completed", DIM
        if num in pr_for or num in started:
            return "in progress", ""
        return "not started", DIM

    parents = [i for i in issues.values() if i["subIssues"]["nodes"]]
    children = {c["number"] for p in parents for c in p["subIssues"]["nodes"]}

    def turn(pr: dict) -> str:
        names = [l["name"] for l in pr["labels"]["nodes"]]
        if "approved" in names:
            return "approved — mine to merge"
        if "awaiting-review" in names:
            return "your turn"
        return "draft" if pr["isDraft"] else "in hand"

    def show_prs_and_actions(num: int, indent: str = "  ") -> None:
        for pr in pr_for.get(num, []):
            doc = sorted(pr["files"]["nodes"], key=lambda f: -(f["additions"] + f["deletions"]))
            path = doc[0]["path"] if doc else ""
            extra = f"  +{len(doc) - 1} more" if len(doc) > 1 else ""
            print(f"{indent}   PR #{pr['number']:<5} {pr['title']}  {DIM}[{turn(pr)}]{OFF}")
            if path:
                print(f"{indent}            {DIM}{path}{extra}{OFF}")
        for item in actions_in(issues.get(num, {}).get("body", "")):
            who = "Steve " if item.startswith("(Steve)") else "Claude" if item.startswith("(Claude)") else "      "
            if WHO and not item.startswith(f"({WHO})"):
                continue
            text = re.sub(r"^\((?:Steve|Claude)\)\s*", "", item)
            print(f"{indent}   - {who} {text}")

    def show_issue(num: int, title: str, state: str = "OPEN", indent: str = "  ") -> None:
        label, shade = status(num, state)
        print(f"{indent}{shade}issue #{num:<5} {title}  [{label}]{OFF if shade else ''}")
        # A completed issue is one line. Its pull request is merged and its
        # actions are done, so printing them is length without information —
        # which is what makes a growing workstream unreadable.
        if label != "completed":
            show_prs_and_actions(num, indent)

    print(f"{BOLD}ACTIONS{OFF}  {DIM}workstreams first, then issues that belong to none{OFF}")

    for p in sorted(parents, key=lambda i: i["number"]):
        print(f"\n{BOLD}workstream #{p['number']}  {p['title']}{OFF}")
        # The parent has its own pull requests and its own actions: a change to
        # the workstream's design lands against the parent, not against a chunk.
        show_prs_and_actions(p["number"], indent="")
        for c in p["subIssues"]["nodes"]:
            show_issue(c["number"], c["title"], c["state"])

    loose = [i for i in issues.values()
             if i["number"] not in children and not i["subIssues"]["nodes"]
             and (actions_in(i["body"]) or i["number"] in pr_for)]
    if loose:
        print(f"\n{BOLD}on their own{OFF}")
        for i in sorted(loose, key=lambda i: i["number"]):
            show_issue(i["number"], i["title"])

    if homeless:
        print(f"\n{BOLD}pull requests with no issue in the branch name{OFF}")
        for pr in homeless:
            print(f"  PR #{pr['number']:<5} {pr['title']}  {DIM}[{turn(pr)}] {pr['headRefName']}{OFF}")

    print(f"\n{DIM}Read-only, derived at run time — the issue body is the record.{OFF}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
