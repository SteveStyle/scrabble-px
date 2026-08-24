#!/usr/bin/env python3
"""pipeline.py — where every issue sits, as a markdown report.

Owner, 2026-08-24: *"We need a view with everything… A long list in the terminal
is not easy to parse"* — *"or a markdown report"*. So this writes a file: VS Code
previews it, GitHub renders it, and fifty rows in a table are readable in a way
fifty lines in a terminal are not.

**Three parts**, at the owner's request: the **backlog** of unallocated
requirements split by status, **live projects** organised by workstream, and
**delivered projects** the same way.

**Derived, never stored.** docs/3.6 §2.18 defines the flow as requirements →
triage → backlog → project planning → projects, and the state is already
queryable: a triaged requirement is an open issue with a type label, without
`needs-triage`, not yet folded into a project.

**Three labels carry what structure cannot say.** A workstream was read off the
sub-issue graph — a parent with nobody above it — which fails for one created
before its first project: #204 registered as an untriaged requirement on the day
it was made. An index is not in the flow at all. So `index`, `workstream` and
`project` are labels, and everything else is derived.

**An open question this report is meant to answer by being used** (owner: *"I
wonder if this is more than one step, we should work some through and see"*):
whether *triaged* and *allocated to a workstream* are one state or two. They are
shown as one, with the workstream as a column, so the answer comes from looking
at real rows rather than from arguing about it.

The output is regenerated, not committed: stale by the next issue.
"""
import json
import subprocess
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

TYPES = {"bug", "minor-function", "major-function", "appearance",
         "documentation", "non-prod-tooling", "prod-tooling"}

QUERY = """
{ repository(owner: "%s", name: "%s") {
    open: issues(states: OPEN, first: 100) {
      nodes { number title url state
              milestone { title }
              labels(first: 20) { nodes { name } }
              parent { number }
              subIssues(first: 50) { nodes { number title url state
                                             labels(first: 20) { nodes { name } } } } } }
    closed: issues(states: CLOSED, first: 100, labels: ["project"]) {
      nodes { number title url state closedAt
              labels(first: 20) { nodes { name } }
              parent { number } } } } }
"""


def gh(*args: str) -> str:
    return subprocess.run(["gh", *args], capture_output=True, text=True).stdout


def labels_of(n: dict) -> set[str]:
    return {l["name"] for l in n["labels"]["nodes"]}


