# wt TUI — design reference

Drop this folder into the repo as `tui/docs/design/`. Point Claude Code at `SPEC.md` first; use the
PNGs in `images/` to see each screen, and the files in `screens/` for exact layout and colour.

| File | What it is |
| --- | --- |
| `SPEC.md` | The implementation spec: architecture, data sources, agent unit + ACP bridge, nvim, tiers, keys, phases |
| `architecture.png` | How wt, mise, the Quadlet units and one worktree's pod connect (same as the ASCII diagram in the spec) |
| `images/*.png` | Rendered screens, 1 px per terminal pixel at JetBrains Mono 15 px / 20 px rows (one cell ≈ 9 × 20 px) |
| `screens/Main.dc.html` | Dashboard source, all three width tiers |
| `screens/Monitor.dc.html` | Agents screen source, cards view and list view |
| `screens/Agent.dc.html` | Agent chat source, ⅔ and ½ tiers |

## Images

| Image | Screen | Terminal size |
| --- | --- | --- |
| `dashboard-half-light.png` | Dashboard, ½ niri column | ~140 × 70 |
| `dashboard-twothirds-light.png` | Dashboard, ⅔ column | ~187 × 70 |
| `dashboard-full-light.png` | Dashboard, full width | ~282 × 70 |
| `dashboard-twothirds-dark.png` | Dashboard, ⅔, Flexoki dark | ~187 × 70 |
| `agents-cards-light.png` | Agents, cards view (10 agents, urgency sort) | ~187 × 70 |
| `agents-list-light.png` | Agents, list view (`v`) | ~187 × 70 |
| `agents-cards-dark.png` | Agents, cards view, dark | ~187 × 70 |
| `chat-twothirds-light.png` | Chat with sidebar | ~187 × 70 |
| `chat-half-light.png` | Chat, sidebar collapsed to a strip | ~140 × 70 |
| `chat-twothirds-dark.png` | Chat, dark | ~187 × 70 |

The images are browser renders of the mockups, so borders are drawn as lines; in the TUI they are
box-drawing characters occupying one cell (Ratatui `Block` with a title on the top border).

## How to read the screen files

They are mockups exported from a design canvas, not runnable pages: they need the canvas runtime
(`support.js`), so read them as text. Everything needed is inline:

- **Layout** is in the inline `style` attributes. Widths are in `ch` (one terminal cell), so
  `grid-template-columns: 2ch 18ch 30ch …` is the column layout in cells. Line height is one row (20px).
- **Variants** are chosen by props declared in `data-props` at the bottom of each file:
  - `Main`: `tier` = `half` | `twothirds` | `full`. The `LAYOUT` object in the script gives each
    tier's grid areas, and `<sc-if value="{{L.wide}}">` / `{{L.compact}}` blocks show which elements
    appear in which tier.
  - `Monitor`: `view` = `cards` | `list`.
  - `Agent`: `tier` = `half` | `twothirds`.
  - All three: `theme` = `light` | `dark`, `accent` = `orange` | `cyan` | `purple` | `blue`.
- **Colours**: the `PAL` object in each script is the Flexoki palette (light and dark) to copy into
  `theme.rb`. `c.ac` is the accent.
- **Glyphs** (◆ ✗ ● · ◐ ○ ⎇ ▰▱ ✎ ◇ ⌕ $ ⟳) are the state markers to reuse.
- **Template syntax**: `{{x}}` is a value from `renderVals()`; `<sc-for>` repeats; `<sc-if>` branches.
- **Sample data** (worktree names, PR numbers, ports, transcripts, the diff) is made up.

Where a mockup and `SPEC.md` ever disagree, follow the spec.
