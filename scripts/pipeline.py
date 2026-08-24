#!/usr/bin/env python3
"""pipeline.py — where every open issue sits in the flow, as a markdown report.

Owner, 2026-08-24: *"We need a view with everything… A long list in the terminal
is not easy to parse."* — and *"or a markdown report"*. So this writes a file
rather than printing: VS Code previews it, GitHub renders it, and a table of
fifty rows is readable in a way a terminal list is not.

**Derived, never stored.** docs/3.6 §2.18 defines the flow as requirements →
triage → backlog → project planning → projects, and the glossary's answer to
where that state lives is that it is already queryable: a triaged requirement is
an open issue with a type label, without `needs-triage`, and not yet folded into
a project. Nothing here is maintained by hand except the three structural labels
below, which cannot be inferred.

**Why three labels rather than inference.** A workstream was read off the graph —
a parent with nobody above it — which fails for a workstream created before its
first project: #204 registered as an untriaged requirement on the day it was
made. An index (#203) is not in the flow at all. Those two cases cannot be
derived from structure, so they are labelled: `index`, `workstream`, `project`.

The output is regenerated, not committed: it would be stale by the next issue.
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
    issues(states: OPEN, first: 100) {
      nodes { number title url
              milestone { title }
              labels(first: 20) { nodes { name } }
              parent { number title }
              subIssues(first: 1) { totalCount } } } } }
"""


def gh(*args: str) -> str:
    return subprocess.run(["gh", *args], capture_output=True, text=True).stdout


def classify(n: dict) -> str:
    """One of the flow states, or a structural level that is not in the flow."""
    labels = {l["name"] for l in n["labels"]["nodes"]}
    if "index" in labels:
        return "index"
    if "workstream" in labels:
        return "workstream"
    if "needs-triage" in labels or not (labels & TYPES):
        return "raised"
    if n["parent"]:
        return "planned"
    return "backlog"


# The order they appear in the report, and what each means. Kept here rather
# than in the template so the two cannot disagree.
SECTIONS = [
    ("raised",    "Raised — needs triage",
     "No type yet, or still labelled `needs-triage`. **This is the queue.**"),
    ("backlog",   "Triaged — not yet planned",
     "Classified and filed, not yet grouped into a project. docs/3.6 §2.18 calls this the backlog."),
    ("planned",   "In a project",
     "Folded into a project, which owns them from here."),
    ("workstream", "Workstreams",
     "Not in the flow: capabilities, worked on indefinitely."),
    ("index",     "Index",
     "Not in the flow: a map."),
]


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
    nodes = json.loads(raw)["data"]["repository"]["issues"]["nodes"]

    buckets: dict[str, list[dict]] = defaultdict(list)
    for n in nodes:
        buckets[classify(n)].append(n)

    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    out = [
        "# The pipeline",
        "",
        f"*Generated {now} by `scripts/pipeline.py`. Derived from GitHub every run —",
        "do not edit, and do not commit: it is stale by the next issue.*",
        "",
        f"**{sum(len(v) for k, v in buckets.items() if k in ('raised', 'backlog', 'planned'))} open requirements**, "
        f"plus {len(buckets['workstream'])} workstreams and {len(buckets['index'])} index.",
        "",
        "| state | | |",
        "| --- | --- | --- |",
    ]
    for key, title, _ in SECTIONS[:3]:
        out.append(f"| **{title}** | {len(buckets[key])} | |")
    out.append("")

    for key, title, blurb in SECTIONS:
        rows = sorted(buckets[key], key=lambda x: x["number"])
        out += [f"## {title}", "", blurb, ""]
        if not rows:
            out += ["*none*", ""]
            continue
        out += ["| # | title | type | milestone | parent |", "| --- | --- | --- | --- | --- |"]
        for n in rows:
            labels = {l["name"] for l in n["labels"]["nodes"]}
            types = ", ".join(sorted(labels & TYPES)) or "—"
            ms = n["milestone"]["title"] if n["milestone"] else "—"
            parent = f"#{n['parent']['number']}" if n["parent"] else "—"
            title_cell = n["title"].replace("|", "\\|")
            out.append(f"| [#{n['number']}]({n['url']}) | {title_cell} | {types} | `{ms}` | {parent} |")
        out.append("")

    path = Path("pipeline.md")
    path.write_text("\n".join(out) + "\n")
    print(f"wrote {path} — {sum(len(v) for v in buckets.values())} open issues")
    for key, title, _ in SECTIONS:
        print(f"  {len(buckets[key]):3}  {title}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
