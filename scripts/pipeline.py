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

# Kept only to read the handful of closed issues predating the move to issue
# fields on 2026-08-26. Everything open carries the field.
TYPES = {"bug", "minor-function", "major-function", "appearance",
         "documentation", "non-prod-tooling", "prod-tooling"}


def field(n: dict, name: str) -> str:
    """One issue field's value, or an em dash.

    **Single-select only.** `SINGLE_SELECT` is GitHub's own name for the data
    type — `Type of change`, `Effort` and `Priority` all have it, and the API
    returns their values as `IssueFieldSingleSelectValue`. The other data types
    an issue field can have are `TEXT`, `NUMBER`, `DATE` and `MULTI_SELECT`,
    each with its own value type; `Start date` and `Target date` are `DATE`.
    This reads none of them, and would need a branch per type to.

    **Issue fields replaced labels on 2026-08-26** — organisation-level, one
    value enforced, settable when the issue is raised, and visible on the issue
    itself rather than only inside a board. Labels could not do the first three:
    a label per value, nothing stopping two, and the requirement form could only
    put the answer in the body for somebody to apply by hand afterwards.

    `status.sh` used to match these as substrings and carried a comment saying
    `non-prod-tooling` had to be tested before `prod-tooling`, because one
    contains the other. An exact value removes the hazard rather than ordering
    around it.
    """
    for v in n.get("issueFieldValues", {}).get("nodes", []):
        if v and v.get("field", {}).get("name") == name:
            return v.get("value") or "—"
    return "—"


def level(n: dict) -> str:
    """The issue type — Requirement, Project, Workstream or Index.

    Read from GitHub's own issue type rather than from a label. The four are
    the levels docs/3.6 1 defines, minus the ones that are not issues.
    """
    t = n.get("issueType")
    return (t or {}).get("name") or "Requirement"

QUERY = """
{ repository(owner: "%s", name: "%s") {
    open: issues(states: OPEN, first: 100) {
      nodes { number title url state
              milestone { title }
              issueType { name }
              issueFieldValues(first: 10) {
                nodes { ... on IssueFieldSingleSelectValue {
                          value field { ... on IssueFieldCommon { name } } } } }
              labels(first: 20) { nodes { name } }
              parent { number }
              subIssues(first: 50) { nodes { number title url state
                                             labels(first: 20) { nodes { name } } } } } }
    closed: issues(states: CLOSED, first: 1) { nodes { number } } } }
"""


CLOSED_PROJECTS = """
{ search(query: "repo:%s/%s is:issue is:closed type:Project", type: ISSUE, first: 50) {
    nodes { ... on Issue { number title url state closedAt parent { number } } } } }
"""


def gh(*args: str) -> str:
    return subprocess.run(["gh", *args], capture_output=True, text=True).stdout


def cell(text: str) -> str:
    """A title, safe inside a markdown table cell.

    Titles are data. `#193` contains `<ref>`, which renders as inline HTML and
    fails the documentation lint; a title containing a pipe would break the
    table outright. Escaped here rather than in each caller, because forgetting
    it once produces a report that is wrong in a way nobody reads carefully.
    """
    return text.replace("|", "\\|").replace("<", "&lt;").replace(">", "&gt;")


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

    # Delivered projects come from **search**, not from the issues connection.
    # There are 190-odd closed issues and the connection returns them newest
    # first in pages of 100, so a project closed a while ago falls off the end —
    # which is exactly what happened on 2026-08-26, and the report showed zero
    # delivered projects while two existed. Search filters server-side on the
    # issue type, so the page holds only what is wanted.
    closed_raw = gh("api", "graphql", "-f", "query=" + CLOSED_PROJECTS % (repo[0], repo[1]))
    closed_projects = (json.loads(closed_raw)["data"]["search"]["nodes"]
                       if closed_raw else [])

    by_num = {n["number"]: n for n in opens}
    workstreams = [n for n in opens if level(n) == "Workstream"]
    live_projects = [n for n in opens if level(n) == "Project"]
    index = [n for n in opens if level(n) == "Index"]
    structural = {n["number"] for n in workstreams + live_projects + index}

    def workstream_of(n: dict) -> str:
        """Walk up to the workstream, however many levels away it is.

        **By name, not by number.** Owner, 2026-08-24: *"in the report the
        workstream column should give the name not the number"* — the same
        complaint that produced the index, #203: navigating by remembering
        numbers is what the structure is supposed to remove.

        The trailing "workstream" is dropped: it is the column heading.
        """
        seen, cur = set(), n
        while cur and cur["number"] not in seen:
            seen.add(cur["number"])
            parent = cur.get("parent")
            if not parent:
                return "—"
            p = by_num.get(parent["number"])
            if p is None:
                return f"#{parent['number']}"
            if level(p) == "Workstream":
                name = p["title"].removesuffix(" workstream")
                return f"[{name}]({p['url']})"
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
        # Untriaged is now: nobody has said what kind of change it is. The
        # `needs-triage` label still counts, for an issue somebody has looked
        # at and deliberately left in the queue.
        untriaged = "needs-triage" in labels_of(n) or field(n, "Type of change") == "—"
        backlog["untriaged" if untriaged else "triaged"].append(n)

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
        f"| **Backlog** — in triage | {len(backlog['triaged'])} |",
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
            types = field(n, "Type of change")
            ms = n["milestone"]["title"] if n["milestone"] else "—"
            t = cell(n["title"])
            out.append(f"| [#{n['number']}]({n['url']}) | {t} | {types} | `{ms}` | {workstream_of(n)} |")
        return out + [""]

    o += ["### Untriaged", "",
          "No type decided, or still labelled `needs-triage`. **This is the queue.**", ""]
    o += table(backlog["untriaged"])
    o += ["### In triage", "",
          "**Being worked on.** Its future is still undecided, and it may be edited",
          "many times before it is. There are no sub-states: which categorisation gets",
          "made when is not something you can prescribe up front (D35).", ""]
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
                t = cell(p["title"])
                o += [f"**[#{p['number']}]({p['url']}) — {t}**", ""]
                kids = [k for k in p.get("subIssues", {}).get("nodes", [])] if not closed else []
                if kids:
                    o += ["| # | title | state |", "| --- | --- | --- |"]
                    for k in sorted(kids, key=lambda x: x["number"]):
                        kt = cell(k["title"])
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
    print(f"  {len(backlog['triaged']):3}  backlog — in triage")
    print(f"  {len(live_projects):3}  live projects")
    print(f"  {len(closed_projects):3}  delivered projects")
    if in_project:
        print(f"  {len(in_project):3}  open requirements inside a project — should be closed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
