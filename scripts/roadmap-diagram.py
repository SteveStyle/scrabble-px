#!/usr/bin/env python3
"""Draw the roadmap from GitHub, as Mermaid.

**A flowchart, not a Gantt.** A Gantt needs a start and a target date per item,
and this programme deliberately has neither: `Q1`-`Q3` on the Phase field order
what is next without inventing dates (docs/4.8). Drawing a Gantt would mean
inventing exactly what that choice avoids, so this draws what is actually
recorded — what depends on what, and what belongs to what.

**Derived, never maintained.** The picture is generated from the issues each
time it is asked for. A hand-drawn diagram is stale the first time something
moves, and stale in a way nobody can see; this one cannot disagree with the
data because it has no independent existence. Same reasoning as docs/4.9's
"change history is derived from git".

Usage:
    ./scripts/roadmap-diagram.py                 # every open project
    ./scripts/roadmap-diagram.py --parent 71     # one project's work packages
    ./scripts/roadmap-diagram.py --all           # requirements too

It prints a fenced ```mermaid block, ready to paste into an issue or a document.
GitHub renders it in both.
"""

import argparse
import json
import subprocess
import sys

FIELDS = "number,title,issueType,parent,blockedBy,blocking"
PHASE_ORDER = [
    "Scope", "Q3", "Q2", "Q1", "Design and Test Approach",
    "Development", "User testing", "Deployment",
    "Post-deployment", "Project Closedown",
]



START = "<!-- roadmap-diagram:start -->"
END = "<!-- roadmap-diagram:end -->"


def write_between_markers(path: str, block: str) -> None:
    """Replace what is between the markers, leaving the rest of the file alone.

    The markers are the contract: everything between them is generated and will
    be overwritten, everything outside is written by a person. Refusing when
    they are absent is deliberate — a diagram appended to the wrong file, or
    silently replacing a document, is worse than not drawing one.
    """
    text = open(path).read()
    if START not in text or END not in text:
        sys.exit(f"roadmap-diagram: {path} has no {START} / {END} markers")
    head, rest = text.split(START, 1)
    _, tail = rest.split(END, 1)
    open(path, "w").write(f"{head}{START}\n\n{block}\n\n{END}{tail}")


def gh_json(*args: str):
    out = subprocess.run(["gh", *args], capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"roadmap-diagram: gh failed: {out.stderr.strip()}")
    return json.loads(out.stdout or "[]")


def phases() -> dict[int, str]:
    """Phase per issue, which the REST-shaped `gh issue list` does not carry."""
    q = """{repository(owner:"delphside",name:"tile-lite-elite"){
      issues(first:100,states:OPEN){nodes{number issueFieldValues(first:12){nodes{
        ... on IssueFieldSingleSelectValue{name field{... on IssueFieldSingleSelect{name}}}}}}}}}"""
    out = subprocess.run(["gh", "api", "graphql", "-f", f"query={q}"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        return {}
    got = {}
    for i in json.loads(out.stdout)["data"]["repository"]["issues"]["nodes"]:
        for n in i["issueFieldValues"]["nodes"]:
            if n and (n.get("field") or {}).get("name") == "Phase":
                got[i["number"]] = n["name"]
    return got


def label(issue, phase: str | None) -> str:
    # Quotes and brackets both end a Mermaid node label, so they go.
    title = issue["title"].replace('"', "'").replace("[", "(").replace("]", ")")
    if len(title) > 46:
        title = title[:45] + "…"
    tail = f"<br/><i>{phase}</i>" if phase else ""
    return f'#{issue["number"]} {title}{tail}'


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--parent", type=int, help="only this issue's sub-issues")
    ap.add_argument("--all", action="store_true", help="include requirements")
    ap.add_argument("--write", metavar="FILE",
                    help="replace the block between the roadmap-diagram markers "
                         "in FILE, instead of printing")
    args = ap.parse_args()

    issues = gh_json("issue", "list", "--state", "open", "--limit", "100",
                     "--json", FIELDS)
    ph = phases()

    def kind(i):
        return (i.get("issueType") or {}).get("name", "")

    wanted = issues if args.all else [i for i in issues
                                      if kind(i) in ("Project", "Project Delivery")]
    if args.parent:
        wanted = [i for i in wanted
                  if (i.get("parent") or {}).get("number") == args.parent
                  or i["number"] == args.parent]
    nums = {i["number"] for i in wanted}

    out: list[str] = ["```mermaid", "flowchart LR"]

    def print(*a, **k):  # noqa: A001 — collect instead of emitting
        out.append(" ".join(str(x) for x in a))

    for i in sorted(wanted, key=lambda x: PHASE_ORDER.index(ph.get(x["number"], "Scope"))
                    if ph.get(x["number"]) in PHASE_ORDER else 0):
        text = '"' + label(i, ph.get(i["number"])) + '"'
        shape = f"([{text}])" if kind(i) == "Project Delivery" else f"[{text}]"
        print(f'  n{i["number"]}{shape}')

    edges = 0
    for i in wanted:
        # `blockedBy` is {nodes, totalCount}, not a list — the shape cost a
        # crash the first time this ran, which is why it is named here.
        for b in ((i.get("blockedBy") or {}).get("nodes") or []):
            if b["number"] in nums:
                print(f'  n{b["number"]} --> n{i["number"]}')
                edges += 1
        p = (i.get("parent") or {}).get("number")
        if p in nums:
            print(f'  n{p} -.- n{i["number"]}')
    out.append("```")

    if args.write:
        write_between_markers(args.write, "\n".join(out))
        sys.stderr.write(f"roadmap-diagram: updated {args.write}\n")
    else:
        sys.stdout.write("\n".join(out) + "\n")

    if not edges:
        print("", file=sys.stderr)
        print("note: no blocked-by relationships are recorded, so the diagram shows",
              file=sys.stderr)
        print("      structure only. Set them on the issues and run this again.",
              file=sys.stderr)


if __name__ == "__main__":
    main()
