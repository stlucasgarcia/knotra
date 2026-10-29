---
name: Knotra
description: Embedded agent harness — warm paper, registry-green stamps, audit-grade restraint
colors:
  vellum: "#f7f6f2"
  margin-paper: "#fbfaf7"
  paper: "#ffffff"
  ledger-toned: "#efeee9"
  iron-gall: "#191a17"
  ledger-grey: "#6c6f66"
  nav-ink: "#3c3e38"
  rule-line: "#e2e1da"
  registry-green: "#1f6f4a"
  registry-wash: "#e3f1e8"
  mention-on-ink: "#d8f3e3"
  ochre-stamp: "#9a6200"
  ochre-wash: "#fff8e6"
  ochre-rule: "#efd9a6"
  red-seal: "#a12d24"
  red-wash: "#fbeae7"
  approval-wash: "#fff5f2"
  approval-rule: "#f1cfc8"
  agent-slate: "#3d6f8e"
  agent-plum: "#7a5a9e"
  agent-clay: "#a15c3e"
  agent-moss: "#3f7d63"
  agent-brass: "#8a6d2f"
  agent-rose: "#94505e"
typography:
  headline:
    fontFamily: "ui-sans-serif, system-ui, -apple-system, \"Segoe UI\", sans-serif"
    fontSize: "1.15rem"
    fontWeight: 650
    lineHeight: 1.3
    letterSpacing: "-0.01em"
  title:
    fontFamily: "ui-sans-serif, system-ui, -apple-system, \"Segoe UI\", sans-serif"
    fontSize: "1.5rem"
    fontWeight: 650
    lineHeight: 1.2
    letterSpacing: "-0.02em"
  body:
    fontFamily: "ui-sans-serif, system-ui, -apple-system, \"Segoe UI\", sans-serif"
    fontSize: "0.9rem"
    fontWeight: 400
    lineHeight: 1.45
    letterSpacing: "0em"
  label:
    fontFamily: "ui-sans-serif, system-ui, -apple-system, \"Segoe UI\", sans-serif"
    fontSize: "0.68rem"
    fontWeight: 600
    lineHeight: 1.2
    letterSpacing: "0.05em"
  mono:
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"
    fontSize: "0.78rem"
    fontWeight: 400
    lineHeight: 1.45
    letterSpacing: "0em"
  metric:
    fontFamily: "ui-sans-serif, system-ui, -apple-system, \"Segoe UI\", sans-serif"
    fontSize: "1.5rem"
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: "-0.02em"
rounded:
  xs: "5px"
  sm: "8px"
  md: "10px"
  lg: "14px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "14px"
  lg: "16px"
  xl: "28px"
components:
  button-primary:
    backgroundColor: "{colors.iron-gall}"
    textColor: "{colors.paper}"
    rounded: "{rounded.sm}"
    padding: "8px 14px"
  button-ghost:
    backgroundColor: "transparent"
    textColor: "{colors.iron-gall}"
    rounded: "{rounded.sm}"
    padding: "8px 14px"
  input-text:
    backgroundColor: "{colors.paper}"
    textColor: "{colors.iron-gall}"
    rounded: "{rounded.sm}"
    padding: "8px 10px"
    height: "36px"
  card-panel:
    backgroundColor: "{colors.paper}"
    rounded: "{rounded.lg}"
    padding: "16px"
  pill-status-active:
    backgroundColor: "{colors.ochre-wash}"
    textColor: "{colors.ochre-stamp}"
    typography: "{typography.label}"
    rounded: "999px"
    padding: "2px 7px"
  pill-status-done:
    backgroundColor: "{colors.registry-wash}"
    textColor: "{colors.registry-green}"
    typography: "{typography.label}"
    rounded: "999px"
    padding: "2px 7px"
  pill-status-error:
    backgroundColor: "{colors.red-wash}"
    textColor: "{colors.red-seal}"
    typography: "{typography.label}"
    rounded: "999px"
    padding: "2px 7px"
---

# Design System: Knotra

## Overview

**Creative North Star: "The Ledger & Ink"**

Two surfaces, one ledger. The demo chat (`examples/knotra_bots`) and the embeddable observability dashboard are both entries in a record that someone will later audit: warm paper underneath, neat ruled lines, monospace where precision matters, and a single green ink used to stamp what is authorized, active or complete. The system looks like a working document rather than an application shell, because the product's whole claim is that every execution can be inspected.

Restraint is the aesthetic. Panels are white sheets on vellum with a hairline rule and a shadow so faint it reads as paper thickness, not lift. Status is never color alone: a pill, a rail, a word and a hue say the same thing together. Density is moderate — compact table rows and 9–11px metadata, comfortable 860px message measure — so a developer can scan an execution timeline without leaving the page.