def main() -> int:
    repo = gh("repo", "view", "--json", "owner,name",
              "--jq", '"\\(.owner.login) \\(.name)"').split()
    if len(repo) != 2:
        print("pipeline.py: could not identify the repository", file=sys.stderr)
        return 1
    raw = gh("api", "graphql", "-f", "query=" + QUERY % (repo[0], repo[1]))
    if not raw:
        print("pipeline.py: no answer from GitHub", file=sys.stderr)
        return 1
    data = json.loads(raw)["data"]["repository"]
    opens = data["open"]["nodes"]
    closed_projects = data["closed"]["nodes"]

    by_num = {n["number"]: n for n in opens}
    workstreams = [n for n in opens if "workstream" in labels_of(n)]
    live_projects = [n for n in opens if "project" in labels_of(n)]
    index = [n for n in opens if "index" in labels_of(n)]
    structural = {n["number"] for n in workstreams + live_projects + index}

    def workstream_of(n: dict) -> str:
        """Walk up to the workstream, however many levels away it is."""
        seen, cur = set(), n
        while cur and cur["number"] not in seen:
            seen.add(cur["number"])
            parent = cur.get("parent")
            if not parent:
                return "—"
            p = by_num.get(parent["number"])
            if p is None:
                return f"#{parent['number']}"
            if "workstream" in labels_of(p):
                return f"#{p['number']}"
            cur = p
        return "—"

    project_nums = {p["number"] for p in live_projects}
    backlog: dict[str, list[dict]] = defaultdict(list)
    in_project: list[dict] = []
    for n in opens:
        if n["number"] in structural:
            continue
        parent = n.get("parent")
        if parent and parent["number"] in project_nums:
            in_project.append(n)
            continue
        labels = labels_of(n)
        backlog["untriaged" if ("needs-triage" in labels or not (labels & TYPES))
                else "triaged"].append(n)

    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    o = [
        "# The pipeline",
        "",
        f"*Generated {now} by `scripts/pipeline.py`. Derived from GitHub every run —",
        "do not edit, and do not commit: it is stale by the next issue.*",
        "",
        "| | |",
        "| --- | --- |",
        f"| **Backlog** — untriaged | {len(backlog['untriaged'])} |",
        f"| **Backlog** — triaged | {len(backlog['triaged'])} |",
        f"| **Live projects** | {len(live_projects)} |",
        f"| **Delivered projects** | {len(closed_projects)} |",
        "",
        "---",
        "",
        "## Backlog",
        "",
        "Requirements not yet allocated to a project. **Workstream is shown where it",
        "has been decided** — an em dash means nobody has said which capability owns it.",
        "",
    ]

    def table(rows: list[dict]) -> list[str]:
        if not rows:
            return ["*none*", ""]
        out = ["| # | title | type | milestone | workstream |",
               "| --- | --- | --- | --- | --- |"]
        for n in sorted(rows, key=lambda x: x["number"]):
            types = ", ".join(sorted(labels_of(n) & TYPES)) or "—"
            ms = n["milestone"]["title"] if n["milestone"] else "—"
            t = n["title"].replace("|", "\\|")
            out.append(f"| [#{n['number']}]({n['url']}) | {t} | {types} | `{ms}` | {workstream_of(n)} |")
        return out + [""]

    o += ["### Untriaged", "",
          "No type decided, or still labelled `needs-triage`. **This is the queue.**", ""]
    o += table(backlog["untriaged"])
    o += ["### Triaged", "",
          "Classified, and waiting to be planned into a project.", ""]
    o += table(backlog["triaged"])

    for heading, projects, closed in (("Live projects", live_projects, False),
                                      ("Delivered projects", closed_projects, True)):
        o += ["---", "", f"## {heading}", ""]
        if not projects:
            o += ["*none*", ""]
            continue
        grouped: dict[str, list[dict]] = defaultdict(list)
        for p in projects:
            parent = p.get("parent")
            grouped[f"#{parent['number']}" if parent else "unallocated"].append(p)
        for ws in sorted(grouped):
            if ws.startswith("#"):
                wsn = by_num.get(int(ws[1:]))
                title = f"{ws} {wsn['title']}" if wsn else ws
            else:
                # A project nobody has said owns which capability. Worth a
                # heading of its own rather than a blank: it is a question
                # outstanding, not a category.
                title = "No workstream decided"
            o += [f"### {title}", ""]
            for p in sorted(grouped[ws], key=lambda x: x["number"]):
                t = p["title"].replace("|", "\\|")
                o += [f"**[#{p['number']}]({p['url']}) — {t}**", ""]
                kids = [k for k in p.get("subIssues", {}).get("nodes", [])] if not closed else []
                if kids:
                    o += ["| # | title | state |", "| --- | --- | --- |"]
                    for k in sorted(kids, key=lambda x: x["number"]):
                        kt = k["title"].replace("|", "\\|")
                        o.append(f"| [#{k['number']}]({k['url']}) | {kt} | {k['state'].lower()} |")
                    o.append("")

    if in_project:
        o += ["---", "", "## Open requirements inside a project", "",
              "**These should be closed.** A requirement is folded into the project that",
              "takes it, and closed with the `folded` label — a requirement issue and a",
              "project issue are different things and should not be conflated.", ""]
        o += table(in_project)

    if index:
        o += ["---", "", "## Index", ""]
        for n in index:
            o.append(f"- [#{n['number']}]({n['url']}) — {n['title']}")
        o.append("")

    path = Path("pipeline.md")
    path.write_text("\n".join(o) + "\n")
    print(f"wrote {path}")
    print(f"  {len(backlog['untriaged']):3}  backlog — untriaged")
    print(f"  {len(backlog['triaged']):3}  backlog — triaged")
    print(f"  {len(live_projects):3}  live projects")
    print(f"  {len(closed_projects):3}  delivered projects")
    if in_project:
        print(f"  {len(in_project):3}  open requirements inside a project — should be closed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
