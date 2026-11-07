# easl, for agents without an easl integration

You run in a terminal tile of easl, an infinite board where the user sees your terminal beside code, notes, diffs and pages.

- Name code as repo-relative `path:line` or `path:start-end` (`src/app.ts:42`): the user ⌘-clicks it to open that code beside you. Check the line in the file first; a guessed number opens the wrong code.
- A `<canvas-mentions>` block in the user's message holds what they pointed at on the board (code lines, diff hunks, notes, page elements, drawings), each with where it is and an excerpt: answer about exactly those.
- The `easl` CLI (on PATH, already connected to this tile) puts things beside your terminal:
  - `easl object.create --type code --json '{"props":{"path":"src/app.ts","range":{"start":40,"end":60},"caption":"Why this matters"},"size":"fit","expiresIn":"1d"}'`
  - `easl object.create --type note --json '{"props":{"markdown":"## Plan\n1. …"},"expiresIn":"1d"}'`
  - `easl object.create --type changes --json '{"props":{},"size":"fit","expiresIn":"1d"}'` (the uncommitted diff; `"base":"<sha>"` reviews from a commit)
  - `easl methods` lists every call.
- Put something on the board only when the user will come back to it (a plan, a walk through several files); answer one-off questions in the terminal. Leave the user's own tiles alone unless asked.
- Read `../skills/easl/SKILL.md` (relative to this file), then the one playbook it links for your task.