Nothing in the system is decorative. There is one accent, one shadow, no gradients, no glass, no illustrated empty states, no webfonts. The surfaces inherit the host's typography stack by design; they must not import an identity that the embedding application did not ask for.

**Key Characteristics:**
- Warm paper canvas, white sheets, hairline rules, no colored fills beyond status washes.
- One accent: registry green, reserved for state and action.
- System sans for prose, system mono for identifiers, arguments, counts and timings.
- Flat by default; depth is tone first, a 4%-alpha shadow second.
- Asymmetric speech bubbles and a 3px status rail are the two recurring silhouettes.
- Zero CSS transitions; motion exists only for live status.

## Colors

A warm neutral field with one archival green and three semantic seals.

### Primary
- **Registry Green** (`{colors.registry-green}`): the only brand accent. Active tab, selected row, completed status, mention chips, links, the live indicator dot. It marks a decision or a state, never a surface.
- **Registry Wash** (`{colors.registry-wash}`): the green's tint. Fill for completed pills, selected rows, mention highlights, focus outlines. Never used as a page or panel background.
- **Mention on Ink** (`{colors.mention-on-ink}`): the only green text allowed on a dark fill — mentions inside a human bubble. It is a tint of the accent, not a second green.

### Neutral
- **Vellum** (`{colors.vellum}`): the page. Every screen's canvas; never pure white at the largest area.
- **Margin Paper** (`{colors.margin-paper}`): the demo sidebar, one step warmer than vellum so the rail separates without a shadow.
- **Paper** (`{colors.paper}`): cards, panels, inputs, agent bubbles — the sheet that content is written on.
- **Ledger Toned** (`{colors.ledger-toned}`): nested rows, inline code, metric labels, stub tiles, table hover. The one tonal step used for "inside the sheet".
- **Iron Gall** (`{colors.iron-gall}`): all primary text, and the fill of the primary button, human bubble and brand mark. Near-black with a green-brown cast, never `#000`.
- **Ledger Grey** (`{colors.ledger-grey}`): secondary text, metadata, placeholder, table headers.
- **Nav Ink** (`{colors.nav-ink}`): sidebar channel labels at rest, one step softer than iron gall so the active item can outrank them.
- **Rule Line** (`{colors.rule-line}`): every 1px border, divider, table rule, rail.

### Status seals
- **Ochre Stamp** (`{colors.ochre-stamp}`) on **Ochre Wash** (`{colors.ochre-wash}`), ruled by **Ochre Rule** (`{colors.ochre-rule}`): queued, running, waiting, needs-you gates.
- **Red Seal** (`{colors.red-seal}`) on **Red Wash** (`{colors.red-wash}`), with **Approval Wash** (`{colors.approval-wash}`) and **Approval Rule** (`{colors.approval-rule}`) for the softer approval gate: failed, rejected, blocked, cancelled, expired, validation errors.
- **Agent hues** (`{colors.agent-slate}`, `{colors.agent-plum}`, `{colors.agent-clay}`, `{colors.agent-moss}`, `{colors.agent-brass}`, `{colors.agent-rose}`): a six-hue set assigned by hashing the agent handle, used only as avatar fills. Identity, not status; never reused for badges.

### Named Rules
**The One Stamp Rule.** Registry green may cover at most a pill, a rail, a link, a selected row or a 32px mark. It never fills a panel, a header, a button, or more than a tenth of a screen. Its rarity is what makes "approved" legible.

**The Ink Rule.** Primary text is iron gall; grey is for metadata only. Never lighten body copy to create hierarchy — use size, weight or the label treatment instead.

**The Seal-Not-Decoration Rule.** Ochre and red appear only where an execution is waiting or has failed. They are not emphasis colors for buttons, headings or borders.

## Typography

**Display Font:** none — every surface uses the platform sans (`ui-sans-serif, system-ui, -apple-system, "Segoe UI"`).
**Body Font:** the same platform sans.
**Label/Mono Font:** platform mono (`ui-monospace, SFMono-Regular, Menlo, Consolas`).

**Character:** deliberately anonymous. The host application is the owner of typographic identity; Knotra reads as native to whatever machine it lands on. Mono is not a costume — it is reserved for values a human or another program will compare: execution ids, tool arguments, versions, timings, token usage, timestamps in traces.

### Hierarchy
- **Title** (650, 1.5rem, −0.02em): page headings on `/agents` and `/channels`. One per page.
- **Headline** (650, 1.15rem, −0.01em): the channel name in the chat header and the dashboard title. Carries the screen, no eyebrow above it.
- **Body** (400, 0.9–0.92rem, 1.45): messages, panel text, descriptions. Message measure stays at or below 860px; detail-rail prose stays short.
- **Label** (600, 0.62–0.72rem, 0.05–0.12em, uppercase): field names, table headers, status pills, "needs you" gate titles, section eyebrows inside panels. Never a sentence.
- **Metric** (700, 1.5rem, −0.02em): the single number in a metric tile.
- **Mono** (400, 0.64–0.78rem): ids, handles, `code`, arguments, per-turn timings, usage.

