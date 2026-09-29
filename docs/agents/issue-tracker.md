# Issue tracker: GitHub

Issues and specs live in stlucasgarcia/knotra. Use the gh CLI.

- Publish: gh issue create --title "..." --body-file <file>
- Fetch: gh issue view <number> --comments
- List: gh issue list --state open
- Comment: gh issue comment <number> --body-file <file>
- Label: gh issue edit <number> --add-label "..." / --remove-label "..."
- Close: gh issue close <number> --comment "..."

Infer the repository from the Git remote.

## Pull requests as a triage surface

PRs as a request surface: no.

## Wayfinding

Use one issue labelled wayfinder:map as the map.
Link child tickets as GitHub sub-issues, falling back to a map task list
and a "Part of #<map>" line in each child.

Use wayfinder:research, wayfinder:prototype, wayfinder:grilling, or
wayfinder:task labels for children.

Record blockers using native issue dependencies; fall back to
"Blocked by: #<number>" lines when unavailable.
Select the first open, unassigned child in map order with no open blockers.
Claim with gh issue edit <number> --add-assignee @me.
Resolve by commenting, closing, and adding a result link to the map.