### Named Rules
**The Annotation Rule.** Uppercase tracked type is allowed only at 0.72rem or smaller, and only for a field or state name. The moment a label becomes a sentence, it drops to body case.

**The Comparison Rule.** Anything a reader might diff against another value — id, version, duration, count, argument, timestamp — is set in mono. Prose never uses mono.

## Layout

The demo app is a fixed 250px rail plus a fluid column: the message thread is centered on an 860px measure, while the composer and page sections cap at 900px. The rail holds the brand mark, channel list, agent and observability links, and the tenant line; it collapses at 760px into a horizontal, scrollable strip above the thread, and the thread drops its fixed viewport height.

The dashboard is a single full-width column with 24px/28px page padding. When a detail pane is open, the body becomes a flexible list plus a 330–420px sticky rail; below 980px the rail stacks under the list instead. Grids are `auto-fit` with 120px metric and 280–300px card minimums, so panels reflow rather than shrink text.

Density is compact: 8–9px vertical padding in rows and events, 14–16px inside panels, 14px between panels. Spacing rhythm: 4 / 8 / 14 / 16 / 28px. Space above a group heading exceeds space below it; the top padding of a page is always larger than its section gaps.

## Elevation & Depth

Flat by default; tone over shadow. A panel sits on the page with a 1px rule and one soft two-layer shadow at 4% alpha — enough to separate paper from paper, not enough to look lifted. Nested content goes down a tone (ledger toned) rather than up in shadow. Hover never raises anything: it changes a border to registry green. Exactly one element is allowed a real popover shadow: the `@` mention menu, which must clear the composer.

### Shadow Vocabulary
- **Sheet** (`0 1px 2px rgba(20, 20, 15, 0.04), 0 8px 24px rgba(20, 20, 15, 0.04)`): cards, panels, bubbles, metric tiles, the sticky detail rail.
- **Event line** (`0 1px 2px rgba(20, 20, 15, 0.03)`): individual timeline events, one step lighter than a sheet.
- **Popover** (`0 18px 42px rgba(20, 20, 15, 0.14), 0 2px 6px rgba(20, 20, 15, 0.06)`): the mention menu only.

### Named Rules
**The No-Lift Rule.** Hover, focus and selection never translate, scale or deepen a surface. They change border color, background tone, or text color — nothing moves.

## Shapes

The radius ladder is 5px (inline code), 8px (buttons, inputs, nav items), 10px (gates, events, callouts, row cards), 14px (panels, cards, bubbles), and 999px (status pills, chips, member badges, the metric count). Corners are gently rounded, never pill-shaped except where something is literally a tag.

Two silhouettes repeat and carry meaning. **Speech bubbles** are asymmetric: the sender's corner is 4px, the other three are 14px, and the human bubble mirrors it — the flat corner always points at the author. **Status rails** are a 3px left border on event cards, message feeds and flow nodes, tinted by kind or status (accent for model/tool/completed, ochre for human/waiting, red for failure) while the card itself stays white.

Borders are always 1px hairlines in rule line, except an active gate which takes its seal color. No gradients, no clipping paths, no decorative geometry. The brand mark is a 28–30px rounded square (9px) in iron gall with a white "K".

## Components

Sober and precise: one solid-ink action per view, hairline outlines and tonal fills for everything else.

### Buttons
- **Shape:** 8px radius, 1px border matching the fill, 8px 14px padding, 0.85rem label in sentence case.
- **Primary:** iron gall fill, paper text. This is the only filled control on a screen — "Send", "Create", "Approve".
- **Hover / Focus:** hover drops opacity to 0.9; there is no transition. Buttons currently inherit the browser focus ring — inputs set their own, buttons do not.
- **Ghost:** transparent fill, rule-line border, ink text; hover tightens the border to iron gall. Used for "Reject", "Dismiss", secondary form actions.
- **Link:** no border or fill, registry green text at 0.78rem, hover at 0.75 opacity. Used only inside payloads and tables.

### Chips & Pills
- **Style:** 999px radius, 2px 7px padding, label typography, colored dot at 5px. Background and text come from one seal pair; the dot uses `currentColor`.
- **States:** ochre for active/waiting, registry green + wash for completed, red + wash for failed/rejected/blocked/cancelled/expired, ledger toned + grey for neutral counts and versions.

### Cards & Panels
- **Corner Style:** 14px; 10px for nested gates and events.
- **Background:** paper on vellum; ledger toned for a stub or nested row inside a panel.
- **Shadow Strategy:** sheet, or event line for timeline events. No deeper shadow exists except the popover.
- **Border:** 1px rule line; hover and selection recolor the border to registry green and add the wash, never a shadow.
- **Internal Padding:** 14px in compact cards, 16px in panels, 10px in row cards.

### Inputs & Fields
- **Style:** paper fill, 1px rule-line border, 8px radius, 0.5rem padding; the composer textarea is larger (12px radius, 11px 12px padding, sheet shadow, 44px minimum height).
- **Focus:** border flips to registry green plus a 2px registry-wash outline. This is the only focus treatment defined; it must not be removed.
- **Error / Disabled:** errors render as red-seal text on the page or inside a gate; no disabled styling exists yet, so disabled controls must not be introduced without one.

### Navigation
- **Sidebar:** 250px, margin paper, 1px right rule. Items are 8px-radius links at 0.9rem; active takes the registry wash with green 600-weight text; the `#` sigil is grey mono. Section labels are uppercase 0.68rem at 0.12em tracking.
- **Tabs (dashboard):** text buttons on a 1px bottom rule; inactive is grey 600 at 0.85rem, hover turns ink, active takes registry green text plus a 2px green underline. Counts sit in a small toned pill.

### Message Bubble (signature)
Paper sheet, 1px rule, sheet shadow, 4px corner on the author's side, 10px 13px padding, 0.92rem body with pre-wrapped text. Human messages invert to iron gall fill with paper text and keep the mirror radius. Mentions render as a wash-filled, green-text chip inside the bubble; inside a human bubble the chip switches to a translucent white with pale green text. Metadata (name, handle, model, status, timestamp) sits outside the bubble at 0.78rem in grey.

### Status Rail Card (signature)
White card, 1px rule, 10px radius, 3px left rail, sequence chip in tone, one line of 0.7rem metadata, body at 0.78–0.85rem in mono where it is data. The rail is the fastest scan cue in the dashboard: it must always agree with the status pill and the status word.

### Mention Menu (signature)
A popover anchored above the composer and spanning its width: paper fill, 1px rule, 14px radius, and the only popover shadow in the system. A header strip at 0.66rem uppercase 0.045em grey carries the label and a `kbd` hint row (Tab, Enter, Escape) separated by its own rule. Options sit in a 6px-padded grid of 9px-radius rows; hover takes ledger toned, the active row takes the registry wash plus a 3px green bar on its left edge, with the name at 600/0.86rem and the handle in grey 0.78rem. Arrow keys move the active row, Escape dismisses. It never becomes a modal or a full sheet.

### Approval Gate (signature)
An inline block inside the message it gates — never a dialog: 10px radius, 1px border, 10px 12px padding, ochre wash for clarifications and approval wash for write approvals. The title is 0.72rem uppercase at 0.08em tracking; the operation name is mono, and the validated arguments sit in a paper `<pre>` at 0.76rem with an 8px radius inside a rule. Actions are a ghost/ink button pair. The approval variant swaps only border and fill — the title keeps ochre, so the red seal is carried by the border and wash alone. Read-only gates are answered by host policy and leave their event in the trace; write gates wait for a human.

### Metric Tile
A sheet card, 14px radius, 12px 14px padding, stacking a 0.68rem uppercase 0.08em grey label over a metric value with a 2px gap. The tile never tints; only the number takes the status hue — ochre for running or waiting, registry green for completed, red for failed. Tiles reflow on an `auto-fit` grid with a 120px minimum.

## Do's and Don'ts

### Do:
- **Do** start every surface on vellum with paper sheets; the largest area is never pure white.
- **Do** encode status three ways at once — hue, pill text and rail or dot — so a colorblind reader still sees it.
- **Do** use one solid-ink primary action per view and ghost controls for everything else.
- **Do** set ids, arguments, versions, timings and usage in mono at 0.64–0.78rem.
- **Do** keep the sheet shadow at 4% alpha and the radius at 14px for panels, 8px for controls.
- **Do** make focus visible on inputs with the green border plus 2px wash outline.

### Don't:
- **Don't** introduce gradients, glass, glow, AI sparkle marks, or a second accent — the world is flat paper and one green stamp.
- **Don't** build a dark terminal skin or neon status colors; the product is a record, not a console toy.
- **Don't** reach for Material/Bootstrap chrome: no elevation ladders, no filled cards everywhere, no default button stacks.
- **Don't** set grey secondary text on the tonal fill: ledger grey on ledger toned measures 4.41:1, below the 4.5 body minimum. Grey belongs on vellum, paper or margin paper.
- **Don't** use `#000`, `#fff` as a page background, or a colored left rail thicker than 3px.
- **Don't** animate layout, translate or scale on hover; motion is limited to the typing-dot blink and live status arrival.
- **Don't** add a webfont or a display face; the host's platform stack is the identity.
- **Don't** put registry green on a large area, a header band, or a primary button.
